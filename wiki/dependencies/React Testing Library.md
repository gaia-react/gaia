---
type: dependency
status: active
package: '@testing-library/react'
role: integration-testing
created: 2026-04-20
updated: 2026-10-03
tags: [dependency, testing]
---

# React Testing Library

Used with [[Vitest]] for component/integration tests. The `frontend/test/rtl.tsx` module:

- Registers an `afterEach` that calls `resetTestData()` then `cleanup()` after each test
- Initializes i18next globally via a side-effect import of `frontend/.storybook/i18next`
- Re-exports the library (`render`, `screen`, etc.)

Tests should `import {render, screen} from 'test/rtl'` (not directly from the library).

See [[Component Testing]], [[Testing]].
