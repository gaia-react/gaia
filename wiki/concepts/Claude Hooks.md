---
type: concept
status: active
created: 2026-04-20
updated: 2026-05-03
tags: [concept, claude, hooks]
---

# Claude Hooks

Bash scripts that run on Claude Code tool calls. Configured in `.claude/settings.json` under `hooks.PreToolUse` (and other event types). Hook scripts filter by command content internally — they do not use per-hook `if:` patterns. (Claude Code's `if:` field requires `ToolUseContext` which isn't always available, surfacing as `"ToolUseContext is required for prompt hooks"` errors. Removed in v1.0.3.)

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

Each script reads `tool_input.command` from stdin and filters by content — there is no `if:` annotation on the hook entry.

- **`block-bare-test.sh`** — denies bare `pnpm test` / `npm test` (and `run test` variants); they start vitest watch mode. Requires `--run` for a one-shot pass. See [[Test Runner]].
- **`block-main-destructive-git.sh`** — denies (1) `git commit` while HEAD is `main`/`master`, (2) force-push to `main`/`master`, and (3) plain `git push` originating from `main`/`master` (PR-only flow — closes the "forgot to switch branches" footgun). Handles `git -C <path>` invocations correctly. Authoritative rule: [[Git Workflow]].
- **`block-rm-rf.sh`** — denies catastrophic `rm -rf` patterns: `--no-preserve-root`, absolute paths, `~` / `$HOME`, `.`, unscoped `*`, `.git`, `node_modules`. Allows scoped scratch paths (`.gaia/local/plans/*`, `.gaia/local/audit/*`, `.gaia/local/handoff/*`, `.gaia/cache/*`, `dist/*`, `build/*`).

### Advisory (Bash)

- **`pr-merge-audit-check.sh`** — reminds to spawn `code-review-audit`, fix issues, and push fixes before merging. See [[PR Merge Workflow]].

### Wiki coherence (multiple events)

The wiki sync system is convergent: the user's already-paid-for Claude session does the work via `/gaia wiki sync`. Hooks only keep Claude _informed_ — they never spawn `claude -p` sub-processes. See [[Wiki Sync]] for the full design.

- **`wiki-session-start.sh`** (SessionStart) / **`wiki-session-stop.sh`** (Stop) — wiki coherence and `hot.md` refresh. The Stop hook also injects an end-of-session reminder when the session committed but `wiki/.state.json` did not advance (once-per-session via `.claude/wiki-safety-checked` marker). See [[Claude Integration Conventions]] § Wiki vendor relationship.
- **`wiki-drift-check.sh`** (UserPromptSubmit) — first prompt of each session, compares `wiki/.state.json`'s `last_evaluated_sha` to HEAD; if drifted, injects a `[wiki state]` reminder. Once-per-session via `.claude/wiki-drift-checked` marker.
- **`wiki-commit-nudge.sh`** (PostToolUse, Bash) — fires after `git commit` invocations. Injects a `[wiki nudge]` line with the short SHA, subject, file count, and current drift count. Skips merge / amend / `wiki:` subjects to avoid loops. Never spawns sub-processes.
- **`wiki-squash-autocommits.sh`** (Stop) — folds adjacent `wiki: auto-commit` subjects into a single PR-branch commit. Failed `gh pr create` / `gh pr merge` preserves the working tree (no silent reset).

### Other events

- **`intercept-init.sh`** (UserPromptExpansion, matcher `init`) — emits `additionalContext` that overrides the built-in `/init` expansion and tells the model to invoke `/gaia-init` via the Skill tool. Does not block the turn — earlier `UserPromptSubmit + exit-2` design blocked the model from running at all.

`update-deps` and `update-gaia` are surfaced via the **statusline** (not a hook) — see [[Claude Skills]] § Statusline update indicators. The statusline surface is chosen over a SessionStart `<system-reminder>` because system-reminders are visible only to the model; passive statusline indicators are visible to the user.

## Adding hooks

Ask Claude to add a hook — Claude will drop the script into `.claude/hooks/` and register it in `.claude/settings.json` via the `update-config` skill. Naming convention: `block-{noun}.sh` for blockers, `check-{noun}.sh` for advisory, `pre-{event}-{noun}.sh` for pre-event reminders. Blocker scripts begin with `#!/usr/bin/env bash` + `set -euo pipefail`, read stdin via `jq`, and either `exit 0`/`exit 2` or emit the structured `hookSpecificOutput.permissionDecision` JSON.

See [[Quality Gate]], [[Pre-commit Hooks]], [[Git Workflow]], [[Claude Integration Conventions]].
