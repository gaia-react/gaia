---
name: update-deps
description: Remediates dependencies in place of Dependabot version and security updates. Discovers outdated packages and open security advisories, resolves advisories (in-range refresh, chain-head bump, security-floor override, or alert dismissal), audits overrides, applies migrations for major bumps, and runs the quality gate. Trigger when the user clicks the statusline `Run /update-deps` indicator or asks "update dependencies", "bump deps", "run dependabot", "fix Dependabot alerts", "fix security advisories".
---

Dependency remediation: outdated packages and security advisories, through one quality gate, in one record. Discover outdated packages and open advisories, preview them (advisories first, ranked) so you can snooze what you are not ready for, audit overrides, apply codebase migrations for major bumps, resolve dependency conflicts, refresh transitive dependencies within range, resolve each advisory by the least invasive method that clears it or accept it by dismissing its alert, and run the quality gate. In CI it runs unattended (no preview); interactively it shows the preview first. On a `main`/`master` run it opens the PR and merges it once checks are green, then cleans up locally; on any other branch it pushes and leaves the PR to you.

## Pre-flight: Worktree check

This wrapper writes a new `pnpm-lock.yaml` and opens a PR, both belong on the main checkout, not a per-SPEC worktree branch. If invoked from a linked worktree, reject hard with a message that surfaces the cached state from main so the user knows whether action is even pending.

Detection (run this first, before anything else):

```bash
. .gaia/scripts/main-only-lib.sh
gaia_update_deps_state_line() {
  local cache_file="$1"
  [ -f "$cache_file" ] && command -v jq >/dev/null 2>&1 || return 0
  local outdated_count checked_at security_count security_term
  outdated_count="$(jq -r '.outdatedCount // 0' "$cache_file" 2>/dev/null)"
  checked_at="$(jq -r '.checkedAt // 0' "$cache_file" 2>/dev/null)"
  # A null security count means no source answered, which is not zero.
  security_count="$(jq -r 'if (.securityCount | type) == "number" and .securitySource != "unavailable" then (.securityCount | tostring) else "null" end' "$cache_file" 2>/dev/null)"
  [ -n "$outdated_count" ] && [ -n "$checked_at" ] && [ "$checked_at" != "0" ] || return 0
  if [ -z "$security_count" ] || [ "$security_count" = "null" ]; then
    security_term="security advisories unavailable"
  else
    security_term="$security_count open security advisories"
  fi
  local now age ago_unit ago_value
  now=$(date +%s)
  age=$((now - checked_at))
  # Format age as <Nm ago> / <Nh ago> / <Nd ago>.
  ago_unit="s"; ago_value="$age"
  if [ "$age" -ge 86400 ]; then ago_unit="d"; ago_value=$((age / 86400));
  elif [ "$age" -ge 3600 ]; then ago_unit="h"; ago_value=$((age / 3600));
  elif [ "$age" -ge 60 ]; then ago_unit="m"; ago_value=$((age / 60));
  fi
  printf 'Cached on main: %s packages outdated, %s (last checked %s%s ago).\n' "$outdated_count" "$security_term" "$ago_value" "$ago_unit"
}
gaia_refuse_if_worktree "/update-deps" gaia_update_deps_state_line || exit 1
```

If the detection does not fire, fall through to the existing `## Pre-flight: Branch check` section.

## Pre-flight: Branch check

```bash
git branch --show-current
```

If the current branch is `main` or `master` **and not running in CI**, set a flag (`SHOULD_CREATE_BRANCH=true`) but **do not create the branch yet**, branch creation is deferred until the run has confirmed work: after Phase 1 when the apply set is non-empty or the security plan has a resolution to apply, or after Phase 5b lands on a refresh-only run (see Branch creation). Creating a branch when there is nothing to update pollutes the branch list.

In CI (`CI=true`, set by GitHub Actions, GitLab CI, CircleCI, and most CI providers), skip branch creation, the workflow owns branch management and pre-creates the appropriate branch before this skill runs.

Otherwise set `SHOULD_CREATE_BRANCH=false` and proceed on the current branch.

## Package layout

The repository is a pnpm workspace with one lockfile at the root. App dependencies (everything the React app imports or builds with) are declared in `frontend/package.json`; harness dependencies (lint-staged, prettier, `typescript` for the harness helpers) and the `gaia.updateDepsHold` map are in the root `package.json`. `overrides:` and `minimumReleaseAge` stay in the root `pnpm-workspace.yaml`. Add or bump an app dependency with `pnpm -C frontend add <pkg>@<spec>`, a harness dependency with `pnpm add -w <pkg>@<spec>` from the root. The quality gate runs the root `pnpm typecheck`, `pnpm lint`, `pnpm test`, `pnpm pw`, and `pnpm build`, which proxy to `frontend`.

## Flags and run modes

Parse the arguments before any other work. `--security` together with `--scope` refuses at once, before discovery, printing `/update-deps: --security and --scope cannot be combined; pass one or the other.` and stopping.

| Run                                    | Preview                                           | Phase 0                     | Waves                         | Phase 5b                    | Security phase | Phase 6                                                  | Acceptance       | Reads alerts          |
| -------------------------------------- | ------------------------------------------------- | --------------------------- | ----------------------------- | --------------------------- | -------------- | -------------------------------------------------------- | ---------------- | --------------------- |
| Interactive, no flag                   | yes, Security section first                       | yes                         | yes                           | yes (default)               | applies        | keys retained in Phase 0 plus every security override    | ask per advisory | yes                   |
| Interactive `--security`               | Security section plus the chain-head bumps needed | no                          | only those chain-head bumps   | no                          | applies        | only if a security override landed, those overrides only | ask per advisory | yes                   |
| `--scope <group>`                      | no                                                | no                          | the group                     | no                          | report-only    | unchanged                                                | no               | yes (enrichment only) |
| `CI=true` (with or without --security) | no                                                | yes / no under `--security` | yes / none under `--security` | yes / no under `--security` | report-only    | unchanged                                                | no               | no                    |
| `--security --scope`                   | refused, naming both flags                        |                             |                               |                             |                |                                                          |                  |                       |

