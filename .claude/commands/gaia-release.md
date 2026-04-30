---
name: gaia-release
description: Cut a new GAIA release — bump version, graduate CHANGELOG, regenerate manifest, commit, tag, push. Maintainer-only.
---

Cut a new GAIA release. Verifies the tree is clean, bumps the version, graduates `## [Unreleased]` in `CHANGELOG.md`, scrubs the adopter-facing wiki files, regenerates `.gaia/manifest.json`, commits, tags, and pushes. This command is **maintainer-only** — it is stripped from distributed tarballs by `.gaia/release-exclude` so adopters never see it.

Unlike `/gaia-init`, this command does **not** self-delete. It runs every release.

## Step 1: Verify clean tree and release branch

- Current branch must be `main` (or an explicit release branch). If not, stop and report.
- `git status` must show a clean working tree. If there are uncommitted changes, stop and report.
- Working directory is the repo root.

```bash
git -C . rev-parse --abbrev-ref HEAD
git -C . status --porcelain
```

## Step 2: Ask the user which bump

Use `AskUserQuestion`:

- **Question**: "Which version bump?"
- **Options**: `patch` (bugfixes) / `minor` (new features, backwards-compatible) / `major` (breaking). Offer "Other" implicitly for an explicit version override.

Compute the new version from `.gaia/VERSION` + the bump. Persist it as `NEW_VERSION` for the rest of the flow.

## Step 3: Run the quality gate

Run the quality gate per `wiki/decisions/Quality Gate.md`. It must pass before continuing. If anything fails, stop and report — the maintainer fixes, recommits, then re-runs `/gaia-release`.

## Step 4: Bump version files

- Update `package.json` `"version"` to `NEW_VERSION`.
- Update `.gaia/VERSION` to `NEW_VERSION` (single line).

## Step 5: Graduate CHANGELOG

In `CHANGELOG.md`:

1. Find the `## [Unreleased]` heading.
2. If the section below it is empty (no Added/Changed/Fixed bullets), stop and ask the maintainer to write release notes first.
3. Replace `## [Unreleased]` with `## [NEW_VERSION] — YYYY-MM-DD` (today's ISO date).
4. Insert a fresh `## [Unreleased]` section (empty) above the newly-dated section.
5. Update the comparison link footer at the bottom of the file — add a line like `[NEW_VERSION]: https://github.com/gaia-react/gaia/releases/tag/vNEW_VERSION` and update the `[Unreleased]` link to compare from the new tag.

## Step 6: Scrub `wiki/hot.md`

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

## Step 7: Scrub `wiki/log.md`

Overwrite `wiki/log.md` entirely with:

```md
# Log

## [v<NEW_VERSION>] <TODAY_ISO> | Released

See CHANGELOG.md for details.
```

(The full development history remains in `git log`; adopters do not need it in the wiki.)

## Step 8: Regenerate `.gaia/manifest.json`

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

## Step 9: Commit

Stage everything changed (package.json, .gaia/VERSION, .gaia/manifest.json, CHANGELOG.md, wiki/hot.md, wiki/log.md) and commit:

```bash
git -C . add package.json .gaia/VERSION .gaia/manifest.json CHANGELOG.md wiki/hot.md wiki/log.md
git -C . commit -m "chore(release): v<NEW_VERSION>"
```

If a pre-commit hook fails, stop and report — fix the issue and create a **new** commit; do not `--amend`.

## Step 10: Tag

```bash
git -C . tag -a "v<NEW_VERSION>" -m "Release v<NEW_VERSION>"
```

Use `-s` instead of `-a` if the maintainer has gpg/ssh signing configured.

## Step 11: Confirm and push

**Ask the maintainer explicitly** before pushing. Show exactly what will be pushed:

```
About to push:
  commit: chore(release): v<NEW_VERSION>
  tag:    v<NEW_VERSION>
  to:     origin/main

Proceed? (y/n)
```

On `y`:

```bash
git -C . push origin main
git -C . push origin "v<NEW_VERSION>"
```

The tag push triggers `.github/workflows/release.yml`, which builds the scrubbed tarball and creates the GitHub Release.

## Step 12: Report

Print:

- Tag name and short SHA of the release commit.
- Expected GitHub Release URL: `https://github.com/gaia-react/gaia/releases/tag/v<NEW_VERSION>` — workflow takes ~1 minute.
- Reminder: if publishing `create-gaia` as well, bump its pinned default version to `v<NEW_VERSION>` and publish.
