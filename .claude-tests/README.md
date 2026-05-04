# .claude-tests

Internal tests for GAIA's Claude Code hooks, commands, and wiki sync system. Not shipped to adopters via `create-gaia` — excluded by `.gaia/release-exclude`.

## Layout

- `hooks/` — bats tests for shell hooks. Free, deterministic, runs on every commit.
- `smoke/wiki-sync/` — claude-driven E2E scenarios for `/wiki-sync`. Costs ~$0.10 per full run on Sonnet. Manual / pre-release.
- `smoke/serena/` — python scanner that reports Serena vs grep usage from real Claude transcripts. Free. Diagnostic, not pass/fail.

## Running

### Hooks tests (free, fast)

```bash
bats .claude-tests/hooks/
```

Requires `bats` (`brew install bats-core`). Tests are self-contained — they spin up tmp git repos via `helpers/tmp-git-repo.sh` and feed synthetic JSON to hooks via `helpers/mock-hook-input.sh`.

### Wiki-sync smoke tests (manual, billable)

```bash
bash .claude-tests/smoke/run-all.sh
```

Requires `claude` CLI on PATH and a working subscription or API key. See `smoke/wiki-sync/README.md` for details and per-scenario commands.

### Serena usage scan (free, diagnostic)

```bash
python3 .claude-tests/smoke/serena/usage_scan.py
```

Reads `~/.claude/projects/.../*.jsonl` and prints tool-call counts. See `smoke/serena/README.md`.

## Why a separate folder

`tests/` already exists in this repo for application tests. `.claude-tests/` is dev infrastructure for the harness itself — different audience (GAIA maintainers, not adopters), different runtime (shell + claude CLI, not vitest).