**Report-only.** Under `CI=true` and `--scope <group>`, which both skip the preview, the security phase is report-only: every advisory is listed still open with `report-only run`, and the security phase adds, edits, and removes no `overrides:` key and applies no advisory-driven bump. The existing Phase 0 and Phase 6 override audit is unchanged in those runs and may still prune an obsolete key exactly as it does today, so report-only is a property of the security phase, not a promise that the whole run leaves the `overrides:` map untouched. In CI the advisories call runs with `--no-alerts` (the verb also refuses alerts by itself under CI), so no Dependabot output reaches the run.

**`--security`** runs Phase 1 (preview), the Wave A/B agents only for the chain-head bumps an accepted advisory needs, the security phase, Phase 6 only when the security phase landed an override, Phase 7, and Phase 8. It runs neither Phase 0 nor Phase 5b, and leaves every other outdated package untouched.

### --scope &lt;group-name&gt;

When invoked with `--scope <group-name>` (e.g. `/update-deps --scope react-router`):

- Skip Phase 0 (override audit), out of scope for a single-group run.
- Skip the discovery + preview phase, no preview runs in `--scope`; the
  group's members are known from the companion-group table.
- Skip wave classification, the run is implicitly a single group; treat it
  as Wave A if all members are minor/patch, else Wave B.
- Wave A / Wave B still apply, scoped to the named group's members
  in the package manifest that declares them (see Package layout).
- Skip Phase 5b (transitive refresh), a single-group run does not re-resolve
  the whole tree.
- The security phase is report-only (see Report-only above).
- Quality gate, return value, and final report still run.

Invoked manually, one group per run, when a maintainer wants a single
major-bump group's own PR rather than the combined Wave A/B run.

## Companion groups (reference)

The fixed table mapping each package to its group. `gaia update-deps run`
resolves grouping internally and is the source of
truth at runtime; every emitted entry already carries its resolved `group`.
**When any member of a group is outdated, all members present in a manifest
update together**, so a group moves as one unit (and snoozes as one unit).

| Group             | Members                                                                                                                                  |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `react-router`    | `react-router`, `@react-router/dev`, `@react-router/node`, `@react-router/serve`, `@react-router/fs-routes`                              |
| `react`           | `react`, `react-dom`, `@types/react`, `@types/react-dom`                                                                                 |
| `tailwindcss`     | `tailwindcss`, `@tailwindcss/vite`, `prettier-plugin-tailwindcss`                                                                        |
| `shadcn`          | `shadcn`, `@base-ui/react`, `class-variance-authority`, `lucide-react`, `tw-animate-css`                                                 |
| `storybook`       | `storybook`, `@storybook/*`, `eslint-plugin-storybook`, `msw-storybook-addon`, `storybook-react-i18next`, `@vueless/storybook-dark-mode` |
| `vitest`          | `vitest`, `@vitest/browser-playwright`, `@vitest/coverage-v8`, `@vitest/ui`, `@vitest/eslint-plugin`, `vitest-browser-react`             |
| `playwright`      | `@playwright/test`, `playwright`                                                                                                         |
| `eslint`          | `eslint`, `@eslint/js`, `@eslint/compat`, `eslint-config-*`, `eslint-plugin-*` (9.x cap applies)                                         |
| `i18next`         | `i18next`, `react-i18next`, `remix-i18next`, `i18next-browser-languagedetector`                                                          |
| `msw`             | `msw`, `msw-storybook-addon`                                                                                                             |
| `vite`            | `vite`, `@vitejs/plugin-react`                                                                                                           |
| `zod-conform`     | `zod`, `@conform-to/react`, `@conform-to/zod`                                                                                            |
| `fontawesome`     | `@fortawesome/*`                                                                                                                         |
| `stylelint`       | `stylelint`, `stylelint-config-*`, `stylelint-order`                                                                                     |
| `prettier`        | `prettier`, `eslint-config-prettier`, `eslint-plugin-prettier`                                                                           |

After any change to the installed `msw` version (Wave A or Wave B), run `pnpm -C frontend msw:init` (`pnpm -C frontend exec msw init` when the project has no such script) so the regenerated `frontend/public/mockServiceWorker.js` joins the change; msw 3 has no postinstall that keeps it current.

Packages not matched form singleton groups. `typescript` is deliberately one of
them: a compiler bump and an ambient type-definition bump (`@types/node`) carry
independent risk and independent migration guides, so they never move as a unit.

## Phase 1: Discover, preview, decide (orchestrator)

Discover deterministically via the CLI primitive, the single source of truth for
grouping, the ESLint 9.x cap, the `gaia.updateDepsHold` config hold, and the
release-age cooldown (all already applied):

```bash
mkdir -p .gaia/local/cache/shared
updates_json="$(mktemp .gaia/local/cache/shared/.updates.XXXXXX)"
.gaia/cli/gaia update-deps run --emit-updates "$updates_json"
advisories_json="$(mktemp .gaia/local/cache/shared/.advisories.XXXXXX)"
.gaia/cli/gaia update-deps advisories --emit "$advisories_json" --updates "$updates_json"
```

Under `CI=true` add `--no-alerts` to the advisories call. It runs in every mode and writes a payload even when no source answered (`source: "unavailable"`). Keep from it, for later phases: the `source` and `reasonText`, whether alerts were read (`source` is `dependabot`), `rejectedCount`, the opening advisory key set (every `advisories[].key` plus every `dismissedGhsas` entry), and the opening `dismissedGhsas`.

### Global tools (before any exit below)

Run this once, right after the discovery call and before every exit branch
that follows (`total_count` `0`, `--scope`, the Skip answer), so it also runs on
an otherwise up-to-date run:

```bash
.gaia/cli/gaia update-deps global-tools
```

