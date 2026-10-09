---
type: decision
status: active
priority: 1
date: 2026-04-26
created: 2026-04-26
updated: 2026-10-09
tags: [decision, tooling, package-manager, security]
---

# Decision: pnpm as the Package Manager

The project uses **pnpm** for installs and dependency resolution. The `packageManager` field in `package.json` pins the exact version; `corepack enable pnpm` reads that field and provisions it transparently.

## Why

- **Speed**: content-addressed store with hard-linking installs significantly faster than npm.
- **Strict isolation**: flat `node_modules/` is gone. A package can only `require` what it declared. Phantom deps fail loud.
- **Built-in supply-chain protection**: GAIA's `pnpm-workspace.yaml` sets `minimumReleaseAge: 4320` (3 days), blocking installs of versions less than three days old, with `minimumReleaseAgeStrict: true` stating that a breach has to be decided rather than admitted, prompting on an interactive terminal and failing the install on any non-TTY instead of auto-appending an exemption, plus `trustPolicy: no-downgrade`, which fails the install when a package's trust level drops versus prior releases (possible takeover). The release-age delay catches the bulk of compromised-package incidents in the window between publish and detection: publicized npm compromises have been pulled within hours, mostly within a day, so three days covers that range with margin for a weekend, while a longer window mainly delays security fixes. pnpm enforces both policies against the entire lockfile on every install, including `--frozen-lockfile` runs in CI, so a latent pre-provenance transitive surfaces at install time rather than only on re-resolution. `trustPolicyExclude` acknowledges the few old, pre-provenance final-major releases that trip `no-downgrade` because a newer major later added npm provenance; each entry is scoped to an exact version and names its requiring dependent. `minimumReleaseAgeExclude` is the parallel escape hatch for the release-age delay: it exempts first-party packages whose third-party-vetting rationale does not apply, and is also how a third-party version ships before it clears the window. Because enforcement runs against the whole lockfile on every install (CI `--frozen-lockfile` included), such an entry stays committed until that version ages past the window; removing it earlier fails any non-interactive install with `ERR_PNPM_NO_MATURE_MATCHING_VERSION` and, on an interactive terminal, re-raises the approval prompt rather than resolving quietly, so it is not an add-install-then-revert step.
- **Reproducible installs**: `pnpm-lock.yaml` + CI `--frozen-lockfile` guarantees the lockfile is the only source of truth.

## How

