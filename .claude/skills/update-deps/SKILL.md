---
name: update-deps
description: Autonomous Dependabot, auto-discover outdated packages, audit overrides, apply migrations for major bumps, resolve conflicts, run quality gate. Trigger when the user clicks the statusline `Run /update-deps` indicator or asks "update dependencies", "bump deps", "run dependabot".
---

Superpowered Dependabot. Auto-discover all outdated packages, preview them grouped by severity so you can snooze any you are not ready for, audit overrides, apply codebase migrations for major bumps, resolve dependency conflicts, and run the quality gate. In CI it runs unattended (no preview); interactively it shows the preview first.

## Pre-flight: Worktree check

This wrapper writes a new `pnpm-lock.yaml` and opens a PR, both belong on the main checkout, not a per-SPEC worktree branch. If invoked from a linked worktree, reject hard with a message that surfaces the cached state from main so the user knows whether action is even pending.

Detection (run this first, before anything else):

```bash
common_dir="$(git rev-parse --git-common-dir 2>/dev/null)"
if [ -n "$common_dir" ]; then
  case "$common_dir" in
    /*) absolute_common_dir="$common_dir" ;;
    *)  absolute_common_dir="$(pwd)/$common_dir" ;;
  esac
  main_root="$(cd "$(dirname "$absolute_common_dir")" 2>/dev/null && pwd)"
  current_root="$(git rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$main_root" ] && [ -n "$current_root" ] && [ "$main_root" != "$current_root" ]; then
    cached_line="Cached state unavailable on main; symlinks may be broken, run \`.gaia/cli/gaia setup link-worktree\` to repair."
    cache_file="$main_root/.gaia/cache/update-check.json"
    if [ -f "$cache_file" ] && command -v jq >/dev/null 2>&1; then
      outdated_count="$(jq -r '.outdatedCount // 0' "$cache_file" 2>/dev/null)"
      checked_at="$(jq -r '.checkedAt // 0' "$cache_file" 2>/dev/null)"
      if [ -n "$outdated_count" ] && [ -n "$checked_at" ] && [ "$checked_at" != "0" ]; then
        now=$(date +%s)
        age=$((now - checked_at))
        # Format age as <Nm ago> / <Nh ago> / <Nd ago>.
        ago_unit="s"; ago_value="$age"
        if [ "$age" -ge 86400 ]; then ago_unit="d"; ago_value=$((age / 86400));
        elif [ "$age" -ge 3600 ]; then ago_unit="h"; ago_value=$((age / 3600));
        elif [ "$age" -ge 60 ]; then ago_unit="m"; ago_value=$((age / 60));
        fi
        cached_line="Cached on main: $outdated_count packages outdated (last checked ${ago_value}${ago_unit} ago)."
      fi
    fi
    cat <<EOF
/update-deps must run from the main checkout, not a worktree.

Worktree:       $current_root
Main checkout:  $main_root

$cached_line

Run \`cd $main_root\` then re-invoke /update-deps.
EOF
    exit 1
  fi
fi
```

If the detection does not fire, fall through to the existing `## Pre-flight: Branch check` section.

## Pre-flight: Branch check

```bash
git branch --show-current
```

If the current branch is `main` or `master` **and not running in CI**, set a flag (`SHOULD_CREATE_BRANCH=true`) but **do not create the branch yet**, branch creation is deferred until after Phase 1 confirms there are packages to update. Creating a branch when there is nothing to update pollutes the branch list.

In CI (`CI=true`, set by GitHub Actions, GitLab CI, CircleCI, and most CI providers), skip branch creation, the workflow owns branch management and pre-creates the appropriate branch before this skill runs.

Otherwise set `SHOULD_CREATE_BRANCH=false` and proceed on the current branch.

## Composition: --scope &lt;group-name&gt;

When invoked with `--scope <group-name>` (e.g. `/update-deps --scope react-router`):

- Skip Phase 0 (override audit), out of scope for a single-group run.
- Skip the discovery + preview phase, no preview runs in `--scope`; the
  group's members are known from the companion-group table.
