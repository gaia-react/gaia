---
type: concept
status: active
created: 2026-04-20
updated: 2026-07-04
tags: [concept, claude, hooks]
---

# Claude Hooks

Bash scripts that run on Claude Code tool calls. Configured in `.claude/settings.json` under `hooks.PreToolUse` (and other event types). Hook scripts filter by command content internally; they do not use per-hook `if:` patterns. (Claude Code's `if:` field requires `ToolUseContext` which isn't always available, surfacing as `"ToolUseContext is required for prompt hooks"` errors. Removed in v1.0.3.)

Exit code semantics:

- `exit 0`: pass; stderr is shown to Claude as advisory
- `exit 2`: block; stderr is shown to Claude as the reason
- JSON `permissionDecision: "deny"` on stdout: block via the structured API; the reason string is surfaced to Claude

## Bundled hooks

Hooks are grouped by the safeguard they enforce, not by event type.

### Source-edit safeguards (Edit|Write|MultiEdit)

- **`block-eslint-config-edit.sh`**: refuses edits to `eslint.config.mjs`. Reason: lint errors should be fixed in source code, not silenced in config.
- **`block-vitest-globals-tsconfig.sh`**: refuses adding `vitest/globals` to `tsconfig.json`. Reason: explicit imports (`import {describe, expect, test} from 'vitest'`) are clearer and per-file.
- **`block-lockfile-edit.sh`**: refuses direct edits to `pnpm-lock.yaml`. Lockfile changes must come from `pnpm install` / `pnpm add` / `pnpm remove`; manual edits routinely produce broken lockfiles. See [[pnpm]].

### Secrets safeguards (Edit|Write|MultiEdit)

- **`block-env-write.sh`**: refuses writes targeting any `.env` / `.env.*` file (allows `.env.example`). Closes the gap left by the Read-only `.env` deny rule in `settings.json`; `.env` files must remain gitignored and edited manually.
- **`block-secrets-write.sh`**: scans `new_string` / `content` / MultiEdit `edits[].new_string` payloads for secret-shaped values (AWS access keys, GitHub PATs, PEM private-key headers, dotenv-style `_TOKEN` / `_SECRET` / `_KEY` / `_PASSWORD` assignments with non-placeholder values). Allows known placeholders (`changeme`, `<…>`, `${VAR}`, `your-…`, etc.).

### Advisory (Edit|Write|MultiEdit)

- **`check-i18n-strings.sh`**: on edits to `app/pages/**/*.tsx` or `app/components/**/*.tsx`, prints a reminder to use `t()` from `useTranslation()`.
- **`check-story-exists.sh`**: on edits to `app/components/{Name}/index.tsx`, checks for `tests/index.stories.tsx` and reminds to add one if missing.

### Bash safeguards (Bash)

Each script reads `tool_input.command` from stdin and filters by content; there is no `if:` annotation on the hook entry.

- **`block-bare-test.sh`**: denies bare `pnpm test` / `npm test` (and `run test` variants); they start vitest watch mode. Requires `--run` for a one-shot pass. Command-position anchored: walks pipeline segments and acts only when `pnpm`/`npm` is the segment's command word, so the phrase inside a commit message or `--body` string is not an invocation and passes; the `--run` opt-out is scoped to the matched segment. `test:ci` / `test:lint-staged` keep their own carve-out. See [[Test Runner]].
- **`block-no-verify.sh`**: denies `git commit` or `git push` carrying a hook-bypass token: `--no-verify`, a falsy `HUSKY=` env prefix, or a `core.hooksPath` redirect. Also denies `git commit -n` (short form of `--no-verify`); `git push -n` (dry-run) stays allowed. Foreign-repo commands pass via the shared repo-scope helper. The hook walks command-position segments so a `-n` on another program (`grep`, `head`, `sort`, `tail`) is inert. Keeps an unambiguous whole-command fail-closed net for the tokens that cannot appear anywhere else (`--no-verify`, `HUSKY=`, `core.hooksPath=`).
- **`block-main-destructive-git.sh`**: denies (1) `git commit` while HEAD is `main`/`master`, (2) force-push to `main`/`master`, and (3) plain `git push` originating from `main`/`master` (PR-only flow, closes the "forgot to switch branches" footgun). Walks command-position segments so `git commit` text in an argument or a different program's flag does not trigger a false deny. Authoritative rule: [[Git Workflow]].
- **`block-rm-rf.sh`**: denies catastrophic `rm -rf` patterns: `--no-preserve-root`, absolute paths, `~` / `$HOME`, `.`, unscoped `*`, `.git`, `node_modules`. Allows scoped scratch paths (`.gaia/local/plans/*`, `.gaia/local/specs/*`, `.gaia/local/audit/*`, `.gaia/local/handoff/*`, `.gaia/cache/*`, `dist/*`, `build/*`).
- **`capture-red-observations.sh`** (PostToolUse, Bash): on a one-shot vitest run, re-invokes vitest with `--reporter=json` scoped to the agent's target, records each genuinely-failing per-test result to the RED-observation ledger (`.gaia/local/red-ledger/`). Records file, full test name, content signal, and failure kind. Collection/compile errors are excluded. Observe-only; always exits 0. See [[TDD RED Verification]].
- **`red-verify-commit-check.sh`** (PreToolUse, Bash deny): before each `git commit`, checks every new-at-HEAD test file against the RED-observation ledger. Requires a ledger RED whose content signal still matches the current test body; no matching entry denies the commit, naming the offending test. Fail-open on missing tooling or unparseable test files. See [[TDD RED Verification]].
- **`worthiness-presence-check.sh`** (PreToolUse, Bash deny): before each `gh pr merge`, scopes to the emergent test files the PR changed and denies the merge when a changed emergent test has no worthiness-ledger line matching its current content signal. Sits alongside `pr-merge-audit-check.sh` as an independent deny on the same event. Checks presence plus signal match only, never the verdict. No-op when zero emergent tests changed; fail-open on missing tooling or unparseable files. See [[Worthiness Presence Gate]].

