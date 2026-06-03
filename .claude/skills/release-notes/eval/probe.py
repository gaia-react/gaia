#!/usr/bin/env python3
"""Local trigger probe for the installed `release-notes` skill.

Maintainer-only validation harness. Verifies the skill's frontmatter
`description` makes Claude trigger the skill for queries that should match, and
NOT trigger for near-miss queries that should not. Run it after any edit to the
`description` to confirm the trigger boundary still holds (target: 100% recall on
the should-trigger set, 0% false-positive on the should-not set).

It does NOT use the skill-creator's temp-command approach (which scores recall=0%
because the real installed skill steals the trigger from the temp hash name).
Instead it probes the real installed skill directly and detects, from streaming
tool-use events, whether the model's first action is Skill(skill="release-notes")
or a Read of the skill's SKILL.md. Detection is early and the process is killed
the instant we detect, so permission prompts never fire.

Requires the `claude` CLI on PATH (uses your Claude Code subscription auth, no
ANTHROPIC_API_KEY needed). The repo root is resolved dynamically, so it runs from
anywhere:

  python3 .claude/skills/release-notes/eval/probe.py                 # full sweep
  python3 .../eval/probe.py --runs 3                                 # 3 runs/query
  python3 .../eval/probe.py --only "make the release-data"           # one query
  python3 .../eval/probe.py --out /tmp/result.json                   # custom output
"""

import argparse
import json
import os
import select
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

SKILL_NAME = "release-notes"
SCRIPT_DIR = Path(__file__).resolve().parent


def _repo_root() -> Path:
    """Repo root, resolved dynamically so the probe is path-portable."""
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            cwd=SCRIPT_DIR, capture_output=True, text=True, check=True,
        )
        return Path(out.stdout.strip())
    except Exception:
        # eval/ -> release-notes/ -> skills/ -> .claude/ -> repo root
        return SCRIPT_DIR.parents[3]


REPO_ROOT = _repo_root()
DEFAULT_EVAL = SCRIPT_DIR / "trigger-eval.json"


def detect_trigger(accumulated_json: str, tool: str) -> bool:
    """True if the first tool action targets the release-notes skill."""
    if tool == "Skill":
        # Skill input is {"skill":"release-notes",...}; sibling skills like
        # "gaia-release" do not contain the substring "release-notes".
        return "release-notes" in accumulated_json
    if tool == "Read":
        return f"skills/{SKILL_NAME}" in accumulated_json
    return False