- `package.json` declares `"packageManager": "pnpm@<version>"`.
- `pnpm-workspace.yaml` carries every non-auth setting pnpm reads:
  - supply-chain hardening: `minimumReleaseAge`, `minimumReleaseAgeStrict`, `trustPolicy`, `trustPolicyExclude`, `minimumReleaseAgeExclude`;
  - dependency `overrides`, using pnpm's `parent>child` / version-range key syntax;
  - the `allowBuilds` map, which names the packages permitted to run install scripts (`true` = allowed); with `strictDepBuilds` on by default, an unlisted package that needs to build fails the install loudly instead of silently skipping;
  - resolution flags: `strictPeerDependencies: false` (peer-dep mismatches warn instead of erroring), `savePrefix: ''` (pin exact versions on `pnpm add`), and `publicHoistPattern` (lift stylelint's shared config/plugins and prettier plugins to the root `node_modules` so those tools resolve them).
- pnpm reads none of the above from the `package.json` `pnpm` field or from `.npmrc`. `.npmrc` carries only registry and auth settings; resolution and supply-chain keys placed there are ignored.
- `pnpm-lock.yaml` is committed. `package-lock.json` is forbidden: delete on sight.
- `pnpm-lock.yaml` opens with a separate YAML document recording pnpm itself (`packageManagerDependencies`, with per-platform `@pnpm/exe.*` integrity hashes) ahead of the dependency lockfile. Bumping `packageManager` rewrites that header; it is expected churn, not drift.
- CI provisioning routes through `.github/actions/gaia-setup-node`, which answers for the pnpm pin, the `cache: 'pnpm'` setting, and the frozen-lockfile install; bumping `packageManager` moves its pnpm version in lockstep.
- A Docker stage that runs a pnpm command needs `pnpm-workspace.yaml` copied alongside `package.json` and `pnpm-lock.yaml`. The stages that `COPY . /app` (`development-dependencies-env`, `build-env`) pick it up implicitly; a stage that copies only the manifest and lockfile (`production-dependencies-env`, the final runtime stage) does not. pnpm reads `overrides`, `allowBuilds`, and supply-chain policy only from that file, so a selective-copy stage that omits it risks two failures: `ERR_PNPM_LOCKFILE_CONFIG_MISMATCH` on a `--frozen-lockfile` install, and `ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY` when a script such as `pnpm start` runs its pre-run deps check in a no-TTY stage. Copy all three together in any selective-copy stage.
- The final runtime stage resolves pnpm at build time (`corepack prepare --activate`), so a container starts without registry access. A root `.dockerignore` mirrors the untracked `.gitignore` entries so the `COPY . /app` stages see only tracked files.
- The final runtime stage resolves pnpm at build time (`corepack prepare --activate && pnpm --version`). `corepack enable` alone installs only a shim, and pnpm's first run also fetches its native `@pnpm/exe` binary, so without that step every container start downloads pnpm and a start without registry access fails before the server boots. The runtime stays on `pnpm start` rather than invoking `react-router-serve` directly because the app's env schema requires `npm_package_version`, which only a package-manager script run sets.
- Adopters bootstrap pnpm with `corepack enable pnpm`. `/gaia-init` does this in Step 0 with a `npm install -g pnpm` fallback for environments without corepack.

## Pinning

Caret ranges (`^x.y.z`) are kept in `package.json`. The lockfile is the authoritative pin; `--frozen-lockfile` guarantees CI installs the exact tree on disk regardless of the `^` specifier. `minimumReleaseAge` provides the supply-chain delay. Packages already pinned exactly stay that way; no bulk conversion in either direction.

<!-- gaia:maintainer-only:start -->

## Maintainer CLI workspace

`.gaia/cli` is a member of the root pnpm workspace: one `pnpm-workspace.yaml`, one `pnpm-lock.yaml`, one install, one `pnpm audit`. The release scrub removes its workspace entry and its lockfile importer from the shipped pair, so adopters receive a workspace file and lockfile that name no CLI (see [[Bundle-time Scrub]]). A security floor the CLI's closure needs goes in the root `overrides` map like any other.
<!-- gaia:maintainer-only:end -->

## Override audit

Overrides drift. The `update-deps` skill audits every `overrides` key before a run and re-audits the retained ones after the waves land; its Phase 0 section in `.claude/skills/update-deps/references/override-audit.md` owns the procedure and the verdicts it reports. The re-resolution primitive it uses is `pnpm dedupe`, not `pnpm install`: an overrides-only change does not re-resolve under `pnpm install`, which short-circuits with "Already up to date" and leaves the floor unapplied. See [[pnpm-overrides]].

## Transitive refresh

pnpm keeps a transitive dependency's locked version for as long as its parent's range still admits it, so bumping direct specs never pulls in a patched transitive that was already in range. The `update-deps` skill closes that gap with a transitive-refresh phase after its waves and before the post-update override audit: `pnpm update --no-save` re-resolves the whole tree (pnpm's default depth is unlimited) to the newest in-range versions, and `--no-save` leaves every `package.json` range as declared. pnpm applies `minimumReleaseAge` while it resolves, so the refresh cannot land a version younger than the window. The phase runs on every run outside `--scope`, including one whose direct dependencies are all current or all snoozed, so a routine run on an up-to-date repository still picks up in-range transitive fixes. A transitive whose parent's range caps it below the patched version stays vulnerable after the refresh, and the skill's security phase resolves it with a chain-head bump or a security-floor override, or reports it still open in its Security section with the chain holding it back. The phase's skip conditions and report section live in `.claude/skills/update-deps/SKILL.md`; its quality gate and whole-refresh revert live in `.claude/skills/update-deps/references/transitive-refresh.md`.

## Release-age-aware version selection

`minimumReleaseAge` guards installs, and the `update-deps` skill honours the same cooldown at selection time so the dependabot flow never introduces a lockfile entry younger than the window. When `pnpm-workspace.yaml` sets `minimumReleaseAge`, `update-deps` caps each candidate to the newest stable version that is an upgrade, at or below `latest`, and published before the cooldown cutoff, resolved via `pnpm view <name> time --json`, rather than blindly targeting `latest`. A package whose only available upgrades are still inside the cooldown is skipped with reason `release-age-cooldown`; a publish-time lookup failure fails closed and skips with `release-age-unresolved`. With the setting unset the filter is inert, no extra registry calls, behaviour identical to targeting `latest`, so adopters without a cooldown are unaffected. Cooldown skips are silent in the human report, like the major-version cap.

The statusline `Run /update-deps (X outdated, Y security)` count derives from `gaia update-deps run`'s `actionable_count` field, which counts only the genuine upgrades the skill will actually apply after applying the cooldown, major-version cap, and local snooze ledger (`.gaia/local/declined-updates.json`). Groups snoozed by the user via the interactive preview drop out of the count until a newer version ships or 14 days elapse. `total_count` in the same payload is the raw eligible-upgrade count before snoozes are subtracted; the statusline uses `actionable_count` so the nudge reflects only updates the skill would act on. The security term is the open advisory count from `gaia update-deps advisories`, which no snooze reduces.

## Field-aware update merge

`pnpm-workspace.yaml` is a mixed file: GAIA-authored settings (`minimumReleaseAge`, `minimumReleaseAgeStrict`, `trustPolicy`, `trustPolicyExclude`, `minimumReleaseAgeExclude`, `publicHoistPattern`, `savePrefix`, `strictPeerDependencies`) live alongside adopter-extensible `overrides` and `allowBuilds` maps. `/update-gaia` therefore merges it field-aware (Step 7b), the YAML analog of the `package.json` step: GAIA-managed keys merge whole-value, the two maps merge per entry, and the iteration spans only `keys(baseline) ∪ keys(latest)` so an adopter-only override is never visited. An adopter who adds one override no longer drifts the whole file into a full-file conflict patch; only the keys GAIA actually changed surface, with re-pin conflicts and added/removed entries written to `.gaia-merge/pnpm-workspace.yaml.notes`.

The verdicts come from the `gaia update merge-workspace` CLI primitive, which parses the three files with the bundled `js-yaml` and emits a JSON report. It is read-only: the skill applies the clean changes with the Edit tool so comments, key order, and quote style survive. A reserialization approach (`js-yaml` `dump`, or piping through an external `yq`) is rejected because `dump` strips every comment and the supply-chain rationale comments in this file are load-bearing. The file is classed `shared` in `.gaia/manifest.json`, matching `package.json`; both are excluded from the generic merge walk by name.

## Source of truth

This page. Mechanics: `package.json`, `.npmrc`, `pnpm-workspace.yaml`, `pnpm-lock.yaml`, `Dockerfile`, `.github/workflows/tests.yml`, `.github/workflows/chromatic.yml`. Bootstrap: `.claude/commands/gaia-init.md` Step 0. Migration tooling: `.claude/skills/update-deps/SKILL.md` (release-age selection implemented in the CLI binary). Field-aware workspace merge: `.claude/skills/update-gaia/references/merge-execution.md` (Step 7b); the merge is driven by the `gaia update merge-workspace` CLI primitive.

See [[Quality Gate]], [[Pre-commit Hooks]], [[lint-staged]], [[Vitest]], [[Playwright]].
