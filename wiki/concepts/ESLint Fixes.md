---
type: concept
status: active
created: 2026-04-20
updated: 2026-10-05
tags: [concept, lint]
---

# ESLint Fixes

> Rules live in [[gaia-lint]] (`src/configs/`). The non-obvious fixes below still apply unchanged; they're rule-level, not config-level.

**Always fix in source, never in config** (a hook puts every edit to `eslint.config.*` to the operator for confirmation, including the sanctioned preset-spread migration, see [[Claude Hooks]]).

The rules below are the ones whose fix isn't obvious from the rule name. Trivial cases ("use the modern API name") aren't listed; query the `eslint-fixes` skill (`.claude/skills/eslint-fixes/`) for the full rule-by-rule playbook.

| Rule                                 | Fix                                                                                                                                                                                            |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `no-void`                            | Make the handler `async` and `await` the call instead of using `void`. The `void` operator hides unhandled rejections; converting to `async/await` surfaces them in the promise chain.         |
| `sonarjs/deprecation`                | **Fix the deprecation; never `eslint-disable`.** Deprecations land in this codebase as a signal to migrate, not a noise source. Common case: `z.email()` not `z.string().email()`.             |
| Testing Library `await-async-events` | All `userEvent` methods are async: `await userEvent.click(el)`. Forgetting the `await` causes flaky tests because assertions run before the event has propagated through React's effect queue. |

## Story play testing patterns

Component tests are story play functions (see [[Stories as Tests]] and [[Component Testing]]); the Testing Library and jest-dom rules apply to the `storybook/test` queries and matchers a play uses. The full pattern is in the `eslint-fixes` skill; the concept-level point is that the screen-query and jest-dom matcher preferences fire on every query-and-assert cycle, so wire them into muscle memory rather than fighting the lint each time.

See [[Zod]], [[Stories as Tests]], [[gaia-lint]].
