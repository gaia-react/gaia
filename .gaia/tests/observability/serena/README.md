# Serena usage scan

Reads Claude Code transcripts at `~/.claude/projects/-Users-stevensacks-Development-gaia-react-gaia/*.jsonl` and reports per-window counts of:

- Total tool calls
- Serena (`mcp__serena__*`) calls and their breakdown by sub-tool
- Grep (structured tool) / Glob / Read calls
- Shell `grep`/`rg`/`ag` searches issued through the `Bash` tool
- Serena/grep ratio, computed against the combined (Grep tool + shell) denominator
- Sessions that touched Serena

This is a **measurement tool**, not a test. It has no PASS/FAIL. The output answers a single question: is the Serena MCP routing rule (`.claude/rules/code-search.md`) actually changing behavior in real sessions, or is it being ignored?

## Why this exists

Serena was wired in via PR #82 (May 2026). The routing rule directs symbol-level queries to Serena's LSP-backed tools instead of Read+grep. The kill criterion for the rule lives in the dogfooding journal; if the week-long trial logs fewer than 5 "win" entries, the rule gets reverted.

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

- **`Grep (tool)`**; structured `Grep` tool calls only.
- **`shell grep/rg (Bash)`**; `grep`/`rg`/`ag` searches issued as shell commands through the `Bash` tool. This is the surface the routing rule and its guard target, and it was previously invisible to the scan, a session can log zero structured `Grep` calls while running dozens of shell greps. Counting it keeps the fair-test denominator honest.
- **`grep (Grep + shell)`**; the combined search-volume figure. `Grep (tool)` + `shell grep/rg (Bash)`. The two component lines stay printed so historical numbers keyed on the structured `Grep` count remain comparable.
- **`serena/grep ratio`**; the headline number, computed against the **combined** denominator so it is not inflated by ignoring shell greps. >= 1.0 means Serena is the default for symbol queries. < 0.3 means the rule is mostly being ignored.
- **`sessions touching serena`**; a low number with a high `serena calls` total means a single session is dominating; not representative.
- **`serena breakdown`**; `find_referencing_symbols`, `rename_symbol`, and `get_symbols_overview` are flagged as high-value queries (the ones grep fundamentally can't replicate). If those three dominate, the rule is earning its keep. If `find_file` and `activate_project` dominate, Serena is being used for things grep already does fine; neutral signal.

### Shell-grep matching heuristic

The shell-grep count is a documented heuristic, not a shell parser, so the number is interpretable and the convene port can reproduce it exactly. A `Bash` command counts a shell search for each `grep`/`rg`/`ag` word at a **command position**: the start of the command, or immediately after a shell separator (`|`, `||`, `&&`, `;`, a newline, or a subshell / command-substitution opener `(` `` ` `` `$(`). This is intentionally **broader** than the routing guard, which fires only on a single bare-identifier grep. The scan wants total shell-search volume, so it also counts searches inside pipelines such as `git diff | grep foo` that the guard deliberately skips. A pipeline with two searches (`rg foo | grep bar`) counts as two.

Known, accepted misses (kept fixed so the numbers stay comparable across runs and repos):

- `git grep` is **not** counted; `grep` there is a git subcommand, not a command-position `grep`/`rg`/`ag` invocation, and it is a distinct, endorsed search tool rather than the ad-hoc symbol-grep surface.
- grep variants outside the `grep`/`rg`/`ag` family (`egrep`, `fgrep`, `zgrep`) and searches hidden behind aliases or `xargs` are not counted.
- A literal `grep` that happens to sit at a command position can be over-counted. Both directions are rare and acceptable for a denominator.

## Caveats

- Transcript dir path is hardcoded to this repo's project ID. If GAIA is checked out under a different path, edit `TRANSCRIPT_DIR` at the top of `usage_scan.py`.
- Counts every `tool_use` block in assistant messages. Failed tool calls and parallel tool calls in the same message count separately.
- `mtime`-filtered, not message-timestamp-filtered. Editing an old transcript bumps it into a recent window.
- The shell-grep count is a heuristic over the raw `Bash` command string (see above), not a real shell parse; it counts intent to search, whether or not the command actually ran or matched anything. The `--per-session` breakdown still reports the structured `Grep` count only; the shell-grep figure is a window total.

## Related

- `.claude/rules/code-search.md`; the routing rule the scan measures.
- `.claude/hooks/serena-code-search-guard.sh`; the PreToolUse guard that enforces the routing rule by blocking bare-identifier greps on TS/TSX when Serena is registered.
- `wiki/concepts/Serena Integration.md`; the wiki page on Serena's role and division of labor with the wiki.