It prints `{"rows":[...]}` and exits 0 even when a probe fails. Keep the
playwright-cli row for the Phase 7 `### Global tools` section. This step never
changes `outdatedCount`, never writes the update-check cache, and never creates
a branch by itself: a global tool cannot be cleared through pnpm, so it stays
out of the discovery payload and the statusline count.

- **In CI (`CI=true`)**: report the row only. Never run `npm install -g`.
- **Under `--scope`**: report the row only.
- **`status` is `not-installed`**: report `not installed, skipped` with the
  row's `installCommand` as text. No prompt, no error.
- **`status` is `current` or `unknown`**: report the row only.
- **Interactively with `offerInstall: true`**: show the row, then ask with
  `AskUserQuestion` (single-select): **Upgrade playwright-cli to `<latest>`
  globally** or **Skip**. Only after the Upgrade answer, run
  `npm install -g @playwright/cli@latest`. Record `upgraded` or `declined` as
  the action taken.

<!-- gaia:maintainer-only:start -->

### Vendored skill sync (GAIA maintainer repository, before any exit below)

`frontend/.claude/skills/playwright-cli/` is a verbatim copy of the upstream
package's skill folder, pinned by `.gaia/vendor/playwright-cli.json`. This phase
also runs on an otherwise up-to-date run. Compare that marker's `version` with
the global-tools row's `latest`. When `latest` is unknown or equal, report
`Vendored skills: current` (or `unknown`) and move on. Otherwise:

1. If no branch exists yet and the run is on `main`/`master`, create one now and
   remember `CREATED_NEW_BRANCH=true` for Phase 8:
   ```bash
   git checkout -b "$(bash .gaia/scripts/branch-name-lib.sh name deps)"
   ```
2. Re-vendor, then verify offline:
   ```bash
   bash .gaia/scripts/revendor-playwright-cli.sh --version <latest>
   bash .gaia/scripts/verify-vendored-skills.sh
   ```
3. Keep the result for the Phase 7 `Vendored skills` row. A re-vendor diff is
   something Phase 8 publishes even when no package moved.

<!-- gaia:maintainer-only:end -->

Read the payload. **A zero `total_count` with at least one advisory** (a
non-empty `advisories[]`) is a real run, not "nothing to do": interactively it
goes to the full preview below (Security section, then the transitive refresh
line), never to the refresh-only prompt and never to `All packages are up to
date.`; in CI it continues as a refresh-only run whose security phase is
report-only. With zero advisories the paths below stand.

If `total_count` is `0` and `advisories[]` is empty, print `All packages are up to date.`
(the Phase 7 `### Global tools` and `### Security` sections are still printed first). Under `--scope`, exit (no branch, no changes). Otherwise the apply set is empty
and the run is **refresh-only** (see Decision): in CI it proceeds straight to
Phase 5b; interactively, print `Transitive refresh: re-resolve every
transitive dependency to the newest in-range version past the release-age
window; reverted whole if the quality gate fails.` and ask with `AskUserQuestion`
(single-select): **Refresh transitive dependencies** (default, first option) or
**Skip** (exit now, no branch, no changes, no ledger write). Each `wave_a[]` and `wave_b[].packages[]` entry
carries `bucket` (`patch` | `minor` | `major` | `nonsemver`), `current`, `latest`,
`group`, `is_pinned`, and `kind`. `total_count` is the genuine-upgrade count;
`actionable_count` is for the statusline only (it already subtracts local
snoozes), ignore it here.

`snoozed[]` lists the groups the human deferred earlier that still match the
currently-offered targets. Each entry carries `group`, `targets`, `snoozed_at`,
and `resurfaces_at` (ISO stamp when the snooze lapses). Build `snoozedGroups`,
the set of their `group` ids, this is what you mark and default-skip below. It
is empty in CI and whenever no active snooze matches the current offer.

`skipped[]` entries with `reason: "held"` are packages capped by the committed
`gaia.updateDepsHold` map in the root `package.json` (a durable version ceiling, distinct
from a snooze: it holds in CI too and never lapses until the maintainer lifts
it). They are already excluded from both waves, never installed, so nothing to
apply. Surface them once (see Preview) so the maintainer remembers a hold is
active.

A hold caps only the package it names; a coupled sibling in the same companion
group (e.g. `@vitejs/plugin-react` beside a held `vite`) still updates on its own
line. If a sibling release's peer range demands a version above the ceiling, hold
the sibling too by adding it to the map. The quality gate catches a peer conflict
before merge regardless.

**In CI (`CI=true`) or with `--scope <group>`, skip the preview and decision
entirely.** The apply set is the full payload (CI) or the named group
(`--scope`); jump straight to the apply phases with an empty skip set and no
ledger write.

### Preview

Group the entries for display into five sections in this order: **Security**,
**Major**, **Non-semver**, **Minor**, **Patch**. The Security section comes
first, one row per advisory in the payload's ranked order, built as
`references/security.md` (`### Security preview`) describes; it is omitted only when
`advisories[]` is empty. Under `--security` the preview shows the Security
section plus only the chain-head bumps the advisories need.

