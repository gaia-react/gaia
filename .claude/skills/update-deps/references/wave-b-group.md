### Wave B group instructions

You are upgrading the `{GROUP}` dependency group from `{FROM}` to `{TO}`.

**Scope.** Operate on the **root pnpm workspace and its `frontend` package only**.

- Run every `pnpm` command from the repository root, using `-C frontend` for app dependencies. Never `cd` into subdirectories.
- For code edits and grep-style searches, scan only `frontend/app/`, `frontend/test/`, and the frontend config files (`frontend/*.config.*`, `frontend/tsconfig*.json`). Do **not** scan the entire repository, sibling directories may be independent pnpm projects with their own `package.json`/`pnpm-lock.yaml`, and they are out of scope for this skill.
- A directory is "out of scope" if it contains its own `package.json` or `pnpm-lock.yaml` and is not `frontend`. Skip those subtrees entirely.

1. **Fetch migration guide** via WebFetch using the table below. If no URL applies, scan the GitHub release notes.
2. **Install** the group, **from the repository root only**:
   - `storybook` group: run `pnpm dlx storybook@latest upgrade` (Storybook's own upgrade tool migrates config alongside the version bump).
   - All others: `pnpm -C frontend add <pkg1>@<latest> <pkg2>@<latest> ...` for every group member present in `frontend/package.json` (a member declared in the root `package.json` goes through `pnpm add -w`).
<!-- gaia:maintainer-only:start -->
   - A member carrying `"workspace": ".gaia/cli"`: `pnpm -C .gaia/cli add <pkg>@<latest>`, never `pnpm -C frontend add`.
<!-- gaia:maintainer-only:end -->
   - `msw` group: after the install, run `pnpm -C frontend msw:init` (`pnpm -C frontend exec msw init` when the project has no such script) to regenerate `frontend/public/mockServiceWorker.js`.
3. **Conflict check**: `pnpm ls 2>&1`. On peer-dep error, attempt one `overrides:` fix in `pnpm-workspace.yaml`, then `pnpm dedupe` to apply it, a bare `pnpm install` won't re-resolve an overrides-only change. If still failing, revert the group and skip with reason.
4. **Apply breaking changes** within scope: from the migration guide, identify code-affecting changes (renamed APIs, removed exports, config schema changes). Grep `frontend/app/`, `frontend/test/`, and the frontend config files for affected patterns. Edit only files inside scope.
5. **Verify the manifest moved**: read `frontend/package.json` (or the root `package.json` for a root-declared member) and confirm every group member you bumped now shows the new version. If `pnpm add` did not change the spec (e.g. the dep is declared in a sibling project's `package.json` and not actually consumed by in-scope code), revert the install and report the package as **skipped, not an in-scope dep**. The skill does not resolve cross-project declarations; the maintainer must clean up manually. If the dep is in an in-scope `package.json` but has zero call sites in scope, that's a phantom declaration: bump it anyway so the version stays current, and add a one-line note `phantom: no call sites in scope` to the breaking-changes report so the maintainer can investigate.
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

| Group                | URL                                                                        |
| -------------------- | -------------------------------------------------------------------------- |
| react-router         | `https://reactrouter.com/upgrading/v7`                                     |
| react                | `https://react.dev/blog` (find the major-version post)                     |
| tailwindcss          | `https://tailwindcss.com/docs/upgrade-guide`                               |
| storybook            | `https://storybook.js.org/docs/migration-guide`                            |
| vitest               | `https://vitest.dev/guide/migration`                                       |
| playwright           | `https://playwright.dev/docs/release-notes`                                |
| eslint               | `https://eslint.org/docs/latest/use/migrate-to-9` (or relevant X)          |
| singleton:typescript | `https://www.typescriptlang.org/docs/handbook/release-notes/overview.html` |
| msw                  | `https://mswjs.io/docs/migrations`                                         |
| vite                 | `https://vite.dev/guide/migration`                                         |

Report back: updated packages, breaking changes applied, any skipped reason, quality gate results, and, when the orchestrator dispatched this group as a security chain-head bump, whether the group landed or was reverted.
