---
type: dependency
status: active
package: chromatic
version: ^16.3.0
role: visual-regression
created: 2026-04-20
updated: 2026-04-20
tags: [dependency, testing, visual]
---

# Chromatic

Visual regression service that consumes Storybook stories. Runs in CI via `.github/workflows/chromatic.yml`.

- `pnpm chromatic`: uploads stories
- `CHROMATIC_PROJECT_TOKEN`: env var on CI
- `--auto-accept-changes 'main'`: auto-accept baseline shifts on `main`
- `--only-changed`, `--exit-zero-on-changes`: efficient PR runs

## Opt-out

If you don't want Chromatic, see [[Chromatic Opt-Out]].
