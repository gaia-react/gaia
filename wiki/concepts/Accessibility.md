---
type: concept
status: active
created: 2026-04-20
updated: 2026-10-05
tags: [concept, a11y]
---

# Accessibility

## Static lint

`eslint-plugin-jsx-a11y` (included via the Airbnb ESLint config in [[gaia-lint]]) catches accessibility issues at development time. Runs as part of `pnpm lint`.

## Runtime testing

Static lint cannot catch violations that only exist in rendered output (color contrast, computed accessible names). Two axe-core runs cover that gap:

- **Storybook, under Vitest** (`@storybook/addon-a11y`): every story is axe-checked in headless Chromium, with or without a `play`. The config is `parameters.a11y` in `frontend/.storybook/preview.ts`. It runs the WCAG 2.0/2.1 A and AA tags, the same tag set as the Playwright scan, and fails on a violation of **any** impact. That is stricter than the scan's critical-and-serious filter on purpose: a moderate WCAG failure is still a failure, and it is cheapest to fix while the story is being written. Only the `region` rule is disabled, because a story renders a fragment outside the page landmarks. It checks the **light theme only**.
- **Playwright** (`frontend/.playwright/a11y.ts`, backed by `@axe-core/playwright`): `expectNoSeriousA11yViolations(page, testInfo, options?)` scans the fully rendered page against the WCAG 2.0/2.1 A and AA tags, in light and dark. Critical and serious violations fail the test; moderate and minor violations attach as `axe-advisory.json` and emit `console.warn`. Run `pnpm pw` on any theme or token change, since the dark theme is checked only here.

Opting a story out (`parameters.a11y.test: 'off'` or a disabled rule) needs a reason written beside it; fixing the markup is the default.

addon-a11y scopes axe to the body, so it cannot see page-level structure on its own. A page story asserts one level-1 heading and one `main` landmark in its `play`.

## Cross-references

- [[ESLint Fixes]]: playbook for lint-level violations.
- `.claude/skills/a11y-fixes/`: fix playbook for the axe-core runtime violations surfaced by the runs above.