- Skip wave classification, the run is implicitly a single group; treat it
  as Wave A if all members are minor/patch, else Wave B.
- Wave A / Wave B still apply, scoped to the named group's members
  in root `package.json`.
- Quality gate, return value, and final report still run.

Used by the GAIA CI update-deps workflow's wave-B matrix shards to fan
out one PR per major-bump group.

## Companion groups (reference)

The fixed table mapping each package to its group. `gaia update-deps run`
(`.gaia/cli/src/update-deps/groups.ts`) implements it and is the source of
truth at runtime; every emitted entry already carries its resolved `group`.
**When any member of a group is outdated, all members present in `package.json`
update together**, so a group moves as one unit (and snoozes as one unit).

| Group             | Members                                                                                                                                                                      |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `react-router`    | `react-router`, `react-router-dom`, `@react-router/dev`, `@react-router/node`, `@react-router/serve`, `@react-router/fs-routes`, `@react-router/remix-routes-option-adapter` |
| `react`           | `react`, `react-dom`, `@types/react`, `@types/react-dom`                                                                                                                     |
| `tailwindcss`     | `tailwindcss`, `@tailwindcss/vite`, `@tailwindcss/forms`, `@tailwindcss/typography`, `prettier-plugin-tailwindcss`                                                           |
| `storybook`       | `storybook`, `@storybook/*`, `eslint-plugin-storybook`, `msw-storybook-addon`, `storybook-react-i18next`, `@vueless/storybook-dark-mode`                                     |
| `vitest`          | `vitest`, `@vitest/coverage-v8`, `@vitest/ui`, `@vitest/eslint-plugin`                                                                                                       |
| `playwright`      | `@playwright/test`, `@playwright-testing-library/test`                                                                                                                       |
| `eslint`          | `eslint`, `@eslint/js`, `@eslint/compat`, `eslint-config-*`, `eslint-plugin-*` (9.x cap applies)                                                                             |
| `testing-library` | `@testing-library/dom`, `@testing-library/react`, `@testing-library/jest-dom`, `@testing-library/user-event`                                                                 |
| `typescript`      | `typescript`, `@types/node`                                                                                                                                                  |
| `i18next`         | `i18next`, `react-i18next`, `remix-i18next`, `i18next-browser-languagedetector`                                                                                              |
| `msw`             | `msw`, `msw-storybook-addon`                                                                                                                                                 |
| `vite`            | `vite`, `@vitejs/plugin-react`                                                                                                                                               |
| `zod-conform`     | `zod`, `@conform-to/react`, `@conform-to/zod`                                                                                                                                |
| `fontawesome`     | `@fortawesome/*`                                                                                                                                                             |
| `stylelint`       | `stylelint`, `stylelint-config-*`, `stylelint-order`                                                                                                                         |
| `prettier`        | `prettier`, `eslint-config-prettier`, `eslint-plugin-prettier`                                                                                                               |
| `husky`           | `husky`, `lint-staged`                                                                                                                                                       |

Packages not matched form singleton groups.

## Phase 1: Discover, preview, decide (orchestrator)

Discover deterministically via the CLI primitive, the single source of truth for
grouping, the ESLint 9.x cap, and the release-age cooldown (all already applied):

```bash
updates_json="$(mktemp)"
.gaia/cli/gaia update-deps run --emit-updates "$updates_json"
```

Read the payload. If `total_count` is `0`, print `All packages are up to date.`
and exit (no branch, no changes). Each `wave_a[]` and `wave_b[].packages[]` entry
carries `bucket` (`patch` | `minor` | `major` | `nonsemver`), `current`, `latest`,
`group`, `is_pinned`, and `kind`. `total_count` is the genuine-upgrade count;
`actionable_count` is for the statusline only (it already subtracts local
snoozes), ignore it here.

**In CI (`CI=true`) or with `--scope <group>`, skip the preview and decision
entirely.** The apply set is the full payload (CI) or the named group
(`--scope`); jump straight to the apply phases with an empty skip set and no
ledger write.

