---
type: concept
status: active
created: 2026-04-20
updated: 2026-06-24
tags: [concept, a11y]
---

# Accessibility

## Static lint

`eslint-plugin-jsx-a11y` (included via the Airbnb ESLint config in [[gaia-lint]]) catches accessibility issues at development time. Runs as part of `pnpm lint`.

## Runtime testing

Static lint cannot catch violations that only exist in rendered output (color contrast, computed accessible names). Two axe-core helpers cover that gap:

- **Vitest** (`test/a11y.ts`, backed by `axe-core`): `expectNoA11yViolations(container, options?)` asserts zero violations; `runAxe` returns the raw `AxeResults` for manual inspection. The helper requires the jsdom environment and throws under happy-dom (axe-core is incompatible with happy-dom), so the test file must start with `// @vitest-environment jsdom`.
- **Playwright** (`.playwright/a11y.ts`, backed by `@axe-core/playwright`): `expectNoSeriousA11yViolations(page, testInfo, options?)` scans the fully rendered page against the WCAG 2.0/2.1 A and AA tags. Critical and serious violations fail the test; moderate and minor violations attach as `axe-advisory.json` and emit `console.warn`.

## Cross-references

- [[ESLint Fixes]]: playbook for lint-level violations.
- `.claude/skills/a11y-fixes/`: fix playbook for the axe-core runtime violations surfaced by the helpers above.
