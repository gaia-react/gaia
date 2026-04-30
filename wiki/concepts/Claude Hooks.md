---
type: concept
status: active
created: 2026-04-20
updated: 2026-04-30
tags: [concept, claude, hooks]
---

# Claude Hooks

Bash scripts that run on Claude Code tool calls. Configured in `.claude/settings.json` under `hooks.PreToolUse` (and other event types). The `Bash` matcher supports per-hook `if:` patterns so a single matcher block can fan out to command-specific hooks.

Exit code semantics:

- `exit 0` — pass; stderr is shown to Claude as advisory
- `exit 2` — block; stderr is shown to Claude as the reason
- JSON `permissionDecision: "deny"` on stdout — block via the structured API; the reason string is surfaced to Claude

## Bundled hooks

Hooks are grouped by the safeguard they enforce, not by event type.

### Source-edit safeguards (Edit|Write|MultiEdit)

- **`block-eslint-config-edit.sh`** — refuses edits to `eslint.config.mjs`. Reason: lint errors should be fixed in source code, not silenced in config.
- **`block-vitest-globals-tsconfig.sh`** — refuses adding `vitest/globals` to `tsconfig.json`. Reason: explicit imports (`import {describe, expect, test} from 'vitest'`) are clearer and per-file.
- **`block-lockfile-edit.sh`** — refuses direct edits to `pnpm-lock.yaml`. Lockfile changes must come from `pnpm install` / `pnpm add` / `pnpm remove`; manual edits routinely produce broken lockfiles. See [[pnpm]].

### Secrets safeguards (Edit|Write|MultiEdit)

- **`block-env-write.sh`** — refuses writes targeting any `.env` / `.env.*` file (allows `.env.example`). Closes the gap left by the Read-only `.env` deny rule in `settings.json`; `.env` files must remain gitignored and edited manually.
- **`block-secrets-write.sh`** — scans `new_string` / `content` / MultiEdit `edits[].new_string` payloads for secret-shaped values (AWS access keys, GitHub PATs, PEM private-key headers, dotenv-style `_TOKEN` / `_SECRET` / `_KEY` / `_PASSWORD` assignments with non-placeholder values). Allows known placeholders (`changeme`, `<…>`, `${VAR}`, `your-…`, etc.).

### Advisory (Edit|Write|MultiEdit)

- **`check-i18n-strings.sh`** — on edits to `app/pages/**/*.tsx` or `app/components/**/*.tsx`, prints a reminder to use `t()` from `useTranslation()`.
- **`check-story-exists.sh`** — on edits to `app/components/{Name}/index.tsx`, checks for `tests/index.stories.tsx` and reminds to add one if missing.

### Bash safeguards (Bash)

- **`block-bare-test.sh`** (`if: Bash(pnpm *)` and `if: Bash(npm *)`) — denies bare `pnpm test` / `npm test` (and `run test` variants); they start vitest watch mode. Requires `--run` for a one-shot pass. See [[Test Runner]].
- **`block-main-destructive-git.sh`** (`if: Bash(git *)`) — denies (1) `git commit` while HEAD is `main`/`master`, (2) force-push to `main`/`master`, and (3) plain `git push` originating from `main`/`master` (PR-only flow — closes the "forgot to switch branches" footgun). Authoritative rule: [[Git Workflow]].
- **`block-rm-rf.sh`** (`if: Bash(rm *)`) — denies catastrophic `rm -rf` patterns: `--no-preserve-root`, absolute paths, `~` / `$HOME`, `.`, unscoped `*`, `.git`, `node_modules`. Allows scoped scratch paths (`.claude/plans/*`, `.claude/audit/*`, `.gaia/cache/*`, `dist/*`, `build/*`).

### Advisory (Bash)

- **`pr-merge-audit-check.sh`** (`if: Bash(gh pr merge:*)`) — reminds to spawn `code-review-audit`, fix issues, and push fixes before merging. See [[PR Merge Workflow]].

### Wiki coherence (multiple events)

- **`wiki-session-start.sh`** (SessionStart) / **`wiki-session-stop.sh`** (Stop) / **`wiki-squash-autocommits.sh`** (Stop) — wiki coherence and `hot.md` refresh. See [[Claude Integration Conventions]] § Wiki vendor relationship for the full pair.
- **`wiki-update-evaluator.sh`** (PostToolUse, `if: Bash(git commit:*)`) — autonomous post-commit wiki evaluator. Captures the new HEAD sha, backgrounds a `claude -p --model sonnet --permission-mode bypassPermissions` sub-agent that reads the diff against `wiki/index.md` and either edits the relevant pages + appends to `wiki/log.md` (subject `wiki: evaluator update for <sha>`) or exits with `NO_UPDATE_NEEDED`. The sub-agent commits independently; subsequent wiki commits get folded by `wiki-squash-autocommits.sh` into the standard wiki-branch PR flow on main. Logs to `.claude/audit/wiki-evaluator-{sha}.log` (gitignored). Skips merge / amend / wiki auto-commit subjects to avoid loops; never blocks the user's commit (always exits 0).

### Other events

- **`intercept-init.sh`** (UserPromptSubmit) — blocks the built-in `/init` and auto-invokes `/gaia-init`.
- **`gaia-session-update-prompt.sh`** (SessionStart, `startup|resume`) — reads `.gaia/cache/update-check.json` and emits a `<system-reminder>` asking the user whether to run the `update-deps` skill (when outdated packages are detected) or the `update-gaia` skill (when a newer GAIA release is available). Sequences `deps` before `gaia` — only one prompt per session; if the deps prompt is snoozed, the hook falls through to gaia. Snoozes each kind for 6h after emit via `.gaia/cache/update-prompt-state.json`. Background-fires `.gaia/scripts/check-updates.sh` (TTL 6h) when the cache is stale. Silent on missing cache or missing `jq`. Never blocks. See [[Claude Skills]] § SessionStart update prompt.

## Adding hooks

Ask Claude to add a hook — Claude will drop the script into `.claude/hooks/` and register it in `.claude/settings.json` via the `update-config` skill. Naming convention: `block-{noun}.sh` for blockers, `check-{noun}.sh` for advisory, `pre-{event}-{noun}.sh` for pre-event reminders. Blocker scripts begin with `#!/usr/bin/env bash` + `set -euo pipefail`, read stdin via `jq`, and either `exit 0`/`exit 2` or emit the structured `hookSpecificOutput.permissionDecision` JSON.

See [[Quality Gate]], [[Pre-commit Hooks]], [[Git Workflow]], [[Claude Integration Conventions]].
