---
type: concept
status: active
created: 2026-04-20
updated: 2026-05-04
tags: [concept, lint]
---

# ESLint Fixes

> Rules now live in [[gaia-lint]] (`/src/configs/`). The non-obvious fixes below still apply unchanged — they're rule-level, not config-level.

Source: `.claude/rules/eslint-fixes.md`. **Always fix in source, never in config** (a hook blocks edits to `eslint.config.mjs`).

The rules below are the ones whose fix isn't obvious from the rule name. Trivial cases ("use the modern API name") aren't listed — query the `eslint-fixes` skill (`.claude/skills/eslint-fixes/`) for the full rule-by-rule playbook.

| Rule                                 | Fix                                                                                                                                                                                             |
| ------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `no-void`                            | Make the handler `async` and `await` the call instead of using `void`. The `void` operator hides unhandled rejections; converting to `async/await` surfaces them in the promise chain.          |
| `sonarjs/deprecation`                | **Fix the deprecation — never `eslint-disable`.** Deprecations land in this codebase as a signal to migrate, not a noise source. Common case: `z.email()` not `z.string().email()`.             |
| `testing-library/await-async-events` | All `userEvent` methods are async — `await userEvent.click(el)`. Forgetting the `await` causes flaky tests because assertions run before the event has propagated through React's effect queue. |

## composeStory testing patterns

Component tests use `composeStory` (see [[Component Testing]]) — this changes which testing-library / jest-dom rules trigger. The full pattern is in the `eslint-fixes` skill; the concept-level point is that `prefer-screen-queries` and `prefer-*` jest-dom matchers fire on every render-and-assert cycle, so wire them into muscle memory rather than fighting the lint each time.

See [[Zod]], [[React Testing Library]], [[gaia-lint]].
