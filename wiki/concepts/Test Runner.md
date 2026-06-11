---
type: concept
status: active
created: 2026-04-20
updated: 2026-06-11
tags: [concept, testing]
---

# Test Runner Rule

Never run bare `pnpm test` or `pnpm run test`; it starts vitest in watch mode. Use `pnpm test --run` for a single CI-style pass.

Machine-enforced by `.claude/hooks/block-bare-test.sh` (PreToolUse `Bash` hook matching `Bash(pnpm *)` and `Bash(npm *)`), which returns `exit 2` on a bare invocation. The hook is command-position anchored: it splits the command on pipeline separators (`| & ; ( )`), strips leading env-var assignments, and acts only when `pnpm`/`npm` is the resulting command word and `test` is the script position. Text that merely mentions the phrase inside a commit message or `--body` string is not an invocation and passes. The `--run` opt-out is scoped to the matched segment, not the whole command line. `test:ci` / `test:lint-staged` are exempt via a `test:` token boundary.

See [[Vitest]], [[Pre-commit Hooks]], [[Claude Hooks]].
