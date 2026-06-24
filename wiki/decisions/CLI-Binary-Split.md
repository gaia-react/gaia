---
type: decision
status: active
priority: 1
date: 2026-05-09
created: 2026-05-09
updated: 2026-06-24
tags: [decision, distribution, maintainer, cli]
---

# CLI Binary Split

> [!note] Audience
> Maintainer-only. This page is excluded from adopter distribution by `.gaia/release-exclude`. Adopter-facing CLI documentation lives in public help text; this page documents the maintainer-only architecture choice.

The `.gaia/cli/` directory ships two binaries:

- **`gaia`** (adopter binary): public CLI, no `release` namespace. Carries CI/runner subcommands (`ci-revert`, `ci-stale-check`, `harden-ledger`, `harden-tally`, `setup-ci`) that the maintainer binary omits. Shipped in tarballs.
- **`gaia-maintainer`** (maintainer-only binary): adds the `release` namespace and intentionally omits the adopter CI/runner subcommands. Excluded from tarballs by `.gaia/release-exclude`.

The two surfaces are not a strict superset relationship: each entry point includes only the subcommands it needs.

## Why

A single binary that bakes in the entire `release` namespace (preflight, bump, changelog, scrub-wiki, manifest, scrub, runtime-deps, commit-and-tag) leaks that surface to adopters: `release-exclude` strips the source directory and the `/gaia-release` slash command, but a binary built before staging still exposes `release …` under `gaia --help` and lets adopters invoke release subcommands. Release is maintainer-only: adopters never cut GAIA releases.

Tree-shaking via esbuild at build time requires two entry points:

- `.gaia/cli/src/index.ts`: excludes release imports and handlers; builds the adopter binary.
- `.gaia/cli/src/index.maintainer.ts`: includes release; builds the maintainer binary.

`pnpm bundle` produces both, each tree-shaking out the other's exclusive subcommands. `release-exclude` lists the maintainer binary as a path to strip from adopter tarballs.

## Where it lives

- Binaries: `.gaia/cli/gaia` and `.gaia/cli/gaia-maintainer`
- Source: `.gaia/cli/src/`
- Build driver: `.gaia/cli/package.json` (`bundle` script)
- Release flow integration: `.claude/commands/gaia-release.md` (Step 7b rebuilds both binaries; Step 8 stages them manually if changed)
- Release exclusions: `.gaia/release-exclude` lists `.gaia/cli/gaia-maintainer` under its CLI-maintainer section as a path stripped from adopter tarballs

## Impact on the release flow

The `/gaia-release` command invokes `.gaia/cli/gaia-maintainer release <subcommand>` by full path (never `gaia release`). When bundling at release time, both binaries are rebuilt via `pnpm --filter @gaia-react/cli bundle` in Step 7b to ensure the new version's `--version` output stays current.

## GAIA-internal code placement rule

GAIA-internal functionality that does not need to live in a specific folder for an external integration should live under `.gaia/`. The folders `.claude/`, `.specify/`, and `app/` exist at the root because Claude Code, spec-kit, and the React Router app build require those exact locations. Everything else GAIA-owned (scripts, manifest, templates, statusline, cache, and the CLI binaries and source) belongs under `.gaia/`; the npm `bin` field points at `.gaia/cli/gaia`, so even the CLI binary lives under `.gaia/`.

**Why:** The adopter's repo root is precious surface: every top-level folder competes with the adopter's own code for attention. Keeping GAIA-internal tooling under `.gaia/` makes the boundary between "GAIA template scaffolding" and "your app" obvious, simplifies `/update-gaia` semantics (one tree to manage), and matches the principle already applied to `.gaia/scripts/`, `.gaia/statusline/`, and `.gaia/templates/`.

**How to apply:**

- New GAIA-internal code: default to `.gaia/<subfolder>/`.
- Reviewing an existing root-level GAIA folder: ask "what external system requires this exact path?" If the answer is nothing, it is a candidate to move under `.gaia/`.

## See also

- [[Bundle-time Scrub]]: enforcement of the distribution boundary after binaries ship.
- Related: `.gaia/release-exclude` (classification rules), `release.yml` (CI distribution gate).
