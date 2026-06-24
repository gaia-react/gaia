---
type: dependency
status: active
package: '@testing-library/react'
version: 16.3.2
role: integration-testing
created: 2026-04-20
updated: 2026-06-24
tags: [dependency, testing]
---

# React Testing Library

Used with [[Vitest]] for component/integration tests. GAIA's `test/rtl.tsx` module:

- Registers an `afterEach` that calls `resetTestData()` then `cleanup()` after each test
- Initializes i18next globally via a side-effect import of `.storybook/i18next`
- Re-exports the library (`render`, `screen`, etc.)

Tests should `import {render, screen} from 'test/rtl'` (not directly from the library).

See [[Component Testing]], [[Testing]].
