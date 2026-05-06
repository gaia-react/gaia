#!/usr/bin/env python3
"""Scan Claude Code transcripts and report Serena vs grep usage.

Default: last 7 days of transcripts for the gaia-react/gaia project.
Override with --days N or --since YYYY-MM-DD.

Usage:
    python3 .claude-tests/smoke/serena/usage_scan.py
    python3 .claude-tests/smoke/serena/usage_scan.py --days 1
    python3 .claude-tests/smoke/serena/usage_scan.py --since 2026-05-04
"""
import argparse
import json
import sys
import time
from collections import Counter
from glob import glob
from pathlib import Path

TRANSCRIPT_DIR = Path.home() / ".claude/projects/-Users-stevensacks-Development-gaia-react-gaia"

SEARCH_TOOLS = {"Grep", "Glob", "Read"}
SERENA_PREFIX = "mcp__serena__"


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
    """Yield (tool_name, session_id) for every tool_use in a transcript."""
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
                    yield b.get("name", "unknown"), sid


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

    for p in files:
        sid = p.stem
        local = Counter()
        for tool, _ in iter_tool_uses(p):
            overall[tool] += 1
            local[tool] += 1
            if tool.startswith(SERENA_PREFIX):
                serena_by_tool[tool[len(SERENA_PREFIX):]] += 1
        by_session[sid] = (local, p.stat().st_mtime)

    serena_total = sum(v for k, v in overall.items() if k.startswith(SERENA_PREFIX))
    grep_total = overall.get("Grep", 0)
    glob_total = overall.get("Glob", 0)
    read_total = overall.get("Read", 0)
    all_tools = sum(overall.values())
    sessions_with_serena = sum(1 for sid, (c, _) in by_session.items() if any(k.startswith(SERENA_PREFIX) for k in c))

    print(f"window: {time.strftime('%Y-%m-%d', time.localtime(cutoff))} → now")
    print(f"transcripts in window: {len(files)}  ·  sessions touching serena: {sessions_with_serena}")
    print()
    print(f"  total tool calls : {all_tools}")
    print(f"  serena calls     : {serena_total}  ({100*serena_total/all_tools:.1f}% of all)" if all_tools else "")
    print(f"  Grep             : {grep_total}")
    print(f"  Glob             : {glob_total}")
    print(f"  Read             : {read_total}")
    if grep_total:
        print(f"  serena/grep ratio: {serena_total/grep_total:.2f}")
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
