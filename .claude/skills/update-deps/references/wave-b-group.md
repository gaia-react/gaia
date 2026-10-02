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
3. **Conflict check**: `pnpm ls 2>&1`. On peer-dep error, attempt one `overrides:` fix in `pnpm-workspace.yaml`, then `pnpm dedupe` to apply it, a bare `pnpm install` won't re-resolve an overrides-only change. If still failing, revert the group and skip with reason.
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
   On failure, make one remediation pass: apply fixes inferred from the migration guide, then re-run the gate once. If it still fails after that single re-run, revert the entire group and log as skipped. Do not keep iterating.

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
| singleton:typescript | `https://www.typescriptlang.org/docs/handbook/release-notes/overview.html` |
| msw          | `https://mswjs.io/docs/migrations`                                         |
| vite         | `https://vite.dev/guide/migration`                                         |

Report back: updated packages, breaking changes applied, any skipped reason, quality gate results.
