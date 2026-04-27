---
type: concept
status: active
created: 2026-04-20
updated: 2026-04-27
tags: [concept, lint]
---

# ESLint Fixes

> Rules now live in [[gaia-lint]] (`/src/configs/`). The fixes below still apply unchanged — they're rule-level, not config-level.

Source: `.claude/rules/eslint-fixes.md`. Patterns for resolving specific ESLint errors. Always fix in source, never in config (a hook blocks edits to `eslint.config.mjs`).

| Rule                                 | Fix                                                                                     |
| ------------------------------------ | --------------------------------------------------------------------------------------- |
| `no-void`                            | Make handler `async` and `await` the call instead of `void`                             |
| `canonical/export-specifier-newline` | Use inline `export const X = …` instead of grouped `export {X}`                         |
| `no-shadow` trailing `_`             | Remove autofix `_` suffix once shadowing is resolved                                    |
| `sonarjs/deprecation`                | Fix the deprecation — never `eslint-disable`. E.g. `z.email()` not `z.string().email()` |
| `you-dont-need-lodash-underscore/*`  | Use native JS — `arr.find(fn)` not `_.find(arr, fn)`                                    |
| `testing-library/prefer-screen-queries` | Use `screen.getBy*` instead of destructuring from `render()`                        |
| `testing-library/await-async-events` | `await userEvent.click(el)` — all `userEvent` methods are async                         |
| `jest-dom/prefer-*`                  | Use jest-dom matchers: `toHaveValue`, `toBeChecked`, `toHaveTextContent`, etc.          |

See [[Zod]], [[React Testing Library]], [[gaia-lint]].
