---
name: update-deps
description: Autonomous Dependabot — auto-discover outdated packages, audit overrides, apply migrations for major bumps, resolve conflicts, run quality gate. Trigger when the user clicks the statusline `Run /update-deps` indicator or asks "update dependencies", "bump deps", "run dependabot".
---

Autonomous superpowered Dependabot. Auto-discover all outdated packages, audit overrides, apply codebase migrations for major bumps, resolve dependency conflicts, and run the quality gate. No user prompts — just execute.

## Pre-flight: Worktree check

This wrapper writes a new `pnpm-lock.yaml` and opens a PR — both belong on the main checkout, not a per-SPEC worktree branch. If invoked from a linked worktree, reject hard with a message that surfaces the cached state from main so the user knows whether action is even pending.

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
    cached_line="Cached state unavailable on main; symlinks may be broken — run \`gaia setup link-worktree\` to repair."
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

If the current branch is `main` or `master` **and not running in CI**, set a flag (`SHOULD_CREATE_BRANCH=true`) but **do not create the branch yet** — branch creation is deferred until after Phase 1 confirms there are packages to update. Creating a branch when there is nothing to update pollutes the branch list.

In CI (`CI=true`, set by GitHub Actions, GitLab CI, CircleCI, and most CI providers), skip branch creation — the workflow owns branch management and pre-creates the appropriate branch before this skill runs.

Otherwise set `SHOULD_CREATE_BRANCH=false` and proceed on the current branch.

## Composition: --scope &lt;group-name&gt;

When invoked with `--scope <group-name>` (e.g. `/update-deps --scope react-router`):

- Skip Phase 0 (override audit) — out of scope for a single-group run.
- Skip Phase 1 (discovery) — the group's members are known from the
  companion-group table.
- Skip Phase 3 (wave classification) — the run is implicitly a single
  group; treat it as Wave A if all members are minor/patch, else Wave B.
- Phase 4 / Phase 5 still apply, scoped to the named group's members
  in root `package.json`.
- Quality gate, return value, and final report still run.

Used by the GAIA CI update-deps workflow's wave-B matrix shards to fan
out one PR per major-bump group.

## Phase 0–4: Haiku agent

Spawn a **Haiku agent** (`model: "haiku"`) to run Phases 0–4. Pass it these instructions verbatim:

---

### Phase 0: Override audit

For each key in `pnpm.overrides` (in `package.json`):

1. Temporarily remove that single key from `pnpm.overrides`.
2. Run `pnpm install`.
3. Run `pnpm ls 2>&1` and scan for peer-dep errors.
4. If no errors → override is obsolete. Leave it removed. Note as **removed** in final report.
5. If errors → restore that key. Note as **retained** in final report.

Operate on one key at a time. Always `pnpm install` after each toggle.

### Phase 1: Discover outdated packages

```bash
pnpm outdated --json
```

Parse the JSON. For each entry record:

- `name`
- `current` version
- `latest` version
- `is_major_bump` (compare leading integers)
- `is_pinned` (no `^` or `~` prefix in the spec found in `package.json`)

**ESLint cap:** if `eslint` or `@eslint/js` show a `latest` whose major is `>= 10`, find the highest available `9.x` (`pnpm view eslint versions --json` and pick the highest `9.x.y`) and treat that as the target. If already on the latest `9.x`, drop the entry.

Apply this silently. Capped packages MUST NOT appear anywhere in the final report — not in Updated, not in Skipped, not in Breaking changes. Adopters know about the cap; surfacing it on every run is noise.

If nothing is outdated after this filtering, print `All packages are up to date.` and exit.

### Phase 2: Resolve companion groups

Map each outdated package into its group. **When any member of a group is outdated, include all members present in `package.json`** in the update — even ones not flagged outdated — so the group moves together.

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

### Phase 3: Classify into waves

- **Wave A** — groups whose members all have minor or patch bumps only. Batched into one install.
- **Wave B** — groups containing at least one major bump. Processed individually, ordered: `react-router`, `react`, `tailwindcss`, `storybook`, `vitest`, `playwright`, `eslint`, then remaining alphabetically.

### Phase 4: Wave A (batch minor/patch)

1. Build install args. For each package: if `is_pinned` use exact target, else use `^<latest>`. Example: `pnpm add foo@1.2.3 bar@^4.5.0 ...`.
2. Run the single `pnpm add` command.
3. Run `pnpm ls 2>&1`. Scan for peer-dep errors.
4. On error: try one targeted `pnpm.overrides` fix (e.g. add a `parent>child` pin), then `pnpm install` again.
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
- **Wave B groups** — list each group name and its major bump (e.g. `react-router: 6 → 7`)
- Quality gate results

