---
type: decision
status: superseded
priority: 2
date: 2026-04-20
created: 2026-04-20
updated: 2026-10-05
tags: [decision, testing, storybook]
---

# Decision: Test Components via Storybook `composeStory`

> Superseded. See [[Stories as Tests]]. A story's own `play` function, run by Vitest in Chromium, is the component test, so no test file re-composes a story with `composeStory` any more. This page keeps the reasoning for the stub-over-mock rule, which still holds.

Component tests used `composeStory(Default, Meta)` from `@storybook/react-vite` rather than rendering the component directly. Framework dependencies (React Router, i18n, state) are wired via stubs in `frontend/test/stubs/`, never via `vi.mock`.

## Rationale

- One source of truth: Storybook decorators and Vitest tests share setup
- Visual regression (Chromatic) and the component test both consume the same story
- Mocking `react-router` or `react-i18next` directly is fragile and easy to get wrong; stubs encapsulate that knowledge in one place
- A new story is a test the moment it carries a `play`

## When to mock

Only mock **external services** or **utilities** the component imports directly. Never mock framework deps; use the stubs.

See [[Component Testing]] rule for examples (including `useInputControl` with custom Conform-bound components).