A companion group (any `group` not prefixed
`singleton:`) renders as ONE block under the section of its most-severe member
(severity major > nonsemver > minor > patch) and is a single choice that updates
together. Render each row as `name  current → next`; for a companion group, list
its members under one labelled block (e.g. "react-router group, updates
together").

Mark every group in `snoozedGroups` with a trailing `[snoozed until <date>]`
(the entry's `resurfaces_at`, rendered as a plain date). Snoozed groups are
**default-skipped**: they are excluded from the default apply set, so a group the
human already deferred is not silently re-applied each run. The human can still
choose to refresh them.

If `skipped[]` has any `reason: "held"` entries, print one line above the
sections listing them, e.g. `Held by config (not offered): vite (current
8.0.16, ceiling 8.0)`. This is informational, held packages are never part of
any apply set; the line just keeps the active holds visible.

Below the sections, print one line for the transitive refresh (Phase 5b),
which runs by default after the waves: `Transitive refresh: re-resolve every
transitive dependency to the newest in-range version past the release-age
window; reverted whole if the quality gate fails. Name transitive-refresh under
"Choose what to skip" to skip it this run.`

Then ask with `AskUserQuestion` (single-select). **When `snoozedGroups` is
non-empty**, offer these options in this order:

- **Update the rest** (default, first option): apply every group EXCEPT the
  snoozed ones; leave the snoozes intact.
- **Choose what to skip**: the human names further package or group names to
  skip; the snoozed groups stay skipped too.
- **Update everything incl. snoozed**: apply every group AND clear the snoozes.
- **Cancel**: exit now, no branch, no changes, no ledger write.

**When `snoozedGroups` is empty**, offer the original three:

- **Update all** (default, first option): apply every group.
- **Choose what to skip**: the human names the package or group names to skip;
  everything else applies.
- **Cancel**: exit now, no branch, no changes, no ledger write.

### Decision

The **skip set** is `snoozedGroups` plus whatever the human names; the **apply
set** is every remaining group. The ledger is full-replace, so any `decline
--skip` call must name every group that should stay snoozed (the pre-existing
snoozes AND any newly named), or the omitted ones are dropped from the ledger.

- **Update the rest** (snoozed groups present) → apply set = payload minus
  `snoozedGroups`. Leave the ledger untouched (the snoozes already match the
  current targets), no `decline` call. **If the apply set is empty** (every
  outstanding group is snoozed), print
  `Snoozed N group(s); nothing else to update.` and continue as a refresh-only
  run.
- **Update all** (no snoozed groups) → clear any prior snoozes, apply
  everything:
  ```bash
  .gaia/cli/gaia update-deps decline --clear
  ```
  Apply set = the full payload.
- **Update everything incl. snoozed** → same action as Update all: clear the
  snoozes (`decline --clear`) and apply the full payload.
- **Choose what to skip** → collect the names, union with `snoozedGroups`, then
  record the whole skip set:
  ```bash
  .gaia/cli/gaia update-deps decline --source "$updates_json" --skip "<snoozed…,named…>"
  ```
  Each name expands to its whole companion group (a partial group cannot be
  skipped); an unknown name errors so you can re-ask. Apply set = the payload
  minus the skip set. Echo the resulting apply set back for confirmation.
  **If the apply set is now empty** (everything is skipped), print
  `Snoozed N group(s); nothing else to update.`, then continue as a
  refresh-only run, or exit (no branch) when `transitive-refresh` was also
  named.
  The name `transitive-refresh` is not a group: strip it from the names before
  the `decline` call and skip Phase 5b for this run only, it is never recorded
  in the ledger. If it was the only name given, handle the choice as **Update
  all** (or **Update the rest** when snoozed groups are present) with Phase 5b
  skipped. An advisory key named here is not a group either: strip it the same
  way and decline that advisory in the security plan (`references/security.md`,
  `### Security preview`).
- **Cancel** → stop here.

The snooze ledger (`.gaia/local/declined-updates.json`) is local-only and
gitignored: it suppresses the statusline nudge and default-skips the group in
this preview until a newer version ships or 14 days pass. It never HARD-gates a
run, the human can always choose to refresh a snoozed group, and CI ignores it
entirely (CI is the freshness backstop and keeps opening PRs).

Carry the **apply set** (filtered `wave_a` and `wave_b`) into the phases below,
together with whether Phase 5b runs: yes by default and in CI, no when the human
skipped `transitive-refresh`, never under `--scope` or `--security`. Carry the
**security plan** too (empty in a report-only run), with the opening advisory
key set, the opening `dismissedGhsas`, whether alerts were read, and the source
from the advisories call.

A **refresh-only run** has an empty apply set but still runs Phase 5b: every
direct dependency is current, or every outstanding group is snoozed or skipped.
It skips the Override audit + Wave A agent and Phase 5, runs Phase 5b first, and
creates its branch only when the refresh lands or the security plan has a
resolution to apply (see Branch creation). Phase 0 does not run, so Phase 6
runs only after a landed refresh or a landed security override, and treats
every key in the `overrides:` map as retained.

## Override audit + Wave A: Haiku agent

Spawn a **Haiku agent** (`model: "haiku"`) to run the override audit and the
Wave A batch install on the **apply set** computed above. Its prompt tells it to
read `.claude/skills/update-deps/references/override-audit.md` and
`.claude/skills/update-deps/references/wave-a.md`, run Phase 0 (skipped under
`--scope` and `--security`) then Wave A exactly as written, and gives it the
apply set's Wave A entries as the Wave A input, marking each chain-head bump
an advisory needs.

**Security chain-head bumps ride the waves.** A minor or patch chain-head bump
an advisory needs joins Wave A; a major one runs in Phase 5 as that group's
Wave B agent. Nothing looks up beforehand whether the head's new release admits
the patched version: after each wave returns, run `advisory-landed` (see
`references/security.md`, step 5) for every advisory that wave was meant to
clear, and that check is what verifies admission. A head bump that landed but
did not clear its advisory falls through to the advisory's next candidate in
the security phase. When Wave A reverts its batch (or a Wave B agent its group)
and the reverted set carried a security chain-head bump, that advisory also
falls through to its next candidate; with none left it is reported still open
with `wave reverted (Wave A)` or `wave reverted (<group>)`, not `quality gate
failed`.

## Branch creation (after discovery)

Phase 1 already exited if the human cancelled, or declined the transitive
refresh with nothing else to apply, so reaching here means the apply set is
non-empty, the security plan has a resolution to apply, or the run is
refresh-only. With a non-empty apply set, run this section after the Haiku
agent returns. When the apply set is empty but the security plan has at least
one resolution to apply (a security-only run, or `--security` with no
chain-head bump), run it right after the decision, and go on to the security
phase even when Phase 5b reports `Nothing moved` or `Reverted (<reason>)`. On a
refresh-only run with nothing in the security plan, run it after Phase 5b
returns, and only when it reports `landed`; on `Nothing moved` or
`Reverted (<reason>)`, skip this section and every phase up to Phase 7 and go
straight to the report (no branch exists, and Phase 8's nothing-updated rule
skips publish):

- Updates were confirmed. **Immediately bust the update-check cache** so the statusline reflects the post-update state on the next session regardless of whether this run completes. Use the Write tool to overwrite `.gaia/local/cache/shared/update-check.json`: read the existing cache first, then write it back unchanged **except** `outdatedCount` set to `0` and `checkedAt` set to the current Unix timestamp. **Carry every other field across verbatim, named here or not.** The cache holds fields this step has no reason to know about, and several are observations nothing later can reconstruct (`auditMemoryBaseline` and the two `harden*` counts), so dropping one silently disarms the nudge it belongs to instead of causing a visible error. If the cache file does not exist, skip this step. (Snoozed groups are already excluded by the ledger on the next real check.)

- If `SHOULD_CREATE_BRANCH=true`, create the branch now and **remember that you created it** (this determines publish behavior in Phase 8):

```bash
git checkout -b "$(bash .gaia/scripts/branch-name-lib.sh name deps)"
# CREATED_NEW_BRANCH=true, used in Phase 8
```

Otherwise (`SHOULD_CREATE_BRANCH=false`), proceed on the current branch and **remember that you did NOT create a new branch**.

## Phase 5: Wave B (per-group major bumps)

Use the **Wave B groups from the apply set** (the payload's `wave_b` minus any
group the human skipped). If there are none, skip to Phase 5b.

For each Wave B group, classify complexity and assign a model:

**Opus** (`model: "opus"`): `react-router`, `react`, `storybook`,
`singleton:typescript`

**Sonnet** (`model: "sonnet"`): `eslint`, all other groups

Spawn one agent per group (or sequentially if resource-constrained). Its prompt tells it to read `.claude/skills/update-deps/references/wave-b-group.md` and follow it exactly, with GROUP, FROM and TO filled in.

## Phase 5b: Transitive refresh (Haiku agent)

Waves A and B move direct specs only, and pnpm keeps a transitive dependency's locked version for as long as its parent's range still admits it, so a vulnerable transitive whose patched release is already in range survives every earlier phase. This phase asks pnpm for the newest in-range version of every transitive dependency. It runs before Phase 6 so the post-update override audit reads the refreshed tree.

Skip it when the human skipped `transitive-refresh` in the preview (report `Declined in preview`), under `--scope` (report `Not run (--scope)`), or under `--security` (report `Not run (--security)`). An advisory this refresh clears (its `advisory-landed` check exits 0 afterwards) is resolved by `in-range refresh` and gets no further resolution. Otherwise spawn a **Haiku agent** (`model: "haiku"`). Its prompt tells it to read `.claude/skills/update-deps/references/transitive-refresh.md` and follow it exactly, with the frozen names as FROZEN_NAMES. The **frozen names** are every package in `skipped[]` with `reason: "held"`, plus every member of a group in the skip set (empty when nothing was held or skipped).

## Phase 5c: Security resolutions

Resolve the advisories the security plan still owes by following `.claude/skills/update-deps/references/security.md` (`### Security resolutions`): in-range refresh and security-floor override resolutions, gated as a batch with a per-resolution revert, then acceptance. It runs after Phase 5b and before Phase 6, so Phase 6 audits every override it adds. The orchestrating session runs it itself, because acceptance asks the human; the resolution steps may be delegated to an agent only while no question is pending. In a report-only run it only records every advisory as still open with `report-only run`.

## Phase 6: Post-update override audit

The key scope is every key retained in Phase 0 plus every security override Phase 5c landed. Phase 6 runs whenever Phase 5c landed an override, including a zero-outdated run and a `--security` run (there, only those overrides). For each key in scope, repeat the full Phase 0 audit (both the peer-dep and the security-floor check, re-capturing a fresh advisory baseline against the now-updated tree) now that surrounding packages have moved. A version that landed in Wave A, Wave B, or the Phase 5b refresh may have resolved the original peer-dep conflict or carried the patched transitive dependency that made a security-floor pin obsolete. The toggle test re-resolves with `pnpm dedupe`, never a bare `pnpm install`, exactly as in Phase 0. This is the last phase that mutates the `overrides:` map, so the lockfile settles here: close it with the same assertion Phase 0 runs, the lockfile's `overrides:` block must list exactly the keys in `pnpm-workspace.yaml`, repairing any drift with `pnpm dedupe`.

On a refresh-only run Phase 0 did not run: Phase 6 runs only when Phase 5b reported `landed` or Phase 5c landed an override, and treats every key in the `overrides:` map as retained. Under `--security` it treats only the Phase 5c overrides as in scope.

Run this as a **Haiku agent**. Its dispatch carries every Phase 6 duty, so pass it all four of these:

- **The recipe.** `.claude/skills/update-deps/references/override-audit.md` (tell the agent to read it), restricted to the keys in scope above, so every quality-gate run it owes runs those same commands. Pass each security override with the advisory id Phase 5c recorded for it, so a retained floor is reported by that id.
- **When to gate.** Run the quality gate once, after the lockfile assertion, whenever it removed any key or repaired lockfile drift. No Wave agent gated that change. This replaces the drift-only trigger in the Phase 0 section.
- **On a failed gate.** Restore every key it removed to the value it held when this Phase 6 run began, run `pnpm dedupe` to apply the restore, and re-run the lockfile assertion. This is the counterpart of Wave A reverting its whole batch: one gate run cannot say which key broke it, so the restore takes them all. Report each restored removal as **retained (quality gate failed)**. When it changed no key and the gate ran only for a drift repair, there is nothing to restore: report the failure for the maintainer to resolve.
- **What to return.** The override audit results (removed / retained) and the quality gate results, including a failed gate and whatever restore followed it, so the Phase 7 Quality gate section has the Phase 6 run to report.

<!-- gaia:maintainer-only:start -->

## Phase 6b: `.gaia/cli` pin sync (GAIA maintainer repository)

`.gaia/cli` is a second workspace root with its own `package.json` and lockfile, and it inherits nothing from the root: a devDependency the two share can drift to different pinned versions with nothing to notice, and a lint- or type-rule package pinned differently in each workspace silently changes what each one flags. The phases above bump the root alone, so a run that moves a shared pin leaves `.gaia/cli` behind. Run this phase inline, after Phase 6 and before the report:

1. For each devDependency declared in both root `package.json` and `.gaia/cli/package.json` whose CLI spec differs from the root's, set the CLI spec to the root's verbatim. The direction is always CLI to root; never edit the root to match the CLI. Skip the rest of this phase only when nothing differs **and** the run left the root `pnpm-lock.yaml` unchanged.
2. Run `pnpm -C .gaia/cli install`, then `pnpm -C .gaia/cli lint`, `pnpm -C .gaia/cli typecheck`, and `pnpm -C .gaia/cli test`.
3. Run `pnpm -C .gaia/cli bundle`, then `bash .gaia/scripts/verify-cli-bundle-fresh.sh` from the repository root. Phase 8's `git add -A` commits any bundle that moved.
4. Add a `.gaia/cli pin sync` row to the report's Quality gate table naming each raised pin (`<name>: <old> → <new>`) and the step 2 and 3 results. On a failure, keep the raised pins, since reverting them reintroduces the drift this phase exists to prevent, and let the row carry the failure for the maintainer.

The raised pins put `.gaia/cli/package.json` and its lockfile in the diff, which dispatches `code-audit-maintainer-node`. On a run that started on `main`/`master`, Phase 8's merge step covers that dispatch; on any other run, the branch owner does.
<!-- gaia:maintainer-only:end -->

## Phase 7: Final report

**Security.** Before building the report, audit the final tree once, inline, from the project root, in every run. This audit is the authority for what is resolved, still open, and introduced; the opening advisories payload only enriches its rows (EPSS, scope, relationship, alert numbers), and the Dependabot alerts list is never the authority. It never fails the run, never reverts anything, and never edits the `overrides:` map.

```bash
mkdir -p .gaia/local/cache/shared
final_audit_json="$(mktemp .gaia/local/cache/shared/.update-deps-final-audit.XXXXXX)"
final_audit_err="$(mktemp .gaia/local/cache/shared/.update-deps-final-audit-err.XXXXXX)"
pnpm audit --json > "$final_audit_json" 2> "$final_audit_err" || true
jq -e '.advisories | type == "object"' "$final_audit_json" >/dev/null 2>&1 || { jq -r '.error.message // empty' "$final_audit_json" 2>/dev/null | grep . || head -n 1 "$final_audit_err" | grep . || echo "pnpm audit produced no JSON"; }
jq -r '.advisories // {} | .[] | [(.github_advisory_id // ("pnpm:" + (.id | tostring))), .id, .module_name, .severity, (.findings | map(.version) | unique | join(", ")), .patched_versions, (.findings | map(.paths[]) | unique | first), (.findings | map(.paths | length) | add)] | @tsv' "$final_audit_json"
```

`pnpm audit` exits non-zero whenever an advisory is open, so read the JSON, not the exit status. When the second command prints a line (no `advisories` object: `pnpm audit` reported an error or the registry did not answer), the source line reads `Source: Not run (<that line>)` and the run's applied resolutions are listed `unverified`. Otherwise each row is `key, pnpm id, package, severity, installed, patched, chain, path count`; the key is the GHSA id, or `pnpm:<id>` without one, the same key the advisories payload uses. In alerts mode you may re-run `advisories --emit` against the final tree for fresh joins. List every severity: the frontend audit's `pnpm audit` oracle surfaces only high and critical, and on a manifest-only `chore(deps)` PR it does not run at all. Remove the two capture files once the report is printed.

Build the report **only** from the agent reports returned to you, the snooze and transitive-refresh decisions from Phase 1, the Phase 5c result, and the final-tree audit above. Do not add rows from your own memory of the run.

**What goes in each section:**

- **Updated packages**: every package the Haiku agent or a Wave B agent reports as `updated`. Nothing else.
- **Breaking changes applied**: only what Wave B agents report editing in the codebase. Empty if no Wave B group ran.
- **Transitive refresh**: the Phase 5b agent's result: one row per package it moved (from and to), or one of `Nothing moved`, `Declined in preview`, `Not run (--scope)`, `Not run (--security)`, or `Reverted (<reason>)` followed by the rows that would have moved. Always include this section; `Nothing moved` is a result, not an empty section. These rows never go in Updated packages, and a reverted refresh is reported here, not in Skipped packages.
- **Overrides audited**: only what the Phase 0 / Phase 6 audit reports. If the `overrides:` map was empty, write "None" and move on. On a refresh-only run where Phase 6 did not run, write `Not run (refresh-only, tree unchanged)`.
- **Security**: always present, printed on every exit path as Global tools is, and never a bare `None`: the heading is always followed by the source line and all three tables, and an empty table reads `None.`. The source line is `Source: pnpm audit, enriched by Dependabot alerts` when alerts were read, `Source: pnpm audit. Dependabot alerts: Not run (<reasonText>)` when they were unavailable, `Source: pnpm audit. Dependabot alerts: Not run (CI run)` in CI, or `Source: Not run (<reason>)` when the final-tree audit failed.
  - **Resolved**: an opening advisory absent from the final-tree audit. Package, advisory key, method (`in-range refresh`, `chain-head bump (<pkg> <from> → <to>)`, `override (<key>: <value>)`, `chain-head major (<group>)`), new installed version. Append `(on this branch, pending merge)` when its alert is still open in alerts mode.
  - **Accepted**: package, advisory key, dismissal reason (or `baseline entry proposed` on the fallback).
  - **Still open**: every final-tree audit row not accepted. Package, advisory key, severity, installed, first patched, held back by (the extracted chain below its importer, plus `(+N more paths)` when the path count exceeds 1), and the reason from the security plan or Phase 5c (`report-only run` in a report-only run). Mark `introduced by this run` on a row whose key is not in the opening advisory set; that set is the opening payload's `advisories[].key` plus its `dismissedGhsas`, and this comparison is the whole test.
  - **Dismissed alerts.** In alerts mode, a final-tree audit record whose GHSA is in the opening `dismissedGhsas`, or that this run dismissed, is accepted, not open: it gets no Still open row and no `introduced by this run` marker. Without this, an advisory accepted in an earlier run would reappear as open and introduced on every run. On the fallback `dismissedGhsas` is `[]` and nothing changes; a final-tree row whose pnpm id `.gaia/local/dep-audit-baseline.json` acknowledges is Accepted with `baseline entry`.

  **Security cache rewrite.** After printing the report, in a run that reads alerts (never in CI: there the rewrite is skipped entirely, so a CI run never replaces a `dependabot` count with a `pnpm-audit` one), take the count from the advisories verb against the final tree, never from the report's tables:

  ```bash
  count_json="$(mktemp .gaia/local/cache/shared/.advisories-count.XXXXXX)"
  .gaia/cli/gaia update-deps advisories --emit "$count_json" --count-only
  jq -r '[.source, (.count | tostring), (.reasons | join(","))] | @tsv' "$count_json"
  ```

  When its source is `dependabot` or `pnpm-audit`, run `.gaia/cli/gaia update-deps write-security-cache --count <count> --source <source>`, adding `--reason <reasons>` when the reasons field is non-empty. When it is `unavailable`, do not call it: the three security fields stay as they are. The verb counts what the background refresh counts (open alerts, so this run's dismissals are already gone and branch-only resolutions still count; or the final tree minus baseline acknowledgments), so the two agree. Never hand-edit the cache's security fields. Remove `$count_json` afterwards.

- **Skipped packages**: _only_ packages that were attempted and reverted mid-run (peer-dep conflict, quality-gate failure, manual revert by an agent). **Never** include packages filtered out before installation by a policy rule (e.g. the ESLint 9.x cap or the release-age cooldown). Those are silent by design, surfacing them is noise the user sees every run. When you cannot tell whether a package was policy-filtered before installation or attempted and reverted mid-run, include it in Skipped, a spurious row is recoverable but a silently dropped real failure is not. If nothing was actually skipped during the run, write "None" or omit the table.
- **Snoozed (deferred this run)**: the companion groups the human chose to skip in the preview, with the version each was snoozed at. These quiet the statusline for 14 days (or until a newer version ships); they are not failures. Omit the section if the human chose "Update all".
- **Quality gate**: the gate result reported by the agents, verbatim.
- **Global tools**: always include the playwright-cli row from the Phase 1 global-tools step: status, installed, latest, and the action taken (`upgraded`, `declined`, `report-only`, `not installed`). It is built inline, so it is an exception to building the report only from agent reports, like the Security section. Print it on every exit path, including the all-up-to-date and Skip exits.

<!-- gaia:maintainer-only:start -->

- **Vendored skills**: built inline from the Vendored skill sync step, so it is an exception to building the report only from agent reports. One row: marker version, upstream latest, and `current`, `re-vendored`, `verify failed (<path>)`, or `unknown`.
- **Phase 6b**: runs inline rather than as an agent, so its `.gaia/cli pin sync` row is an exception to building the report only from agent reports, like the Security section. Include it whenever Phase 6b ran past step 1, including a failed step it kept in the diff.

<!-- gaia:maintainer-only:end -->

If a section would be empty, write "None" rather than leaving it blank or fabricating filler.

Print the report. Do not commit.

```
## Migration Report

### Updated packages
| Group | Package | From | To | Type |
| --- | --- | --- | --- | --- |

### Breaking changes applied
- [group] description

### Transitive refresh
| Package | From | To |
| --- | --- | --- |

### Overrides audited
- Removed: <key>, <reason>
- Retained: <key>, <reason>

### Security
Source: pnpm audit, enriched by Dependabot alerts

Resolved
| Package | Advisory | Method | Installed now |
| --- | --- | --- | --- |

Accepted
| Package | Advisory | Reason |
| --- | --- | --- |

Still open
| Package | Advisory | Severity | Installed | First patched | Held back by | Reason |
| --- | --- | --- | --- | --- | --- | --- |

### Skipped packages
| Package | Reason |
| --- | --- |

### Snoozed (deferred this run)
| Group | Snoozed at version | Resurfaces |
| --- | --- | --- |

### Quality gate
| Step | Result |
| --- | --- |

### Global tools
| Tool | Status | Installed | Latest | Action |
| --- | --- | --- | --- | --- |
```

## Phase 8: Publish

**If nothing was updated** (all packages were already up to date or all were skipped, the transitive refresh did not report `landed`, and no security resolution landed), skip this phase entirely. Phase 8 runs when the only landed work is security resolutions. An accepted advisory changes no file (its dismissal lives on GitHub), so acceptance alone publishes nothing.
<!-- gaia:maintainer-only:start -->

A re-vendor diff from the Vendored skill sync step counts as an update: publish it even when no package moved, with the subject `chore(deps): re-vendor playwright-cli skill <version>`. It touches paths beyond the dependency manifests, so it gets the normal audit handshake, not the dep-bump bypass.
<!-- gaia:maintainer-only:end -->

**Commit the update.** Stage and commit the applied changes on the current branch. Write the message to a temp file first, then commit from it:

```bash
git add -A
git commit -F <commit-message-file>
```

The commit **subject** must be `chore(deps): <concise summary of what moved>` (use `chore(deps-dev):` when every landed change is a devDependency version bump; a refresh-only run uses `chore(deps): refresh transitive dependencies`). The summary names the security work, for example `chore(deps): resolve 2 security advisories (cookie, tar)`. An in-range refresh or a security-floor override has no declared dependency type, so a run whose landed changes are only security resolutions, with no devDependency-only version bump, always uses `chore(deps):`. A reverted resolution leaves no trace in the commit: its revert restored its files before staging. Every `/update-deps` commit follows a passing local quality gate. That subject triggers the dep-bump bypass in the merge gate (`wiki/concepts/PR Merge Workflow.md`; `.gaia/scripts/chore-deps-skip.sh` decides it) only when every path the PR changes is a dependency manifest (`package.json`, `pnpm-lock.yaml`, `pnpm-workspace.yaml` at the repository root); a migration edit, a root-config change, or any other path denies the bypass and the PR gets the normal audit handshake and the normal Tests/Chromatic runs. On a manifest-only PR the bypass waives code-audit-frontend only; any other member the diff dispatches still earns its own marker. Routing the message through a file rather than `-m` keeps package-manager keywords from tripping shell-hook false positives. The Wave agents already ran the full quality gate over their changes, and Phase 6 kept only the override changes that passed it, so nothing else is owed before committing. A Phase 6 gate failure with nothing to restore is already in the report's Quality gate section for the maintainer.
<!-- gaia:maintainer-only:start -->

In this checkout the same three manifests under `.gaia/cli/` also count as dependency manifests.
A Phase 6b failure is the exception: it keeps its raised pins and reports through its `.gaia/cli pin sync` row, so the required `Vitest (.gaia/cli)` check stays red and step 3's queued merge waits on the maintainer rather than landing.
<!-- gaia:maintainer-only:end -->

Then branch on where the run started.

**If a new branch was created** (interactive run, you were on `main`/`master` at pre-flight and branched off):

1. Push the branch:
   ```bash
   git push -u origin <branch-name>
   ```
2. Open a PR against `main`. Title: the commit subject. Body: the migration report rendered as markdown, via `--body-file` on a temp file (same false-positive reason). Capture the PR number `<N>` and its URL.
3. **Merge when green, then clean up locally.** This step runs only on a `main`/`master` run, it is what "completes the flow." Merge per `wiki/concepts/PR Merge Workflow.md`: when the PR's diff is manifest-only, the `chore(deps)` title clears its audit-marker gate via the dep-bump bypass; otherwise run the full audit handshake in that page (spawn every member `resolve-audit-members.sh` names, `code-audit-frontend` included) before the merge call below.

<!-- gaia:maintainer-only:start -->

On a manifest-only run, first run `bash .gaia/scripts/resolve-audit-members.sh` and spawn each member it names other than `code-audit-frontend`, per that workflow page's "Spawn the dispatched Code Audit Team members" section. Whenever Phase 6b raised a pin, `code-audit-maintainer-node` is among them. If the Phase 6b bundle rebuild moved a committed `.gaia/cli` bundle file (Phase 8's `git add -A` picks up only a bundle that actually moved), the diff is NOT manifest-only, so spawn `code-audit-frontend` too, same as any other member. Otherwise, on a manifest-only run, the `chore(deps)` title waives only `code-audit-frontend` (see the bypass paragraph in `wiki/concepts/PR Merge Workflow.md`), so each other member's earned marker is what completes the handshake. Skip this and `GAIA-Audit` stays at `members pending` and the queued merge waits on it indefinitely. Members write their markers only, they do not post the success status themselves; once `wiki/concepts/PR Merge Workflow.md` `#### Posting the status last` conditions hold, post it yourself, `bash .claude/hooks/post-audit-status.sh <path to a current member marker>`, before the merge call below.
<!-- gaia:maintainer-only:end -->

```bash
gh pr merge <N> --squash --delete-branch --auto
```

`--auto` queues the merge so GitHub lands it once the required checks pass (or immediately if they are already green). If the repo has auto-merge disabled and `gh` rejects `--auto`, wait for the required checks to pass by reading `gh pr checks <N>` as a bounded series of single calls, not a shell loop (`.claude/hooks/block-handrolled-pr-poll.sh` denies a loop naming `gh pr checks` that reads no `mergeable`), then re-run the merge without `--auto`.

`gh pr merge` can exit success while the merge is still queued, so verify the terminal state before touching the local checkout with the bounded poll in `wiki/concepts/PR Merge Workflow.md` (`## Post-merge verification before cleanup`), which also stops early on every state that means the merge will never land.

```bash
bash .gaia/scripts/pr-wait-merge.sh --pr <N> --attempts 20
```

The 20-attempt bound replaces the default 5, for the reason the sibling callers give: the merge queued above lands only after a fresh full CI run, which outlasts the ~2.5 minutes the default spends, so a default-bound wait would report `TIMEOUT` on essentially every run and the cleanup below would never be reached.

- **`MERGED`** (exit 0) → clean up locally, then print the merged PR URL:
  ```bash
  git checkout main && git pull origin main
  git branch -D <branch-name>
  git fetch --prune origin
  ```
- **`TIMEOUT`** (exit 5, the bound was spent with the pull request still open) → print the PR URL and note that the merge queued above has not landed yet. **Do not** delete the local branch or switch off it, the PR is still open.
- **`CONFLICTING`** (exit 3) → repair it per that page's `### Conflict found mid-wait` and run the wait again.
- **`CHECK_FAILED`** (exit 4) → print the PR URL and the failing check, and leave the branch in place as for a queued merge.
- **`CLOSED`** (exit 6) → the pull request was closed without merging, so no wait can clear it: report that, leave the branch in place, and stop.
- **the wait refused rather than answered** (exit 2) → report what it could not read, leave the branch in place, and assert no state for the pull request.

**If you were already on a non-main branch** at pre-flight, or running in CI (no new branch was created):

1. Push the branch:
   ```bash
   git push
   ```
2. Do not open a PR and do not merge, the branch owner (the user, or the CI job that invoked it) drives it from here.

If any `git push`, `gh pr create`, or `gh pr merge` above exits non-zero, print the command's error and STOP. Do not retry, force-push, or amend, a rejected push, failed PR creation, or blocked merge is the user's call to resolve (usually a manual rebase, a remote-side block, or a failing check).
