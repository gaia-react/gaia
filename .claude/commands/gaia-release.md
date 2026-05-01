---
name: gaia-release
description: Cut a new GAIA release — bump version, graduate CHANGELOG, regenerate manifest, open release PR, then tag on merge. Maintainer-only.
---

Cut a new GAIA release. Verifies the tree is clean, auto-determines the version bump, graduates `CHANGELOG.md` with entries auto-drafted from git history, scrubs the adopter-facing wiki files, regenerates `.gaia/manifest.json`, commits to a `release/v<NEW_VERSION>` branch, opens and merges the PR, then tags the merge commit. This command is **maintainer-only** — it is stripped from distributed tarballs by `.gaia/release-exclude` so adopters never see it.

Unlike `/gaia-init`, this command does **not** self-delete. It runs every release.

> [!important] `main` is protected
> Direct pushes to `main` are blocked. The release commit lands on a `release/v<NEW_VERSION>` branch, goes through a PR, and the tag is created on the merge commit _after_ it lands on `main`. There are no required checks on release branches, so the PR is merged immediately by the command itself — no manual merge step needed.

## Step 1: Verify clean tree, on `main`

- Current branch must be `main`. If not, stop and report (the command creates the release branch itself in Step 4).
- `git status` must show a clean working tree. If there are uncommitted changes, stop and report.
- Local `main` must be up to date with `origin/main`. If behind, `git pull --ff-only` first.
- Working directory is the repo root.

```bash
git -C . rev-parse --abbrev-ref HEAD
git -C . status --porcelain
git -C . fetch origin main
git -C . rev-list --count origin/main..main  # must be 0
git -C . rev-list --count main..origin/main  # if >0, pull --ff-only
```

## Step 2: Determine the version bump

Read `.gaia/VERSION` for the current version. Then run:

```bash
git -C . log v<CURRENT_VERSION>...HEAD --no-merges --oneline
```

Analyze each commit message using conventional-commit prefixes to classify the bump:

| Commit type                                                                      | Bump             |
| -------------------------------------------------------------------------------- | ---------------- |
| `feat:` / `feat(...):`                                                           | minor            |
| `fix:` / `docs:` / `chore:` / `refactor:` / `perf:` / `ci:` / `test:` / `style:` | patch            |
| `BREAKING CHANGE` in body, or `!` suffix (e.g. `feat!:`)                         | **major → STOP** |

Rules:

- The highest-severity commit wins (minor beats patch; major beats both).
- If **major** is indicated, stop and report the breaking commits. Ask the maintainer to confirm before proceeding. Only continue on explicit confirmation.
- If **minor** or **patch**, proceed automatically. Report: `Detected <bump> bump → v<NEW_VERSION>`.

Compute `NEW_VERSION` from the current version + bump. Persist it for the rest of the flow.

## Step 3: Run the quality gate

Run the quality gate per `wiki/decisions/Quality Gate.md`. It must pass before continuing. If anything fails, stop and report — the maintainer fixes, recommits, then re-runs `/gaia-release`.

## Step 4: Switch to the release branch

Create and switch to `release/v<NEW_VERSION>` from `main`. All subsequent edits and the release commit land here, not on `main`.

```bash
git -C . checkout -b "release/v<NEW_VERSION>"
```

If the branch already exists (e.g. a previous attempt aborted mid-flow), stop and ask the maintainer whether to delete it and retry, or resume.

## Step 5: Bump version files

- Update `package.json` `"version"` to `NEW_VERSION`.
- Update `.gaia/VERSION` to `NEW_VERSION` (single line).

## Step 6: Draft and graduate CHANGELOG

Run:

```bash
git -C . log v<CURRENT_VERSION>...HEAD --no-merges --oneline
```

Map each commit to a Keep-a-Changelog section using its conventional-commit prefix:

| Prefix                            | Section                   |
| --------------------------------- | ------------------------- |
| `feat`                            | Added                     |
| `fix`                             | Fixed                     |
| `refactor` / `perf`               | Changed                   |
| `docs`                            | Changed                   |
| `chore` / `ci` / `test` / `style` | (omit — not user-visible) |

Strip the prefix/scope from the message body; write each entry as a plain bullet. Group bullets under their section headings. Omit sections that have no entries.

Present the draft to the maintainer:

```
CHANGELOG draft for v<NEW_VERSION>:

### Added
- ...

### Fixed
- ...

Proceed, or edit before continuing?
```

On approval (or if the maintainer says "looks good"), write the entry to `CHANGELOG.md`:

