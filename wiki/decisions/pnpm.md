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
- **Built-in supply-chain protection** — `minimumReleaseAge=10080` (7 days, in `.npmrc`) blocks installs of versions less than a week old. Catches the bulk of compromised-package incidents in the window between publish and detection.
- **Reproducible installs** — `pnpm-lock.yaml` + CI `--frozen-lockfile` guarantees the lockfile is the only source of truth.

## How

- `package.json` declares `"packageManager": "pnpm@<version>"`.
- `package.json` declares `"pnpm": { "overrides": { ... } }` using pnpm's `parent>child` syntax (the previous npm `overrides.parent.child` shape does not apply).
- `.npmrc` carries the pnpm-specific keys:
  ```
  strict-peer-dependencies=false
  minimumReleaseAge=10080
  ```
  `strict-peer-dependencies=false` keeps the previous npm `legacy-peer-deps=true` semantics — peer-dep mismatches warn instead of erroring.
- `pnpm-lock.yaml` is committed. `package-lock.json` is forbidden — delete on sight.
- CI workflows install pnpm via `pnpm/action-setup@v4` (which reads `packageManager`), use `cache: 'pnpm'` in `actions/setup-node`, and install with `pnpm install --frozen-lockfile`.
- Adopters bootstrap pnpm with `corepack enable pnpm`. `/gaia-init` does this in Step 0 with a `npm install -g pnpm` fallback for environments without corepack.

## Pinning

Caret ranges (`^x.y.z`) are kept in `package.json`. The lockfile is the authoritative pin — `--frozen-lockfile` guarantees CI installs the exact tree on disk regardless of the `^` specifier. `minimumReleaseAge` provides the supply-chain delay. Packages already pinned exactly stay that way; no bulk conversion in either direction.

## Override audit

Overrides drift. The `sharpen` skill's Phase 0 toggles each `pnpm.overrides` key out, runs `pnpm install`, scans `pnpm ls` for peer-dep errors, and removes any override that is no longer needed. Phase 6 re-checks retained overrides after a wave updates surrounding packages.

## Source of truth

This page. Mechanics: `package.json`, `.npmrc`, `pnpm-lock.yaml`, `.github/workflows/tests.yml`, `.github/workflows/chromatic.yml`. Bootstrap: `.claude/commands/gaia-init.md` Step 0. Migration tooling: `.claude/skills/sharpen/SKILL.md`.

> [!key-insight] minimumReleaseAge is the cheap supply-chain win
> Most npm supply-chain attacks are caught and yanked within hours. A 7-day quarantine cuts the dominant attack window for the cost of one config line. No infra. No subscription. No agent.

See [[Quality Gate]], [[Husky]], [[Vitest]], [[Playwright]].
