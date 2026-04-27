Autonomous superpowered Dependabot. Auto-discover all outdated packages, audit overrides, apply codebase migrations for major bumps, resolve dependency conflicts, and run the quality gate. No user prompts — just execute.

## Phase 0: Override audit

For each key in `pnpm.overrides` (in `package.json`):

1. Temporarily remove that single key from `pnpm.overrides`.
2. Run `pnpm install`.
3. Run `pnpm ls 2>&1` and scan for peer-dep errors.
4. If no errors → override is obsolete. Leave it removed. Note as **removed** in final report.
5. If errors → restore that key. Note as **retained** in final report.

Operate on one key at a time. Always `pnpm install` after each toggle.

## Phase 1: Discover outdated packages

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

If nothing is outdated after this filtering, print `All packages are up to date.` and exit.

## Phase 2: Resolve companion groups

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

## Phase 3: Classify into waves

- **Wave A** — groups whose members all have minor or patch bumps only. Batched into one install.
- **Wave B** — groups containing at least one major bump. Processed individually, ordered: `react-router`, `react`, `tailwindcss`, `storybook`, `vitest`, `playwright`, `eslint`, then remaining alphabetically.

## Phase 4: Wave A (batch minor/patch)

1. Build install args. For each package: if `is_pinned` use exact target, else use `^<latest>`. Example: `pnpm add foo@1.2.3 bar@^4.5.0 ...`.
2. Run the single `pnpm add` command.
3. Run `pnpm ls 2>&1`. Scan for peer-dep errors.
4. On error: try one targeted `pnpm.overrides` fix (e.g. add a `parent>child` pin), then `pnpm install` again.
5. If still failing: revert the offending packages (`pnpm add <pkg>@<previous>`) and log them as **skipped** with the reason.
6. Run quality gate (Phase 7). If it fails, revert the entire Wave A batch.

## Phase 5: Wave B (per-group major bumps)

For each Wave B group, in the order from Phase 3:

1. **Fetch migration guide** via WebFetch using the table below. If no URL applies, scan the GitHub release notes.
2. **Install** the group:
   - `storybook` group: run `pnpm dlx storybook@latest upgrade` (Storybook's own upgrade tool migrates config alongside the version bump).
   - All others: `pnpm add <pkg1>@<latest> <pkg2>@<latest> ...` for every group member present in `package.json`.
3. **Conflict check**: `pnpm ls 2>&1`. On peer-dep error, attempt one `pnpm.overrides` fix. If still failing, revert the group and skip with reason.
4. **Apply breaking changes**: from the migration guide, identify code-affecting changes (renamed APIs, removed exports, config schema changes). `grep` the codebase for affected patterns and edit the matching files.
5. **Quality gate** (Phase 7). On failure, attempt fixes inferred from the migration guide. If unfixable after a reasonable attempt, revert the entire group and log as skipped.

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

## Phase 6: Post-update override audit

For every override that was **retained** in Phase 0, repeat the Phase 0 toggle test now that surrounding packages have moved. New versions may have resolved the original conflict.

## Phase 7: Quality gate

```bash
pnpm typecheck
pnpm lint
pnpm test --run
pnpm pw
pnpm build
```

Run after Wave A completes, then once per Wave B group. Stop on first failure within a wave/group and follow the revert rules above.

## Phase 8: Final report

Print this report. Do not commit.

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

After printing the report, bust the statusline cache so the "Run /update-deps (N outdated)" hint doesn't linger from the pre-update snapshot:

```bash
rm -f .gaia/cache/statusline-update-check.json
```

The next statusline render fires the background refresher; the render after that reflects the post-update state.

Stop and wait for user review.