### Preview

Group the entries for display into four sections in this order: **Major**,
**Non-semver**, **Minor**, **Patch**. A companion group (any `group` not prefixed
`singleton:`) renders as ONE block under the section of its most-severe member
(severity major > nonsemver > minor > patch) and is a single choice that updates
together. Render each row as `name  current → next`; for a companion group, list
its members under one labelled block (e.g. "react-router group, updates
together"). Default is to update everything.

If `update_deps.mode` in `.gaia/automation.json` is `ci`, first print one line:
`CI owns updates; snoozing here only quiets your local statusline.`

Then ask with `AskUserQuestion` (single-select, options in this order):

- **Update all** (default, first option): apply every group.
- **Choose what to skip**: the human names the package or group names to skip;
  everything else applies.
- **Cancel**: exit now, no branch, no changes, no ledger write.

### Decision

- **Update all** → clear any prior snoozes, apply everything:
  ```bash
  .gaia/cli/gaia update-deps decline --clear
  ```
  Apply set = the full payload.
- **Choose what to skip** → collect the names, then record the snooze:
  ```bash
  .gaia/cli/gaia update-deps decline --source "$updates_json" --skip "<n1,n2,...>"
  ```
  Each name expands to its whole companion group (a partial group cannot be
  skipped); an unknown name errors so you can re-ask. Apply set = the payload
  minus the skipped groups. Echo the resulting apply set back for confirmation.
  **If the apply set is now empty** (everything was skipped), print
  `Snoozed N group(s); nothing to update now.` and exit (no branch).
- **Cancel** → stop here.

The snooze ledger (`.gaia/local/declined-updates.json`) is local-only and
gitignored: it suppresses the statusline nudge until a newer version ships or 14
days pass. It never gates a run, a snoozed group still appears (and is updatable)
in every future preview, and CI ignores it entirely (CI is the freshness
backstop and keeps opening PRs).

Carry the **apply set** (filtered `wave_a` and `wave_b`) into the phases below.

## Override audit + Wave A: Haiku agent

Spawn a **Haiku agent** (`model: "haiku"`) to run the override audit and the
Wave A batch install on the **apply set** computed above. Pass it these
instructions verbatim, substituting the apply set's Wave A entries into the
Wave A input:

---

### Phase 0: Override audit

For each key in the top-level `overrides:` map in `pnpm-workspace.yaml` (pnpm 11 reads overrides here; the `package.json` `pnpm.overrides` field is no longer honored):

1. Temporarily remove that single key from the `overrides:` map.
2. Run `pnpm install`.
3. Run `pnpm ls 2>&1` and scan for peer-dep errors.
4. If no errors → override is obsolete. Leave it removed. Note as **removed** in final report.
5. If errors → restore that key. Note as **retained** in final report.

Operate on one key at a time, leaving every other `pnpm-workspace.yaml` setting untouched. Always `pnpm install` after each toggle.

### Wave A input

You are given the **Wave A apply set**: the `wave_a` entries from the
orchestrator's discovery, minus any group the human chose to skip. Each entry
carries `name`, `current`, `latest`, `is_pinned`, and `kind` (`minor` or
`patch`). Do **not** run `pnpm outdated` or re-discover, the ESLint 9.x cap, the
release-age cooldown, and companion-group expansion are already applied. If the
Wave A apply set is empty, skip straight to the quality gate (Wave B groups, if
any, are handled by the orchestrator).

### Wave A (batch minor/patch)

1. Build install args. For each entry: if `is_pinned` use the exact target, else use `^<latest>`. Example: `pnpm add foo@1.2.3 bar@^4.5.0 ...`.
2. Run the single `pnpm add` command.
3. Run `pnpm ls 2>&1`. Scan for peer-dep errors.
4. On error: try one targeted fix in the `overrides:` map in `pnpm-workspace.yaml` (e.g. add a `parent>child` pin), then `pnpm install` again.
5. If still failing: revert the offending packages (`pnpm add <pkg>@<previous>`) and log them as **skipped** with the reason.
6. Run the quality gate (below). If it fails, revert the entire Wave A batch.

### Quality gate

```bash
pnpm typecheck
pnpm lint
pnpm test --run
pnpm pw
pnpm build
```

### Return value

Report back to the orchestrator with:

- Override audit results (removed / retained)
- Wave A results (updated packages, any skipped)
- Quality gate results

---

## Branch creation (after discovery)

Phase 1 already exited if nothing was outstanding or the human cancelled or
skipped everything, so reaching here means the apply set is non-empty. After the
Haiku agent returns:

- Updates were confirmed. **Immediately bust the update-check cache** so the statusline reflects the post-update state on the next session regardless of whether this run completes. Use the Write tool to overwrite `.gaia/cache/update-check.json`, preserving `gaiaCurrent`, `gaiaLatest`, and `gaiaHasUpdate` from the existing cache (read it first), but setting `outdatedCount` to `0` and `checkedAt` to the current Unix timestamp. If the cache file does not exist, skip this step. (Snoozed groups are already excluded by the ledger on the next real check.)

- If `SHOULD_CREATE_BRANCH=true`, create the branch now and **remember that you created it** (this determines publish behavior in Phase 8):

```bash
git checkout -b chore/update-deps-$(date +%Y-%m-%d-%H-%M)
# CREATED_NEW_BRANCH=true, used in Phase 8
```

Otherwise (`SHOULD_CREATE_BRANCH=false`), proceed on the current branch and **remember that you did NOT create a new branch**.

## Phase 5: Wave B (per-group major bumps)

Use the **Wave B groups from the apply set** (the payload's `wave_b` minus any
group the human skipped). If there are none, skip to Phase 6.

For each Wave B group, classify complexity and assign a model:

**Opus** (`model: "opus"`): `react-router`, `react`, `typescript`, `storybook`

**Sonnet** (`model: "sonnet"`): `eslint`, all other groups

Spawn one agent per group (or sequentially if resource-constrained), passing it these instructions:

---

### Wave B group instructions

You are upgrading the `{GROUP}` dependency group from `{FROM}` to `{TO}`.

**Scope.** Operate on the **root pnpm project only**.

- Run every `pnpm` command from the project root. Never `cd` into subdirectories or use `-C <path>`.
- For code edits and grep-style searches, scan only `app/`, `test/`, and root config files (`*.config.*`, `tsconfig*.json` at root). Do **not** scan the entire repository, sibling directories may be independent pnpm projects with their own `package.json`/`pnpm-lock.yaml`, and they are out of scope for this skill.
- A directory is "out of scope" if it contains its own `package.json` or `pnpm-lock.yaml`. Skip those subtrees entirely.

1. **Fetch migration guide** via WebFetch using the table below. If no URL applies, scan the GitHub release notes.
2. **Install** the group, **from project root only**:
   - `storybook` group: run `pnpm dlx storybook@latest upgrade` (Storybook's own upgrade tool migrates config alongside the version bump).
   - All others: `pnpm add <pkg1>@<latest> <pkg2>@<latest> ...` for every group member present in root `package.json`.
3. **Conflict check**: `pnpm ls 2>&1`. On peer-dep error, attempt one `overrides:` fix in `pnpm-workspace.yaml`. If still failing, revert the group and skip with reason.
4. **Apply breaking changes** within root scope: from the migration guide, identify code-affecting changes (renamed APIs, removed exports, config schema changes). Grep `app/`, `test/`, and root config files for affected patterns. Edit only files inside root scope.
5. **Verify root `package.json` moved**: read root `package.json` and confirm every group member you bumped now shows the new version. If `pnpm add` did not change root's spec (e.g. the dep is declared in a sibling project's `package.json` and not actually consumed by root code), revert the install and report the package as **skipped, not a root dep**. The skill does not resolve cross-project declarations; the maintainer must clean up manually. If the dep is in root `package.json` but has zero call sites in root scope, that's a phantom declaration: bump it anyway so the version stays current, and add a one-line note `phantom: no call sites in root` to the breaking-changes report so the maintainer can investigate.
6. **Quality gate**:
   ```bash
   pnpm typecheck
   pnpm lint
   pnpm test --run
   pnpm pw
   pnpm build
   ```
   On failure, attempt fixes inferred from the migration guide. If unfixable after a reasonable attempt, revert the entire group and log as skipped.

Migration guide URLs:

| Group        | URL                                                                        |
| ------------ | -------------------------------------------------------------------------- |
| react-router | `https://reactrouter.com/upgrading/v7`                                     |
| react        | `https://react.dev/blog` (find the major-version post)                     |
| tailwindcss  | `https://tailwindcss.com/docs/upgrade-guide`                               |
| storybook    | `https://storybook.js.org/docs/migration-guide`                            |
| vitest       | `https://vitest.dev/guide/migration`                                       |
| playwright   | `https://playwright.dev/docs/release-notes`                                |
| eslint       | `https://eslint.org/docs/latest/use/migrate-to-9` (or relevant X)          |
| typescript   | `https://www.typescriptlang.org/docs/handbook/release-notes/overview.html` |
| msw          | `https://mswjs.io/docs/migrations`                                         |
| vite         | `https://vite.dev/guide/migration`                                         |

Report back: updated packages, breaking changes applied, any skipped reason, quality gate results.

---

## Phase 6: Post-update override audit

For every override that was **retained** in Phase 0, repeat the Phase 0 toggle test now that surrounding packages have moved. New versions may have resolved the original conflict. Run this as a **Haiku agent**.

## Phase 7: Final report

Build the report **only** from the agent reports returned to you, plus the snooze decision from Phase 1. Do not add rows from your own memory of the run.

**What goes in each section:**

- **Updated packages**: every package the Haiku agent or a Wave B agent reports as `updated`. Nothing else.
- **Breaking changes applied**: only what Wave B agents report editing in the codebase. Empty if no Wave B group ran.
- **Overrides audited**: only what the Phase 0 / Phase 6 audit reports. If the `overrides:` map was empty, write "None" and move on.
- **Skipped packages**: _only_ packages that were attempted and reverted mid-run (peer-dep conflict, quality-gate failure, manual revert by an agent). **Never** include packages filtered out before installation by a policy rule (e.g. the ESLint 9.x cap or the release-age cooldown). Those are silent by design, surfacing them is noise that adopters see every run. If nothing was actually skipped during the run, write "None" or omit the table.
- **Snoozed (deferred this run)**: the companion groups the human chose to skip in the preview, with the version each was snoozed at. These quiet the statusline for 14 days (or until a newer version ships); they are not failures. Omit the section if the human chose "Update all".
- **Quality gate**: the gate result reported by the agents, verbatim.

If a section would be empty, write "None" rather than leaving it blank or fabricating filler.

Print the report. Do not commit.

```
## Migration Report

### Updated packages
| Group | Package | From | To | Type |
| --- | --- | --- | --- | --- |

### Breaking changes applied
- [group] description

### Overrides audited
- Removed: <key>, <reason>
- Retained: <key>, <reason>

### Skipped packages
| Package | Reason |
| --- | --- |

### Snoozed (deferred this run)
| Group | Snoozed at version | Resurfaces |
| --- | --- | --- |

### Quality gate
| Step | Result |
| --- | --- |
```

## Phase 8: Publish

**If nothing was updated** (all packages were already up to date or all were skipped), skip this phase entirely.

**If a new branch was created** (you were on `main`/`master` at pre-flight and branched off):

1. Push the branch:
   ```bash
   git push -u origin <branch-name>
   ```
2. Open a PR against `main`. Title: the commit message from the update commit. Body: the migration report rendered as markdown. Use `--body-file` with a temp file to avoid shell-hook false positives on package manager keywords in the body.

**If you were already on a non-main branch** at pre-flight (no new branch was created):

1. Push the branch:
   ```bash
   git push
   ```
2. Do not open a PR, the user owns the branch context.

In both cases, print the resulting PR URL (if created) or confirm the push completed.
