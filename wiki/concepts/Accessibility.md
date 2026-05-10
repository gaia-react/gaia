---
type: concept
status: active
created: 2026-04-20
updated: 2026-05-10
tags: [concept, a11y]
---

# Accessibility

The accessibility stack runs at four layers. Each layer catches different categories of regression; together they cover what is realistically catchable without manual screen-reader review.

## Layers

| Layer            | Tool                                              | Where                                                                                                                          |
| ---------------- | ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Static lint      | `eslint-plugin-jsx-a11y` (Airbnb set)             | [[gaia-lint]] config; runs in `pnpm lint`                                                                                      |
| Component tests  | `axe-core` via `expectNoA11yViolations`           | `test/a11y.ts`; called from `app/components/*/tests/index.test.tsx`                                                            |
| End-to-end       | `@axe-core/playwright`                            | `.playwright/fixtures.ts` + `.playwright/a11y.ts`; called from `.playwright/e2e/*.spec.ts`                                     |
| Pre-merge audit  | `code-review-audit` agent's `a11y-axe` extension  | `.claude/agents/code-review-audit/a11y-axe.md`; runs as part of the mandatory pre-merge audit                                  |

## Authoring rule

`.claude/rules/accessibility.md` — keyboard, alt text, form labels, color, focus, ARIA. Auto-loads on edits to `app/components/**` and `app/pages/**`.

## Component test layer

`test/a11y.ts` exports `expectNoA11yViolations(container)`. The component scaffolder (`gaia scaffold component`) emits a test file with the assertion already wired plus the `// @vitest-environment jsdom` doc-comment. The doc-comment is required: happy-dom's `Node.prototype.isConnected` is getter-only and breaks axe-core's prototype mutation — see capricorn86/happy-dom#978.

## E2E layer

`.playwright/a11y.ts` exports `expectNoSeriousA11yViolations(page, testInfo)`. Failure threshold is `critical` and `serious`; `moderate` and `minor` violations are attached to the test info as JSON and surfaced via `console.warn`. The threshold lives in one place — adjust there, not in each spec.

## Fixing violations

The `a11y-fixes` skill (`.claude/skills/a11y-fixes/`) has a per-rule playbook covering color-contrast, label, image-alt, button-name, region, landmark-one-main, heading-order, focus-trap, and the rest of the common axe rules. Invoke it when triaging axe output from any of the three runtimes.

## Cross-references

- [[Component Testing]] — `composeStory` pattern that wraps the axe-asserted render.
- [[Code Review Audit Agent]] — extension loader and audit lifecycle.
- [[ESLint Fixes]] — sister playbook for lint-level violations.
