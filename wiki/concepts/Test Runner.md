---
type: concept
status: active
created: 2026-04-20
updated: 2026-04-21
tags: [concept, testing]
---

# Test Runner Rule

Never run bare `pnpm test` or `pnpm run test`; it starts vitest in watch mode. Use `pnpm test --run` for a single CI-style pass.

Machine-enforced by `.claude/hooks/block-bare-test.sh` (PreToolUse `Bash` hook matching `Bash(pnpm *)` and `Bash(npm *)`), which returns `exit 2` on a bare invocation.

See [[Vitest]], [[Pre-commit Hooks]], [[Claude Hooks]].
