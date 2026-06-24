---
type: concept
status: active
created: 2026-04-20
updated: 2026-06-24
tags: [concept, testing]
---

# Test Runner Rule

Never run bare `pnpm test` or `pnpm run test`; the `test` script is plain `vitest`, which starts in watch mode. Use `pnpm test --run` for a single CI-style pass. The one-shot scripts are `test:ci` (`vitest --run --passWithNoTests --coverage --bail 1`) and `test:lint-staged` (`vitest --run --changed --passWithNoTests --bail 1`).

Machine-enforced by `.claude/hooks/block-bare-test.sh`, a PreToolUse `Bash` hook (matcher `Bash`), which returns `exit 2` on a bare invocation. The script itself anchors on the command word, the `pnpm`/`npm` matching lives in its body, not in the settings matcher. The hook is command-position anchored: it splits the command on pipeline separators (`| & ; ( )`), strips leading env-var assignments, and acts only when `pnpm`/`npm` is the resulting command word and `test` is the script position. Text that merely mentions the phrase inside a commit message or `--body` string is not an invocation and passes. The `--run` opt-out is scoped to the matched segment, not the whole command line. `test:ci` / `test:lint-staged` are exempt via a `test:` token boundary.

See [[Vitest]], [[Pre-commit Hooks]], [[Claude Hooks]].
