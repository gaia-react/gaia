---
type: dependency
status: active
package: vitest
version: ^4.1.4
role: test-runner
created: 2026-04-20
updated: 2026-04-20
tags: [dependency, testing]
---

# Vitest

Test runner for unit + integration tests. Paired with `happy-dom` and [[React Testing Library]].

## Companion packages

- `@vitest/coverage-v8`: coverage reports
- `@vitest/eslint-plugin`: Vitest-aware lint rules

## Conventions

- `*.test.{ts,tsx}` anywhere in `app/`
- Tests live in `tests/` subfolders next to components/pages/hooks
- Explicit imports: `import {describe, expect, test} from 'vitest'`: never enable `globals` in tsconfig (blocked by hook)

## Run rules

> [!warning] Never run bare `pnpm test` in CI
> Bare `pnpm test` starts watch mode. Use `pnpm test --run` for CI-style. See [[Test Runner]] rule.

See [[Testing]], [[Component Testing]].
