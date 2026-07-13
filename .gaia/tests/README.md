# .gaia/tests

Internal tests for GAIA's Claude Code hooks, commands, and wiki sync system. Not shipped to adopters via `create-gaia`; excluded by `.gaia/release-exclude`.

## Layout

- `shell-lint.sh`; shellcheck gate over every tracked `*.sh` in the repo. Free, deterministic, runs in CI on every PR that touches a shell script (`.github/workflows/shell-lint.yml`).
- `hooks/`; bats tests for shell hooks. Free, deterministic, runs on every commit.
- `smoke/`; release-gate harnesses with PASS/FAIL semantics. Subdirs: `wiki-sync/`, `wiki-promote/`, `uat-write/`. Routing rule: `.claude/rules/maintainers/smoke.md`. See `smoke/README.md`.
- `observability/`; measurement tools that watch agent behavior over time and report metrics. NO PASS/FAIL. Subdirs: `serena/`. See `observability/serena/README.md` (no observability tree-level README needed for a single-occupant tree; revisit if a second observability tool lands).

## Running

### Shell lint (free, fast)

```bash
bash .gaia/tests/shell-lint.sh
```

Requires `shellcheck` (`brew install shellcheck`). Lints every tracked `*.sh` at severity `warning`; exits non-zero on any finding. The `info`/`style` tiers are below the gate's floor because they are dominated here by intentional single-quoted `jq`/`awk` programs (SC2016) and unresolvable dynamic `source` paths (SC1091); see those tiers with `shellcheck -S style <file>`.

This is the deterministic backstop for the `code-audit-maintainer-shell` agent, which already treats shellcheck as an authoritative oracle but is model-dispatched and advisory-only. The agent keeps the lenses shellcheck cannot model (hook fail-open, stdin-JSON shape, `jq -n` injection safety).

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
