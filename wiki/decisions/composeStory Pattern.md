---
type: decision
status: active
priority: 2
date: 2026-04-20
created: 2026-04-20
updated: 2026-04-20
tags: [decision, testing, storybook]
---

# Decision: Test Components via Storybook `composeStory`

Component tests use `composeStory(Default, Meta)` from `@storybook/react-vite` rather than rendering the component directly. Framework dependencies (React Router, i18n, state) are wired via stubs in `test/stubs/`, never via `vi.mock`.

## Rationale

- One source of truth: Storybook decorators and Vitest tests share setup
- Visual regression (Chromatic) and integration tests both consume the same story
- Mocking `react-router` or `react-i18next` directly is fragile and easy to get wrong; stubs encapsulate that knowledge in one place
- New stories automatically get a story-driven test scaffold

## When to mock

Only mock **external services** or **utilities** the component imports directly. Never mock framework deps; use the stubs.

See [[Component Testing]] rule for examples (including `useInputControl` with custom Conform-bound components).