### Code-search safeguard (Grep)

- **`serena-code-search-guard.sh`** (PreToolUse, Grep deny): blocks a `Grep` call whose pattern is a bare identifier (≥ 3 chars, no spaces or regex metacharacters) scoped to `app/**` or `test/**` TS/TSX, and points it at Serena's `find_symbol` / `find_referencing_symbols` / `get_symbols_overview` instead. Re-running the identical grep within 2 minutes passes (block-once escape), for the rare string-literal or comment search that happens to be identifier-shaped. No-ops unless Serena is a registered MCP server and the repo has a `tsconfig.json`, so adopters without Serena never see it. Closes the gap left by `.claude/rules/code-search.md` being path-scoped to `app/**`/`test/**` *edits*: the rule is absent from context during exploration, which is when the grep-vs-Serena decision actually gets made. See [[Serena Integration]].

### Advisory (Bash)

- **`pr-merge-audit-check.sh`**: reminds to spawn `code-review-audit`, fix issues, and push fixes before merging. See [[PR Merge Workflow]].

### Wiki coherence (multiple events)

The wiki sync system is convergent: the user's already-paid-for Claude session does the work via `/gaia-wiki sync`. Hooks only keep Claude _informed_; they never spawn `claude -p` sub-processes. See [[Wiki Sync]] for the full design.

- **`wiki-session-start.sh`** (SessionStart) / **`wiki-session-stop.sh`** (Stop): wiki coherence and `hot.md` refresh. The Stop hook also injects an end-of-session reminder when the session committed but `wiki/.state.json` did not advance (once-per-session via `.claude/wiki-safety-checked` marker). See [[Claude Integration Conventions]] § Wiki vendor relationship.
- **`wiki-drift-check.sh`** (UserPromptSubmit): first prompt of each session, compares `wiki/.state.json`'s `last_evaluated_sha` to HEAD; if drifted, injects a `[wiki state]` reminder. Once-per-session via `.claude/wiki-drift-checked` marker.
- **`wiki-recompact-sentinel.sh`** (PostCompact): on a context compaction event, drops a sentinel file (`.claude/wiki-recompact-pending`) so the next `UserPromptSubmit` knows to re-inject the hot cache. PostCompact command hooks cannot inject stdout into context directly, so the sentinel hands off to `wiki-recompact-inject.sh`. A no-op when `wiki/hot.md` does not exist.
- **`wiki-recompact-inject.sh`** (UserPromptSubmit): on the first prompt after a compaction (sentinel present), re-injects `wiki/hot.md` into context via stdout, then removes the sentinel so it fires exactly once per compaction. Replaces the claude-obsidian prompt-type PostCompact hook, which some Claude Code builds reject. A no-op on every prompt where no compaction has occurred.
- **`wiki-commit-nudge.sh`** (PostToolUse, Bash): fires after `git commit` invocations. Injects a `[wiki nudge]` line with the short SHA, subject, file count, and current drift count. Skips merge / amend / `wiki:` subjects to avoid loops. Never spawns sub-processes.
- **`wiki-squash-autocommits.sh`** (Stop): folds adjacent `wiki: auto-commit` subjects into a single PR-branch commit. Failed `gh pr create` / `gh pr merge` preserves the working tree (no silent reset).

### Other events

- **`intercept-init.sh`** (UserPromptExpansion, matcher `init`): emits `additionalContext` that overrides the built-in `/init` expansion and tells the model to invoke `/gaia-init` via the Skill tool. Does not block the turn; earlier `UserPromptSubmit + exit-2` design blocked the model from running at all.
- **`telemetry-task-postuse.sh`** (PostToolUse, matcher `Task`): fires when a subagent/Task completes. A thin pipe to `gaia telemetry parse-stdin`, which extracts structured-trailer events from the Task output and dispatches `gaia telemetry emit` for each. No-op when `.gaia/cli/gaia` is absent; always exits 0 so telemetry never blocks the flow. See [[Telemetry]].

`update-deps` and `update-gaia` are surfaced via the **statusline** (not a hook); see [[Claude Skills]] § Statusline update indicators. The statusline surface is chosen over a SessionStart `<system-reminder>` because system-reminders are visible only to the model; passive statusline indicators are visible to the user.

## Adding hooks

Ask Claude to add a hook; Claude will drop the script into `.claude/hooks/` and register it in `.claude/settings.json` via the `update-config` skill. Naming convention: `block-{noun}.sh` for blockers, `check-{noun}.sh` for advisory, `pre-{event}-{noun}.sh` for pre-event reminders. Blocker scripts begin with `#!/usr/bin/env bash` + `set -euo pipefail`, read stdin via `jq`, and either `exit 0`/`exit 2` or emit the structured `hookSpecificOutput.permissionDecision` JSON.

See [[Quality Gate]], [[Pre-commit Hooks]], [[Git Workflow]], [[Claude Integration Conventions]], [[TDD RED Verification]].