---

## Branch creation (after discovery)

After the Haiku agent returns:

- If Phase 1 reported `All packages are up to date.`, skip the rest of this skill entirely. **Do not create a branch.**
- Otherwise, updates were confirmed. **Immediately bust the update-check cache** so the statusline reflects the post-update state on the next session regardless of whether this run completes:

```bash
rm -f .gaia/cache/update-check.json
```

- If `SHOULD_CREATE_BRANCH=true`, create the branch now and **remember that you created it** (this determines publish behavior in Phase 8):

```bash
git checkout -b chore/update-deps-$(date +%Y-%m-%d-%H-%M)
# CREATED_NEW_BRANCH=true — used in Phase 8
```

Otherwise (`SHOULD_CREATE_BRANCH=false`), proceed on the current branch and **remember that you did NOT create a new branch**.

## Phase 5: Wave B (per-group major bumps)

After the Haiku agent returns, if there are no Wave B groups, skip to Phase 6.

For each Wave B group, classify complexity and assign a model:

**Opus** (`model: "opus"`): `react-router`, `react`, `typescript`, `storybook`

**Sonnet** (`model: "sonnet"`): `eslint`, all other groups

Spawn one agent per group (or sequentially if resource-constrained), passing it these instructions:

---

### Wave B group instructions

You are upgrading the `{GROUP}` dependency group from `{FROM}` to `{TO}`.

**Scope.** Operate on the **root pnpm project only**.

- Run every `pnpm` command from the project root. Never `cd` into subdirectories or use `-C <path>`.
- For code edits and grep-style searches, scan only `app/`, `test/`, and root config files (`*.config.*`, `tsconfig*.json` at root). Do **not** scan the entire repository — sibling directories may be independent pnpm projects with their own `package.json`/`pnpm-lock.yaml`, and they are out of scope for this skill.
- A directory is "out of scope" if it contains its own `package.json` or `pnpm-lock.yaml`. Skip those subtrees entirely.

1. **Fetch migration guide** via WebFetch using the table below. If no URL applies, scan the GitHub release notes.
2. **Install** the group, **from project root only**:
   - `storybook` group: run `pnpm dlx storybook@latest upgrade` (Storybook's own upgrade tool migrates config alongside the version bump).
   - All others: `pnpm add <pkg1>@<latest> <pkg2>@<latest> ...` for every group member present in root `package.json`.
3. **Conflict check**: `pnpm ls 2>&1`. On peer-dep error, attempt one `pnpm.overrides` fix. If still failing, revert the group and skip with reason.
4. **Apply breaking changes** within root scope: from the migration guide, identify code-affecting changes (renamed APIs, removed exports, config schema changes). Grep `app/`, `test/`, and root config files for affected patterns. Edit only files inside root scope.
5. **Verify root `package.json` moved**: read root `package.json` and confirm every group member you bumped now shows the new version. If `pnpm add` did not change root's spec (e.g. the dep is declared in a sibling project's `package.json` and not actually consumed by root code), revert the install and report the package as **skipped — not a root dep**. The skill does not resolve cross-project declarations; the maintainer must clean up manually. If the dep is in root `package.json` but has zero call sites in root scope, that's a phantom declaration: bump it anyway so the version stays current, and add a one-line note `phantom: no call sites in root` to the breaking-changes report so the maintainer can investigate.
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

Build the report **only** from the agent reports returned to you. Do not add rows from your own memory of the run.

**What goes in each section:**

- **Updated packages** — every package the Haiku agent or a Wave B agent reports as `updated`. Nothing else.
- **Breaking changes applied** — only what Wave B agents report editing in the codebase. Empty if no Wave B group ran.
- **Overrides audited** — only what the Phase 0 / Phase 6 audit reports. If `pnpm.overrides` was empty, write "None" and move on.
- **Skipped packages** — *only* packages that were attempted and reverted mid-run (peer-dep conflict, quality-gate failure, manual revert by an agent). **Never** include packages filtered out before installation by a policy rule (e.g. the Phase 1 ESLint 9.x cap). Those are silent by design — surfacing them is noise that adopters see every run. If nothing was actually skipped during the run, write "None" or omit the table.
- **Quality gate** — the gate result reported by the agents, verbatim.

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
- Removed: <key> — <reason>
- Retained: <key> — <reason>

### Skipped packages
| Package | Reason |
| --- | --- |

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
2. Do not open a PR — the user owns the branch context.

In both cases, print the resulting PR URL (if created) or confirm the push completed.
