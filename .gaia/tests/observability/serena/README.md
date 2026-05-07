# Serena usage scan

Reads Claude Code transcripts at `~/.claude/projects/-Users-stevensacks-Development-gaia-react-gaia/*.jsonl` and reports per-window counts of:

- Total tool calls
- Serena (`mcp__serena__*`) calls and their breakdown by sub-tool
- Grep / Glob / Read calls
- Serena/Grep ratio
- Sessions that touched Serena

This is a **measurement tool**, not a test. It has no PASS/FAIL. The output answers a single question: is the Serena MCP routing rule (`.claude/rules/code-search.md`) actually changing behavior in real sessions, or is it being ignored?

## Why this exists

Serena was wired in via PR #82 (May 2026). The routing rule directs symbol-level queries to Serena's LSP-backed tools instead of Read+grep. The kill criterion for the rule lives in the dogfooding journal — if the week-long trial logs fewer than 5 "win" entries, the rule gets reverted.

The scan is the quantitative half of that decision. It tells you whether Serena is being invoked at all, which sub-tools dominate, and how Serena calls compare to grep volume in the same window.

## Usage

```bash
# Last 7 days (default)
python3 .gaia/tests/observability/serena/usage_scan.py

# Last day
python3 .gaia/tests/observability/serena/usage_scan.py --days 1

# Since a specific date
python3 .gaia/tests/observability/serena/usage_scan.py --since 2026-05-04

# Per-session breakdown
python3 .gaia/tests/observability/serena/usage_scan.py --per-session
```

## Reading the output

- **`serena/grep ratio`** — the headline number. >= 1.0 means Serena is the default for symbol queries. < 0.3 means the rule is mostly being ignored.
- **`sessions touching serena`** — a low number with a high `serena calls` total means a single session is dominating; not representative.
- **`serena breakdown`** — `find_referencing_symbols`, `rename_symbol`, and `get_symbols_overview` are flagged as high-value queries (the ones grep fundamentally can't replicate). If those three dominate, the rule is earning its keep. If `find_file` and `activate_project` dominate, Serena is being used for things grep already does fine — neutral signal.

## Caveats

- Transcript dir path is hardcoded to this repo's project ID. If GAIA is checked out under a different path, edit `TRANSCRIPT_DIR` at the top of `usage_scan.py`.
- Counts every `tool_use` block in assistant messages. Failed tool calls and parallel tool calls in the same message count separately.
- `mtime`-filtered, not message-timestamp-filtered. Editing an old transcript bumps it into a recent window.

## Related

- `.claude/rules/code-search.md` — the routing rule the scan measures.
- `wiki/concepts/Serena Integration.md` — the wiki page on Serena's role and division of labor with the wiki.
