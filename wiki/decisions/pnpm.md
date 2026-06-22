---
type: decision
status: active
priority: 1
date: 2026-04-26
created: 2026-04-26
updated: 2026-06-12
tags: [decision, tooling, package-manager, security]
---

# Decision: pnpm as the Package Manager

GAIA uses **pnpm** for installs and dependency resolution. The `packageManager` field in `package.json` pins the exact version; `corepack enable pnpm` reads that field and provisions it transparently.

## Why

- **Speed**: content-addressed store with hard-linking installs significantly faster than npm.
- **Strict isolation**: flat `node_modules/` is gone. A package can only `require` what it declared. Phantom deps fail loud.
- **Built-in supply-chain protection**: `pnpm-workspace.yaml` sets `minimumReleaseAge: 10080` (7 days), blocking installs of versions less than a week old, plus `trustPolicy: no-downgrade`, which fails the install when a package's trust level drops versus prior releases (possible takeover). The release-age delay catches the bulk of compromised-package incidents in the window between publish and detection. pnpm enforces both policies against the entire lockfile on every install, including `--frozen-lockfile` runs in CI, so a latent pre-provenance transitive surfaces at install time rather than only on re-resolution. `trustPolicyExclude` acknowledges the few old, pre-provenance final-major releases that trip `no-downgrade` because a newer major later added npm provenance; each entry is scoped to an exact version and names its requiring dependent.
- **Reproducible installs**: `pnpm-lock.yaml` + CI `--frozen-lockfile` guarantees the lockfile is the only source of truth.

## How