1. Find the `## [Unreleased]` heading. Replace it with `## [NEW_VERSION] — YYYY-MM-DD` (today's ISO date).
2. Insert a fresh empty `## [Unreleased]` section above the newly-dated section.
3. Paste the approved draft below the dated heading.
4. Update the comparison link footer — add `[NEW_VERSION]: https://github.com/gaia-react/gaia/releases/tag/vNEW_VERSION` and update the `[Unreleased]` link to compare from the new tag.

## Step 7: Scrub `wiki/hot.md`

Overwrite `wiki/hot.md` entirely with:

```md
---
type: meta
title: Hot Cache
updated: <TODAY_ISO>
---

# Recent Context

## Last Updated

<TODAY_ISO>. Released as GAIA v<NEW_VERSION>. Fresh slate.

## Active Threads

- None.
```

## Step 8: Scrub `wiki/log.md`

Overwrite `wiki/log.md` entirely with:

```md
# Log

## [v<NEW_VERSION>] <TODAY_ISO> | Released

See CHANGELOG.md for details.
```

(The full development history remains in `git log`; adopters do not need it in the wiki.)

## Step 9: Regenerate `.gaia/manifest.json`

Walk the tree and emit a manifest mapping each GAIA-shipped file to a class. Adopter-owned files (`wiki/hot.md`, `wiki/log.md`, anything not listed) are implicit — absent from the manifest entirely.

Classification rules, in order of precedence:

1. **Excluded** (not in tarball) — any path matched by `.gaia/release-exclude`. Skip.
2. **Gitignored** — skip.
3. **Adopter-owned sentinel paths** — `wiki/hot.md`, `wiki/log.md`, `CHANGELOG.md`, `.gaia/VERSION`, `.gaia/manifest.json`. Skip (not in manifest).
4. **`shared`** — GAIA seeds, adopter customizes:
   - `.claude/settings.json`
   - `package.json`
   - `CLAUDE.md`
   - `README.md`
   - `.github/workflows/*.yml`
   - `wiki/index.md`
   - `.github/CODEOWNERS`
   - `.github/FUNDING.yml`
5. **`wiki-owned`** — GAIA-seeded wiki pages that adopters may edit:
   - `wiki/concepts/**`
   - `wiki/decisions/**`
   - `wiki/modules/**`
   - `wiki/flows/**`
   - `wiki/dependencies/**`
   - `wiki/overview.md`
   - `wiki/README.md`
6. **`owned`** — default for everything else GAIA ships: `.claude/**`, `app/**`, config files (`tsconfig*.json`, `eslint.config.js`, `vite.config.ts`, `vitest.config.ts`, `playwright.config.ts`, `postcss.config.mjs`, `.prettierrc*`, `.stylelintrc*`, `tailwind.config.*`, etc.), `public/**`, `.storybook/**`, `.playwright/**` (specs), `.husky/**`.

Emit to `.gaia/manifest.json`:

```json
{
  "version": "<NEW_VERSION>",
  "generated": "<ISO timestamp>",
  "files": {
    ".claude/settings.json": "shared",
    ".claude/skills/tdd/SKILL.md": "owned",
    "wiki/concepts/Quality Gate.md": "wiki-owned",
    "...": "..."
  }
}
```

Sort keys alphabetically for deterministic diffs.

Reference implementation (bash + jq, run from repo root):

```bash
node .gaia/scripts/generate-manifest.mjs > .gaia/manifest.json.tmp && \
  mv .gaia/manifest.json.tmp .gaia/manifest.json
```

(If `.gaia/scripts/generate-manifest.mjs` has not been authored yet, do so now — see Step 8's classification rules. The script is tiny: walk `git ls-files`, subtract `.gaia/release-exclude` matches and sentinel paths, classify each remaining path by the rules above, emit sorted JSON.)

## Step 10: Commit on the release branch

Stage everything changed (package.json, .gaia/VERSION, .gaia/manifest.json, CHANGELOG.md, wiki/hot.md, wiki/log.md) and commit:

```bash
git -C . add package.json .gaia/VERSION .gaia/manifest.json CHANGELOG.md wiki/hot.md wiki/log.md
git -C . commit -m "chore(release): v<NEW_VERSION>"
```

If a pre-commit hook fails, stop and report — fix the issue and create a **new** commit; do not `--amend`.

**Do not tag yet.** The tag must point at the merge commit on `main`, which doesn't exist until after the PR merges. Tagging the local pre-merge commit and then pushing leads to a tag that doesn't match `main`'s history.

## Step 11: Push the release branch, open the PR, and merge it

```bash
git -C . push -u origin "release/v<NEW_VERSION>"
```

Open the PR:

```bash
gh pr create --base main --head "release/v<NEW_VERSION>" \
  --title "chore: release v<NEW_VERSION>" \
  --body "<release summary — link the CHANGELOG entry, list highlights, include the quality-gate checklist>"
```

Print the PR URL. Then immediately merge it — there are no required checks on release branches, so it merges instantly:

```bash
gh pr merge --merge "release/v<NEW_VERSION>"
```

## Step 12: Pull main and push the tag

Sleep 5 seconds to let GitHub settle, then pull the merge commit and tag it:

```bash
sleep 5
git -C . checkout main
git -C . pull --ff-only origin main
git -C . log -1 --oneline  # verify this is the merge commit
git -C . tag -a "v<NEW_VERSION>" HEAD -m "Release v<NEW_VERSION>"
git -C . push origin "v<NEW_VERSION>"
```

Report: tag pushed → `https://github.com/gaia-react/gaia/releases/tag/v<NEW_VERSION>` (GitHub Release workflow takes ~1 min to build the artifact).

## Recovery: I tagged on the wrong commit

If you (or a previous attempt) tagged the local pre-merge commit instead of the merge commit:

```bash
git -C . tag -d "v<NEW_VERSION>"           # delete locally
git -C . push origin :"v<NEW_VERSION>"     # only if already pushed (otherwise skip)
```

Then re-tag from Step 13 against the actual merge commit.
