---
type: decision
status: active
priority: 1
date: 2026-04-26
created: 2026-04-26
updated: 2026-05-01
tags: [decision, tooling, package-manager, security]
---

# Decision: pnpm as the Package Manager

GAIA uses **pnpm** for installs and dependency resolution. The `packageManager` field in `package.json` pins the exact version; `corepack enable pnpm` reads that field and provisions it transparently.

## Why

- **Speed** — content-addressed store with hard-linking installs significantly faster than npm.
- **Strict isolation** — flat `node_modules/` is gone. A package can only `require` what it declared. Phantom deps fail loud.
- **Built-in supply-chain protection** — `pnpm-workspace.yaml` sets `minimumReleaseAge: 10080` (7 days), blocking installs of versions less than a week old, plus `trustPolicy: no-downgrade`, which fails the install when a package's trust level drops versus prior releases (possible takeover). The release-age delay catches the bulk of compromised-package incidents in the window between publish and detection.
- **Reproducible installs** — `pnpm-lock.yaml` + CI `--frozen-lockfile` guarantees the lockfile is the only source of truth.

## How

- `package.json` declares `"packageManager": "pnpm@<version>"`.
- `package.json` declares `"pnpm": { "overrides": { ... } }` using pnpm's `parent>child` syntax (the previous npm `overrides.parent.child` shape does not apply).
- `.npmrc` carries only what pnpm 10.x+ still reads from it — registry/auth and a few resolution flags: `strict-peer-dependencies=false` (keeps the npm `legacy-peer-deps=true` semantics, so peer-dep mismatches warn instead of erroring), `save-exact=true`, and `public-hoist-pattern[]` entries for tools that need flat resolution (stylelint, prettier plugins).
- `pnpm-workspace.yaml` carries everything else pnpm reads, including supply-chain hardening — it lives here, not `.npmrc`:
  ```
  minimumReleaseAge: 10080
  trustPolicy: no-downgrade
  ```
- `pnpm-lock.yaml` is committed. `package-lock.json` is forbidden — delete on sight.
- CI workflows install pnpm via `pnpm/action-setup@v4` (which reads `packageManager`), use `cache: 'pnpm'` in `actions/setup-node`, and install with `pnpm install --frozen-lockfile`.
- Adopters bootstrap pnpm with `corepack enable pnpm`. `/gaia-init` does this in Step 0 with a `npm install -g pnpm` fallback for environments without corepack.

## Pinning

Caret ranges (`^x.y.z`) are kept in `package.json`. The lockfile is the authoritative pin — `--frozen-lockfile` guarantees CI installs the exact tree on disk regardless of the `^` specifier. `minimumReleaseAge` provides the supply-chain delay. Packages already pinned exactly stay that way; no bulk conversion in either direction.

## Override audit

Overrides drift. The `update-deps` skill's Phase 0 toggles each `pnpm.overrides` key out, runs `pnpm install`, scans `pnpm ls` for peer-dep errors, and removes any override that is no longer needed. Phase 6 re-checks retained overrides after a wave updates surrounding packages.

## Release-age-aware version selection

`minimumReleaseAge` guards installs, and the `update-deps` skill honours the same cooldown at selection time so the dependabot flow never introduces a lockfile entry younger than the window. When `pnpm-workspace.yaml` sets `minimumReleaseAge`, `update-deps` caps each candidate to the newest stable version that is an upgrade, at or below `latest`, and published before the cooldown cutoff — resolved via `pnpm view <name> time --json` — rather than blindly targeting `latest`. A package whose only available upgrades are still inside the cooldown is skipped with reason `release-age-cooldown`; a publish-time lookup failure fails closed and skips with `release-age-unresolved`. With the setting unset the filter is inert — no extra registry calls, behaviour identical to targeting `latest` — so adopters without a cooldown are unaffected. Cooldown skips are silent in the human report, like the major-version cap.

The statusline `Run /update-deps (N outdated)` count derives from `gaia update-deps run`, counting only the plan the skill will actually apply. It inherits the same cooldown and major-version cap, so the nudge never advertises an update the skill would skip.

## Source of truth

This page. Mechanics: `package.json`, `.npmrc`, `pnpm-workspace.yaml`, `pnpm-lock.yaml`, `.github/workflows/tests.yml`, `.github/workflows/chromatic.yml`. Bootstrap: `.claude/commands/gaia-init.md` Step 0. Migration tooling: `.claude/skills/update-deps/SKILL.md` (release-age selection: `.gaia/cli/src/update-deps/run.ts`).

> [!key-insight] minimumReleaseAge is the cheap supply-chain win
> Most npm supply-chain attacks are caught and yanked within hours. A 7-day quarantine cuts the dominant attack window for the cost of one config line. No infra. No subscription. No agent.

See [[Quality Gate]], [[Husky]], [[Vitest]], [[Playwright]].