- `package.json` declares `"packageManager": "pnpm@<version>"`.
- `pnpm-workspace.yaml` carries every non-auth setting pnpm reads:
  - supply-chain hardening: `minimumReleaseAge`, `trustPolicy`, `trustPolicyExclude`, `minimumReleaseAgeExclude`;
  - dependency `overrides`, using pnpm's `parent>child` / version-range key syntax;
  - the `allowBuilds` map, which names the packages permitted to run install scripts (`true` = allowed); with `strictDepBuilds` on by default, an unlisted package that needs to build fails the install loudly instead of silently skipping;
  - resolution flags: `strictPeerDependencies: false` (peer-dep mismatches warn instead of erroring), `savePrefix: ''` (pin exact versions on `pnpm add`), and `publicHoistPattern` (lift stylelint's shared config/plugins and prettier plugins to the root `node_modules` so those tools resolve them).
- pnpm reads none of the above from the `package.json` `pnpm` field or from `.npmrc`. `.npmrc` carries only registry and auth settings; resolution and supply-chain keys placed there are ignored.
- `pnpm-lock.yaml` is committed. `package-lock.json` is forbidden: delete on sight.
- CI workflows install pnpm via `pnpm/action-setup` (pinned by commit SHA, no `version:` input, so it reads the `packageManager` field), use `cache: 'pnpm'` in `actions/setup-node`, and install with `pnpm install --frozen-lockfile`. Because the action keys off `packageManager`, bumping that one field moves CI's pnpm version in lockstep.
- Every Docker stage that runs a pnpm command, including the final runtime stage, needs `pnpm-workspace.yaml` copied alongside `package.json` and `pnpm-lock.yaml`. pnpm reads `overrides`, `allowBuilds`, and supply-chain policy only from that file, so a stage that copies just the manifest and lockfile fails two ways: `ERR_PNPM_LOCKFILE_CONFIG_MISMATCH` on a `--frozen-lockfile` install, and `ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY` when a script such as `pnpm start` runs its pre-run deps check in a no-TTY stage. Copy all three together.
- Adopters bootstrap pnpm with `corepack enable pnpm`. `/gaia-init` does this in Step 0 with a `npm install -g pnpm` fallback for environments without corepack.

## Pinning

Caret ranges (`^x.y.z`) are kept in `package.json`. The lockfile is the authoritative pin; `--frozen-lockfile` guarantees CI installs the exact tree on disk regardless of the `^` specifier. `minimumReleaseAge` provides the supply-chain delay. Packages already pinned exactly stay that way; no bulk conversion in either direction.

## Override audit

Overrides drift. The `update-deps` skill's Phase 0 toggles each `overrides` key out, re-resolves with `pnpm dedupe`, then runs two tests, `pnpm ls` for peer-dep errors and `pnpm audit` for reintroduced advisories, and removes only an override that regresses neither. Phase 6 re-checks retained overrides after a wave updates surrounding packages. The re-resolution primitive is `pnpm dedupe`, not `pnpm install`: an overrides-only change does not re-resolve under `pnpm install`, which short-circuits with "Already up to date" and leaves the floor unapplied. See [[pnpm-overrides]].

## Release-age-aware version selection

`minimumReleaseAge` guards installs, and the `update-deps` skill honours the same cooldown at selection time so the dependabot flow never introduces a lockfile entry younger than the window. When `pnpm-workspace.yaml` sets `minimumReleaseAge`, `update-deps` caps each candidate to the newest stable version that is an upgrade, at or below `latest`, and published before the cooldown cutoff, resolved via `pnpm view <name> time --json`, rather than blindly targeting `latest`. A package whose only available upgrades are still inside the cooldown is skipped with reason `release-age-cooldown`; a publish-time lookup failure fails closed and skips with `release-age-unresolved`. With the setting unset the filter is inert, no extra registry calls, behaviour identical to targeting `latest`, so adopters without a cooldown are unaffected. Cooldown skips are silent in the human report, like the major-version cap.

The statusline `Run /update-deps (N outdated)` count derives from `gaia update-deps run`'s `actionable_count` field, which counts only the genuine upgrades the skill will actually apply after applying the cooldown, major-version cap, and local snooze ledger (`.gaia/local/declined-updates.json`). Groups snoozed by the user via the interactive preview drop out of the count until a newer version ships or 14 days elapse. `total_count` in the same payload is the raw eligible-upgrade count before snoozes are subtracted; the statusline uses `actionable_count` so the nudge reflects only updates the skill would act on.

## Field-aware update merge

`pnpm-workspace.yaml` is a mixed file: GAIA-authored settings (`minimumReleaseAge`, `trustPolicy`, `trustPolicyExclude`, `minimumReleaseAgeExclude`, `publicHoistPattern`, `savePrefix`, `strictPeerDependencies`) live alongside adopter-extensible `overrides` and `allowBuilds` maps. `/update-gaia` therefore merges it field-aware (Step 7b), the YAML analog of the `package.json` step: GAIA-managed keys merge whole-value, the two maps merge per entry, and the iteration spans only `keys(baseline) ∪ keys(latest)` so an adopter-only override is never visited. An adopter who adds one override no longer drifts the whole file into a full-file conflict patch; only the keys GAIA actually changed surface, with re-pin conflicts and added/removed entries written to `.gaia-merge/pnpm-workspace.yaml.notes`.

The verdicts come from the `gaia update merge-workspace` CLI primitive, which parses the three files with the bundled `js-yaml` and emits a JSON report. It is read-only: the skill applies the clean changes with the Edit tool so comments, key order, and quote style survive. A reserialization approach (`js-yaml` `dump`, or piping through an external `yq`) is rejected because `dump` strips every comment and the supply-chain rationale comments in this file are load-bearing. The file is classed `shared` in `.gaia/manifest.json`, matching `package.json`; both are excluded from the generic merge walk by name.

## Source of truth

This page. Mechanics: `package.json`, `.npmrc`, `pnpm-workspace.yaml`, `pnpm-lock.yaml`, `.github/workflows/tests.yml`, `.github/workflows/chromatic.yml`. Bootstrap: `.claude/commands/gaia-init.md` Step 0. Migration tooling: `.claude/skills/update-deps/SKILL.md` (release-age selection implemented in the CLI binary). Field-aware workspace merge: `.claude/skills/update-gaia/SKILL.md` (Step 7b); the merge is driven by the `gaia update merge-workspace` CLI primitive.

> [!key-insight] minimumReleaseAge is the cheap supply-chain win
> Most npm supply-chain attacks are caught and yanked within hours. A 7-day quarantine cuts the dominant attack window for the cost of one config line. No infra. No subscription. No agent.

See [[Quality Gate]], [[Husky]], [[Vitest]], [[Playwright]].
