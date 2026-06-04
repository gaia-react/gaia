# .gaia/tests

Internal tests for GAIA's Claude Code hooks, commands, and wiki sync system. Not shipped to adopters via `create-gaia`; excluded by `.gaia/release-exclude`.

## Layout

- `hooks/`; bats tests for shell hooks. Free, deterministic, runs on every commit.
- `smoke/`; release-gate harnesses with PASS/FAIL semantics. Subdirs: `wiki-sync/`, `wiki-promote/`, `uat-write/`. Routing rule: `.claude/rules/_internal/smoke.md`. See `smoke/README.md`.
- `observability/`; measurement tools that watch agent behavior over time and report metrics. NO PASS/FAIL. Subdirs: `serena/`. See `observability/serena/README.md` (no observability tree-level README needed for a single-occupant tree; revisit if a second observability tool lands).

## Running

### Hooks tests (free, fast)

```bash
bats .gaia/tests/hooks/
```

Requires `bats` (`brew install bats-core`). Tests are self-contained; they spin up tmp git repos via `helpers/tmp-git-repo.sh` and feed synthetic JSON to hooks via `helpers/mock-hook-input.sh`.

### Wiki-sync smoke tests (manual, billable)

```bash
bash .gaia/tests/smoke/run-all.sh
```

Requires `claude` CLI on PATH and a working subscription or API key. See `smoke/wiki-sync/README.md` for details and per-scenario commands.

### Serena usage scan (free, diagnostic)

```bash
python3 .gaia/tests/observability/serena/usage_scan.py
```

Reads `~/.claude/projects/.../*.jsonl` and prints tool-call counts. See `observability/serena/README.md`.

## Why a separate folder

`tests/` already exists in this repo for application tests. `.gaia/tests/` is dev infrastructure for the harness itself; different audience (GAIA maintainers, not adopters), different runtime (shell + claude CLI, not vitest).
