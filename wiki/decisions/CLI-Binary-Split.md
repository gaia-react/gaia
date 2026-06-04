---
type: decision
status: active
priority: 1
date: 2026-05-09
created: 2026-05-09
updated: 2026-05-09
tags: [decision, distribution, maintainer, cli]
---

# CLI Binary Split

> [!note] Audience
> Maintainer-only. This page is excluded from adopter distribution by `.gaia/release-exclude`. Adopter-facing CLI documentation lives in public help text; this page documents the maintainer-only architecture choice.

The `.gaia/cli/` directory ships two binaries:

- **`gaia`** (adopter binary): public CLI, no `release` namespace. Shipped in tarballs.
- **`gaia-maintainer`** (maintainer-only binary): includes `release` namespace. Excluded from tarballs by `.gaia/release-exclude`.

## Why

The adopter binary previously baked in the entire `release` namespace (preflight, bump, changelog, scrub-wiki, manifest, scrub, runtime-deps, commit-and-tag). Though `release-exclude` stripped the source directory and the `/gaia-release` slash command, the binary was built before staging, so adopters running `gaia --help` saw `release …` and could invoke release subcommands. Release is maintainer-only: adopters never cut GAIA releases.

Tree-shaking via esbuild at build time requires two entry points:

- `.gaia/cli/src/index.ts`: excludes release imports and handlers; builds the adopter binary (829KB).
- `.gaia/cli/src/index.maintainer.ts`: includes release; builds the maintainer binary (984KB).

`pnpm bundle` produces both. `release-exclude` marks the maintainer binary as `category: 4` so it's omitted from adopter tarballs.

## Where it lives

- Binaries: `.gaia/cli/gaia` and `.gaia/cli/gaia-maintainer`
- Source: `.gaia/cli/src/`
- Build driver: `.gaia/cli/package.json` (`bundle` script)
- Release flow integration: `.claude/commands/gaia-release.md` (Step 7b rebuilds both binaries; Step 8 stages them manually if changed)
- Release exclusions: `.gaia/release-exclude` (`category: 4` for `gaia-maintainer`)

## Impact on the release flow

The `/gaia-release` command invokes `gaia-maintainer release <subcommand>` (never `gaia release`). When bundling at release time, both binaries are rebuilt in Step 7b to ensure the new version's `--version` output stays current.

## GAIA-internal code placement rule

GAIA-internal functionality that does not need to live in a specific folder for an external integration should live under `.gaia/`. The folders `.claude/`, `.specify/`, `app/`, and `bin/` exist at the root because Claude Code, spec-kit, the React Router app build, and the npm `bin` field require those exact locations. Everything else GAIA-owned (scripts, manifest, templates, statusline, cache, and the CLI source) belongs under `.gaia/`.

**Why:** The adopter's repo root is precious surface: every top-level folder competes with the adopter's own code for attention. Keeping GAIA-internal tooling under `.gaia/` makes the boundary between "GAIA template scaffolding" and "your app" obvious, simplifies `/update-gaia` semantics (one tree to manage), and matches the principle already applied to `.gaia/scripts/`, `.gaia/statusline/`, and `.gaia/templates/`.

**How to apply:**

- New GAIA-internal code: default to `.gaia/<subfolder>/`.
- Reviewing an existing root-level GAIA folder: ask "what external system requires this exact path?" If the answer is nothing, it is a candidate to move under `.gaia/`.
- `bin/gaia` stays at root because the npm `bin` field points there: that is an external integration constraint.
- `gaia-cli/` at root is a known exception pending migration.

## See also

- [[Bundle-time Scrub]]: enforcement of the distribution boundary after binaries ship.
- Related: `.gaia/release-exclude` (classification rules), `release.yml` (CI distribution gate).