def run_single(query: str, timeout: int, model: str) -> dict:
    """Run one query; return {'triggered', 'first_tool', 'first_arg',
    'elapsed', 'note'}. cwd is the repo root so the installed skill is found."""
    cmd = [
        "claude",
        "-p", query,
        "--output-format", "stream-json",
        "--verbose",
        "--include-partial-messages",
        "--model", model,
    ]
    # Drop CLAUDECODE so a nested `claude -p` is allowed; the guard is for
    # interactive terminal conflicts, not programmatic subprocess use.
    env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}

    process = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        cwd=str(REPO_ROOT),
        env=env,
    )

    triggered = False
    first_tool = ""
    accumulated_json = ""
    pending_tool = None
    start = time.time()
    buffer = ""

    def result(trig, tool, arg, n):
        return {
            "triggered": trig,
            "first_tool": tool,
            "first_arg": arg[:160],
            "elapsed": round(time.time() - start, 1),
            "note": n,
        }

    try:
        while time.time() - start < timeout:
            if process.poll() is not None:
                rest = process.stdout.read()
                if rest:
                    buffer += rest.decode("utf-8", errors="replace")
            else:
                ready, _, _ = select.select([process.stdout], [], [], 1.0)
                if not ready:
                    continue
                chunk = os.read(process.stdout.fileno(), 8192)
                if not chunk:
                    if process.poll() is not None:
                        break
                    continue
                buffer += chunk.decode("utf-8", errors="replace")

            while "\n" in buffer:
                line, buffer = buffer.split("\n", 1)
                line = line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue

                etype = event.get("type")

                if etype == "stream_event":
                    se = event.get("event", {})
                    st = se.get("type", "")

                    if st == "content_block_start":
                        cb = se.get("content_block", {})
                        if cb.get("type") == "tool_use":
                            name = cb.get("name", "")
                            if name in ("Skill", "Read"):
                                pending_tool = name
                                first_tool = name
                                accumulated_json = ""
                            else:
                                # First tool is something else -> non-trigger.
                                return result(False, name, "", "first tool not Skill/Read")

                    elif st == "content_block_delta" and pending_tool:
                        delta = se.get("delta", {})
                        if delta.get("type") == "input_json_delta":
                            accumulated_json += delta.get("partial_json", "")
                            if detect_trigger(accumulated_json, pending_tool):
                                return result(True, pending_tool, accumulated_json, "early-detect")

                    elif st in ("content_block_stop", "message_stop"):
                        if pending_tool:
                            trig = detect_trigger(accumulated_json, pending_tool)
                            return result(trig, pending_tool, accumulated_json,
                                          "block-stop" if trig else "tool but wrong target")
                        if st == "message_stop":
                            return result(False, first_tool or "(text)", "", "turn ended, no skill")

                elif etype == "assistant":
                    # Fallback: full assistant message (post-execution).
                    msg = event.get("message", {})
                    for ci in msg.get("content", []):
                        if ci.get("type") != "tool_use":
                            continue
                        name = ci.get("name", "")
                        inp = json.dumps(ci.get("input", {}))
                        if name == "Skill" and SKILL_NAME in ci.get("input", {}).get("skill", ""):
                            return result(True, "Skill", inp, "fallback-assistant")
                        if name == "Read" and f"skills/{SKILL_NAME}" in ci.get("input", {}).get("file_path", ""):
                            return result(True, "Read", inp, "fallback-assistant")
                        return result(False, name, inp, "fallback wrong tool")

                elif etype == "result":
                    return result(triggered, first_tool or "(text)", "", "result event")

            if process.poll() is not None:
                break

        return result(triggered, first_tool or "(timeout)", accumulated_json, "timeout/eof")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--eval-set", default=str(DEFAULT_EVAL))
    ap.add_argument("--runs", type=int, default=1)
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--timeout", type=int, default=120)
    ap.add_argument("--model", default="claude-opus-4-8")
    ap.add_argument("--only", default=None,
                    help="substring filter: only run queries containing this")
    ap.add_argument("--out",
                    default=str(Path(tempfile.gettempdir()) / "release-notes-probe-result.json"),
                    help="where to write the JSON result (default: system temp dir)")
    args = ap.parse_args()

    eval_set = json.loads(Path(args.eval_set).read_text())
    if args.only:
        eval_set = [q for q in eval_set if args.only.lower() in q["query"].lower()]

    jobs = []  # (idx, query, should_trigger, run_idx)
    for i, item in enumerate(eval_set):
        for r in range(args.runs):
            jobs.append((i, item["query"], item["should_trigger"], r))

    out = {}  # idx -> {query, should_trigger, runs:[result...]}
    for i, item in enumerate(eval_set):
        out[i] = {"query": item["query"], "should_trigger": item["should_trigger"], "runs": []}

    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        fut = {ex.submit(run_single, q, args.timeout, args.model): (idx, st)
               for (idx, q, st, _) in jobs}
        done = 0
        for f in as_completed(fut):
            idx, st = fut[f]
            try:
                res = f.result()
            except Exception as e:
                res = {"triggered": False, "first_tool": "ERROR", "first_arg": str(e)[:160],
                       "elapsed": 0, "note": "exception"}
            out[idx]["runs"].append(res)
            done += 1
            mark = "TRIG" if res["triggered"] else "----"
            exp = "+" if st else "-"
            print(f"[{done}/{len(jobs)}] {mark} exp={exp} {res['elapsed']:>5}s "
                  f"{res['first_tool']:<8} :: {out[idx]['query'][:60]}", file=sys.stderr)

    should_rows, shouldnot_rows = [], []
    for idx in sorted(out):
        row = out[idx]
        rate = sum(1 for r in row["runs"] if r["triggered"]) / max(1, len(row["runs"]))
        row["trigger_rate"] = rate
        (should_rows if row["should_trigger"] else shouldnot_rows).append(row)

    def fmt(rows, want):
        lines = []
        for row in rows:
            rate = row["trigger_rate"]
            ok = (rate >= 0.5) == want
            status = "PASS" if ok else "FAIL"
            firsts = ",".join(sorted({r["first_tool"] for r in row["runs"]}))
            lines.append(f"  [{status}] rate={rate:.2f} first={firsts:<14} {row['query'][:64]}")
        return "\n".join(lines)

    recall = sum(1 for r in should_rows if r["trigger_rate"] >= 0.5) / max(1, len(should_rows))
    fp_rate = sum(1 for r in shouldnot_rows if r["trigger_rate"] >= 0.5) / max(1, len(shouldnot_rows))

    print("\n=== SHOULD TRIGGER (recall) ===")
    print(fmt(should_rows, True))
    print("\n=== SHOULD NOT TRIGGER (false positives) ===")
    print(fmt(shouldnot_rows, False))
    print(f"\nrecall = {recall * 100:.0f}%  "
          f"({sum(1 for r in should_rows if r['trigger_rate'] >= 0.5)}/{len(should_rows)})")
    print(f"false-positive rate = {fp_rate * 100:.0f}%  "
          f"({sum(1 for r in shouldnot_rows if r['trigger_rate'] >= 0.5)}/{len(shouldnot_rows)})")

    Path(args.out).write_text(json.dumps(out, indent=2))
    print(f"\nwrote {args.out}")


if __name__ == "__main__":
    main()
