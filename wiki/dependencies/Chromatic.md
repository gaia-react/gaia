---
type: dependency
status: active
package: chromatic
version: 17.4.1
role: visual-regression
created: 2026-04-20
updated: 2026-06-24
tags: [dependency, testing, visual]
---

# Chromatic

Visual regression service that consumes Storybook stories. Runs in CI via `.github/workflows/chromatic.yml`.

- `pnpm chromatic`: uploads stories
- `CHROMATIC_PROJECT_TOKEN`: env var on CI
- `--auto-accept-changes 'main'`: auto-accept baseline shifts on `main`
- `--only-changed`, `--exit-zero-on-changes`: efficient PR runs
- `--exit-once-uploaded`: return after upload instead of waiting for the build
- `--storybook-build-dir 'storybook-static'`: consume the prebuilt Storybook
- `--skip '@(renovate/**|dependabot/**)'`: skip visual review on bot branches

## CI gating

The `.github/workflows/chromatic.yml` workflow triggers on every `push` but does not always run Chromatic:

- Commits whose subject matches `chore(deps):` or `chore(deps-dev):` short-circuit (dep-bump PRs run the quality gate locally before pushing).
- A `paths-filter` allowlists Storybook-affecting changes (`app/**`, `.storybook/**`, `public/**`, `package.json`, `pnpm-lock.yaml`, `tsconfig*.json`, `vite.config.*`, and the workflow file). Pushes touching nothing on the list report the required check green without running Chromatic.

## Opt-out

If you don't want Chromatic, see [[Chromatic Opt-Out]].
