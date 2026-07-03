#!/usr/bin/env python3
"""Scan Claude Code transcripts and report Serena vs grep usage.

Default: last 7 days of transcripts for the gaia-react/gaia project.
Override with --days N or --since YYYY-MM-DD.

Usage:
    python3 .gaia/tests/observability/serena/usage_scan.py
    python3 .gaia/tests/observability/serena/usage_scan.py --days 1
    python3 .gaia/tests/observability/serena/usage_scan.py --since 2026-05-04
"""
import argparse
import json
import re
import sys
import time
from collections import Counter
from glob import glob
from pathlib import Path

TRANSCRIPT_DIR = Path.home() / ".claude/projects/-Users-stevensacks-Development-gaia-react-gaia"

SEARCH_TOOLS = {"Grep", "Glob", "Read"}
SERENA_PREFIX = "mcp__serena__"

# Shell grep/rg/ag issued through the Bash tool. The structured Grep tool is
# counted directly; this catches the same search intent when it goes out as a
# shell command instead. Heuristic (measurement, not enforcement): match
# grep/rg/ag as a word at the start of the command or immediately after a shell
# separator (| || && ; a newline, or a subshell / command-substitution opener
# ( ` $( ). It deliberately counts searches inside pipelines such as
# `git diff | grep foo` that the routing guard skips, because the scan wants
# total shell-search volume so the serena/grep denominator is honest. Known,
# accepted misses (kept identical so the convene port's numbers stay
# comparable): `git grep` (git subcommand, not a command-position grep/rg/ag),
# grep variants outside the family (egrep/fgrep/zgrep), and greps hidden behind
# aliases or xargs. It can also over-count a literal "grep" that happens to sit
# at a command position; both directions are rare and acceptable for a
# denominator.
SHELL_GREP_RE = re.compile(r"(?:^|[|;&(`\n]|\$\()\s*(?:grep|rg|ag)\b")


def count_shell_greps(command):
    """Number of shell grep/rg/ag invocations at a command position in a string."""
    return len(SHELL_GREP_RE.findall(command))


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--days", type=int, default=7, help="window in days (default: 7)")
    p.add_argument("--since", type=str, help="ISO date YYYY-MM-DD (overrides --days)")
    p.add_argument("--per-session", action="store_true", help="show per-session breakdown")
    return p.parse_args()


def cutoff_ts(args):
    if args.since:
        return time.mktime(time.strptime(args.since, "%Y-%m-%d"))
    return time.time() - args.days * 86400


def iter_tool_uses(path):
    """Yield (tool_name, session_id, command) for every tool_use in a transcript.

    command is the Bash tool's `input.command` string when tool_name == "Bash"
    (the transcript field is `input`, not `tool_input`), otherwise None. It lets
    the counting pass detect shell grep/rg/ag searches issued through Bash.
    """
    sid = path.stem
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue

            msg = ev.get("message")
            if not isinstance(msg, dict):
                continue
            if msg.get("role") != "assistant":
                continue
            for b in msg.get("content") or []:
                if isinstance(b, dict) and b.get("type") == "tool_use":
                    name = b.get("name", "unknown")
                    command = None
                    if name == "Bash":
                        inp = b.get("input")
                        if isinstance(inp, dict) and isinstance(inp.get("command"), str):
                            command = inp["command"]
                    yield name, sid, command


def main():
    args = parse_args()

    if not TRANSCRIPT_DIR.exists():
        print(f"transcript dir not found: {TRANSCRIPT_DIR}", file=sys.stderr)
        sys.exit(1)

    cutoff = cutoff_ts(args)
    files = [Path(p) for p in glob(str(TRANSCRIPT_DIR / "*.jsonl"))]
    files = [p for p in files if p.stat().st_mtime >= cutoff]

    if not files:
        print(f"no transcripts modified since {time.strftime('%Y-%m-%d', time.localtime(cutoff))}")
        return

    overall = Counter()
    serena_by_tool = Counter()
    by_session = {}
    shell_grep_total = 0

    for p in files:
        sid = p.stem
        local = Counter()
        for tool, _, command in iter_tool_uses(p):
            overall[tool] += 1
            local[tool] += 1
            if tool.startswith(SERENA_PREFIX):
                serena_by_tool[tool[len(SERENA_PREFIX):]] += 1
            if command:
                shell_grep_total += count_shell_greps(command)
        by_session[sid] = (local, p.stat().st_mtime)

    serena_total = sum(v for k, v in overall.items() if k.startswith(SERENA_PREFIX))
    grep_total = overall.get("Grep", 0)
    combined_grep_total = grep_total + shell_grep_total
    glob_total = overall.get("Glob", 0)
    read_total = overall.get("Read", 0)
    all_tools = sum(overall.values())
    sessions_with_serena = sum(1 for sid, (c, _) in by_session.items() if any(k.startswith(SERENA_PREFIX) for k in c))

    print(f"window: {time.strftime('%Y-%m-%d', time.localtime(cutoff))} → now")
    print(f"transcripts in window: {len(files)}  ·  sessions touching serena: {sessions_with_serena}")
    print()
    print(f"  total tool calls : {all_tools}")
    print(f"  serena calls     : {serena_total}  ({100*serena_total/all_tools:.1f}% of all)" if all_tools else "")
    print(f"  Grep (tool)      : {grep_total}")
    print(f"  shell grep/rg (Bash) : {shell_grep_total}")
    print(f"  grep (Grep + shell)  : {combined_grep_total}")
    print(f"  Glob             : {glob_total}")
    print(f"  Read             : {read_total}")
    if combined_grep_total:
        print(f"  serena/grep ratio: {serena_total/combined_grep_total:.2f}  (vs Grep tool + shell grep)")
    print()

    if serena_by_tool:
        print("serena breakdown:")
        for tool, n in serena_by_tool.most_common():
            marker = ""
            if tool in {"find_referencing_symbols", "rename_symbol", "get_symbols_overview"}:
                marker = "  ← high-value query"
            print(f"  {tool:<32} {n:>4}{marker}")
    else:
        print("serena breakdown: (no serena calls in window)")

    if args.per_session:
        print()
        print("per-session (most recent first):")
        for sid, (c, mt) in sorted(by_session.items(), key=lambda x: -x[1][1]):
            scount = sum(v for k, v in c.items() if k.startswith(SERENA_PREFIX))
            gcount = c.get("Grep", 0)
            ts = time.strftime("%Y-%m-%d %H:%M", time.localtime(mt))
            print(f"  {ts}  {sid[:8]}  serena={scount:<3} grep={gcount:<3} total_tools={sum(c.values()):<4}")


if __name__ == "__main__":
    main()
