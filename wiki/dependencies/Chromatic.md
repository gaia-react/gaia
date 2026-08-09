---
type: dependency
status: active
package: chromatic
version: 17.7.2
role: visual-regression
created: 2026-04-20
updated: 2026-07-07
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

## Preview publishes no environment values

Before uploading, the workflow builds Storybook once with sentinel values standing in for every key `app/env.server.ts`'s `schema` declares except `NODE_ENV` (which needs its real value for the build itself), then fails if any sentinel survives into `storybook-static/`. The published preview is a static Vite artifact with no build-time `define` substitution wired to it, so this step asserts that fact directly rather than trusting it never regresses: a substitution re-added to any Storybook config or plugin that inlined an env value would fail the build instead of silently shipping a secret- or deployment-value-carrying preview.

## Opt-out

If you don't want Chromatic, see [[Chromatic Opt-Out]].
