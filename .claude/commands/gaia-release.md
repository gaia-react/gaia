---
name: gaia-release
description: Cut a new GAIA release, bump version, graduate CHANGELOG, regenerate manifest, open release PR, then tag on merge. Maintainer-only.
---

Cut a new GAIA release. Thin orchestrator over the `.gaia/cli/gaia-maintainer release` CLI namespace, which owns every deterministic step (preflight checks, semver bump, CHANGELOG graduation, wiki scrub, manifest regen, commit + tag dance). This command sequences the CLI subcommands and surfaces user-facing prompts where human judgment is required.

This command is **maintainer-only**, both this slash command and the `gaia-maintainer` binary are stripped from distributed tarballs by `.gaia/release-exclude` so adopters never see them. The adopter `gaia` binary has no `release` namespace at all; only `gaia-maintainer` does. Unlike `/gaia-init`, this command does not self-delete; it runs every release.

> [!important] `main` is protected
> Direct pushes to `main` are blocked. The release commit lands on a `release/v<NEW_VERSION>` branch, goes through a PR, and the tag is created on the merge commit _after_ it lands on `main`. The release PR is subject to the same CI gate (`Vitest and Playwright`, `Run Chromatic`, a few minutes) and `code-review-audit` merge handshake as any other PR. `gh pr merge --merge --auto` is the normal path: base-branch protection rejects a plain `--merge`, so `--auto` is required to queue the merge until checks pass. See `wiki/concepts/PR Merge Workflow.md`.

## Required argument

Invocation: `/gaia-release patch|minor|major`. The argument is the **sole authority** for the version bump.

If the argument is missing, including when `/gaia-release` is reached as part of a larger batch of work ("ship this then release", a multi-step plan that ends in release, a chained workflow), **STOP and ask the maintainer via `AskUserQuestion`** before any preflight / branch / commit step. Do not infer the bump from commit prefixes, diff size, or the `gaia-maintainer release bump` proposal.

The conventional-commit scan over-proposes `minor` for CI/plumbing commits incorrectly tagged `feat:` that are patch-level in spirit; the maintainer is the only reliable source for semver intent. Never proceed without an explicit `patch|minor|major` from the maintainer.

## Workflow

The CLI surface is the source of truth. The classification rules for `.gaia/manifest.json` live in code (`.gaia/cli/src/release/manifest.ts`); the on-disk manifest is the single source of truth for `/update-gaia` consumers.

### 1. Preflight

```bash
.gaia/cli/gaia-maintainer release preflight
```

Verifies: on `main`, clean working tree, and `wiki/.state.json` is current. The wiki check reads `gaia wiki state --json`: a reachable state passes on `commits_ahead === 0`; an orphaned state (`reachable:false`, the normal post-squash-merge condition, where `commits_ahead` is hardcoded `0`) is re-evaluated over `suggested_base..HEAD` so an un-evaluated window isn't read as a silent zero. Either way, drift that is only wiki-sync squash artifacts passes; substantive drift exits non-zero with an explanation. STOP and report; the maintainer fixes (commit, push, run `/gaia-wiki sync`) and re-runs `/gaia-release`.

### 2. Apply the bump

Use the maintainer's argument from "Required argument" as `<BUMP>`. The CLI's `release bump` proposal is **informational only**, print it for awareness, then proceed with `<BUMP>` regardless:

```bash
.gaia/cli/gaia-maintainer release bump            # propose only, informational
```

If the proposal disagrees with `<BUMP>`, surface the disagreement once (e.g. "CLI proposed minor from `feat(ci):` commits; you specified patch, proceeding with patch") but do not re-prompt.

Apply by path:

- **`<BUMP>` ≥ proposal, not major:** `.gaia/cli/gaia-maintainer release bump --auto`, writes `package.json` + `.gaia/VERSION`.
- **`<BUMP>` < proposal** (e.g. `patch` override of a `minor` proposal): `--auto` would write the larger version. Compute NEW_VERSION = current with the requested bump applied, then write `package.json` + `.gaia/VERSION` directly. Preserve `package.json` formatting (2-space indent, trailing newline), use `node -e "const fs=require('fs');const p=require('./package.json');p.version='<NEW>';fs.writeFileSync('package.json',JSON.stringify(p,null,2)+'\n');"` and `printf '<NEW>\n' > .gaia/VERSION`.
- **`<BUMP>` = major:** `--auto` refuses (exit 1). Compute NEW_VERSION = `v<CURRENT_MAJOR+1>.0.0` and write `package.json` + `.gaia/VERSION` directly per the form above.

### 3. Quality gate

Run the quality gate per `wiki/decisions/Quality Gate.md`. Stop on failure, fix, recommit, re-run from Step 1.

### 4. Switch to the release branch

```bash
git checkout -b "release/v<NEW_VERSION>"
```

If the branch already exists (a previous attempt aborted), STOP and ask the maintainer whether to delete it and retry, or resume from the next pending step.

### 5. Graduate the CHANGELOG

```bash
.gaia/cli/gaia-maintainer release changelog --draft   # render to stdout for human review
```

Present the draft to the maintainer. On approval (or "looks good"), apply:

```bash
.gaia/cli/gaia-maintainer release changelog            # graduate Unreleased → vX.Y.Z
```

The graduation is idempotent, re-running with the same version is a no-op.

### 6. Scrub adopter-facing wiki state

```bash
.gaia/cli/gaia-maintainer release scrub-wiki
```

Overwrites `wiki/hot.md` and `wiki/log.md` with release-clean content (full frontmatter required by `/gaia-wiki lint`).

### 7. Regenerate the manifest

```bash
.gaia/cli/gaia-maintainer release manifest
```

Writes `.gaia/manifest.json`, sorted alphabetically. Walks `git ls-files`, subtracts `.gaia/release-exclude` patterns and adopter-owned sentinels, classifies the remainder as `owned` / `shared` / `wiki-owned`. Adopters use this manifest in `/update-gaia` to decide which files to overwrite, three-way merge, or leave alone.

### 7b. Rebuild the bundled CLIs

```bash
pnpm --filter @gaia-react/cli bundle
```

Rebuilds both `.gaia/cli/gaia` (adopter binary) and `.gaia/cli/gaia-maintainer` (maintainer binary, excluded from the tarball). Skip only when no `.gaia/cli/src/` files changed since the last release; when in doubt, rebuild, the script is fast and idempotent. The release tarball ships the committed `gaia` binary as-is, so a stale bundle ships a stale CLI.

### 8. Commit on the release branch

```bash
.gaia/cli/gaia-maintainer release commit-and-tag --commit
```

Stages `package.json`, `.gaia/VERSION`, `.gaia/manifest.json`, `CHANGELOG.md`, `wiki/hot.md`, `wiki/log.md` (and `wiki/.state.json` after the amend). The maintainer adds `.gaia/cli/gaia` and `.gaia/cli/gaia-maintainer` manually if Step 7b rebuilt them. Commits as `chore(release): vX.Y.Z`, captures the new SHA, updates `wiki/.state.json` to point at it, then amends the commit so the tree contains a self-referential state file. Adopters who scaffold via `create-gaia` get a state file that says "wiki is in sync at this release."

If the pre-commit hook fails, STOP and report, fix the issue and create a **new** commit; do not `--amend`.

### 9. Push the release branch and open the PR

```bash
git push -u origin "release/v<NEW_VERSION>"
gh pr create --base main --head "release/v<NEW_VERSION>" \
  --title "chore: release v<NEW_VERSION>" \
  --body "<release summary, link CHANGELOG entry, list highlights>"
```

### 10. Code-review-audit + marker handshake

The release PR is **not** exempt from the merge gate, `.claude/hooks/pr-merge-audit-check.sh` denies `gh pr merge` until a `code-review-audit` marker exists for the release commit's HEAD SHA. Run the four-step protocol in `wiki/concepts/PR Merge Workflow.md`: spawn `code-review-audit` on the branch, fix every Critical and Important finding, push (HEAD moves), re-spawn until the agent writes `.gaia/local/audit/<HEAD-sha>.ok`. Knip / react-doctor advisories never block the marker.

### 11. Merge the PR

```bash
gh pr merge <N> --merge --auto --delete-branch
# --auto is mandatory: base-branch protection rejects a plain --merge, and the
# Vitest/Playwright + Chromatic checks take a few minutes. --auto queues the
# merge; GitHub completes it once checks pass.
for i in $(seq 1 20); do
  state=$(gh pr view <N> --json state -q .state)
  [ "$state" = "MERGED" ] && break
  sleep 30
done
[ "$state" = "MERGED" ] || { echo "release PR did not merge, investigate before tagging"; exit 1; }
```

Do not run any local cleanup or tagging until the poll confirms `MERGED`. If it times out, inspect `gh pr view <N>` for a failing check or a stuck merge queue. This mirrors the safe pattern in `wiki/concepts/PR Merge Workflow.md`, with `--merge` instead of `--squash`.

### 12. Tag the merge commit

```bash
git checkout main
git pull --ff-only origin main
git log -1 --oneline    # verify this is the merge commit
.gaia/cli/gaia-maintainer release commit-and-tag --tag
```

Push the tag, which kicks the GitHub Release workflow (`release.yml`) to build the scrubbed tarball.

### 13. Lockstep `create-gaia`

`create-gaia` (the `npx create-gaia` scaffolder) must stay in **version lockstep** with the GAIA template: its `package.json` `version` and its offline `FALLBACK_VERSION` (`bin/index.js`) both track the release just cut. Its `publish.yml` triggers on a `v*.*.*` tag and refuses to publish unless the tag equals `package.json` version.

It lives in a sibling checkout (`../create-gaia` relative to the GAIA repo root). If the sibling is absent on this machine, STOP and report, do not silently skip; lockstep is mandatory and a maintainer with the checkout must complete it.

```bash
CG="$(git rev-parse --show-toplevel)/../create-gaia"
[ -d "$CG/.git" ] || { echo "create-gaia checkout not found at $CG, lockstep cannot complete here"; exit 1; }
CG="$(git -C "$CG" rev-parse --show-toplevel)"   # canonical absolute path
echo "create-gaia resolved to: $CG"              # ← note this literal path; inline it (NOT $CG) into the push commands below
git -C "$CG" fetch origin --quiet && git -C "$CG" checkout main --quiet && git -C "$CG" pull --ff-only origin main --quiet
```

Set both version sites to `<NEW_VERSION>` (no `v` in `package.json`, `v`-prefixed in `FALLBACK_VERSION`):

- `$CG/package.json` → `"version": "<NEW_VERSION>"`
- `$CG/bin/index.js` → `const FALLBACK_VERSION = 'v<NEW_VERSION>';`

Commit on a branch, open + merge a PR, then tag. The PR-merge and main-push guards are repo-scoped (`.claude/hooks/lib/repo-scope.sh`), but the two surfaces resolve the sibling differently. `gh pr merge -R gaia-react/create-gaia` is recognized as foreign by repo-**name** (basename) comparison, so this repo's audit gate does **not** fire, no manual-UI detour needed. Raw-git operations (`git -C <path>`, `cd <path> &&`) are recognized as foreign only by resolving the **filesystem path** from the raw command string: `repo-scope.sh` reads `tool_input.command` verbatim and cannot expand shell variables, so a `$CG` form fails to resolve, the guard falls back to enforcing home-repo main-protection, and a legitimate sibling push is denied. Every sibling `git -C … push` below therefore inlines the **literal absolute path** the discovery step printed, never `$CG`. `create-gaia` has no audit infrastructure or branch protection of its own; a plain `--merge` (not `--auto`) is correct there.

> [!important] Sibling-repo push protocol
> `repo-scope.sh` classifies a raw-git command as foreign only when it can resolve a concrete target path from the **raw command string**. Two things defeat that, and both make the guard fail closed and deny a legitimate sibling push:
>
> 1. **Variables don't expand.** The hook reads `tool_input.command` verbatim. `git -C "$CG" push …` resolves the target to the literal string `$CG`, the path lookup fails, and the guard enforces home-repo policy. **Inline the literal absolute path** the discovery step printed (e.g. `git -C /abs/path/to/create-gaia push …`), never `$CG`.
> 2. **One `-C` per push invocation.** The guard uses a single-capture regex and fails closed when it sees more than one `-C` in a single command string (git's last-wins semantics defeat a single capture). Each push (branch push **and** tag push) runs in **its own Bash tool invocation**, one `-C`, literal path.
>
> Non-push `-C` chains (add, commit, fetch, checkout, pull, tag without push) keep the `$CG`/`$WEB` variable and combine freely, only pushes (and force-pushes) need the literal-path, one-`-C` treatment.

```bash
git -C "$CG" checkout -b "release/v<NEW_VERSION>"
# (edit package.json + bin/index.js as above)
node --check "$CG/bin/index.js"   # smoke: no syntax error
git -C "$CG" add package.json bin/index.js
git -C "$CG" commit -m "chore: release v<NEW_VERSION>"
```

Branch push, own Bash invocation, **literal path inlined** (substitute the path printed by the discovery step for the placeholder; do not pass `$CG`):

```bash
git -C /abs/path/to/create-gaia push -u origin "release/v<NEW_VERSION>"
```

```bash
gh pr create -R gaia-react/create-gaia --base main --head "release/v<NEW_VERSION>" \
  --title "chore: release v<NEW_VERSION>" --body "Lockstep with GAIA v<NEW_VERSION>."
gh pr merge -R gaia-react/create-gaia <N> --merge --delete-branch
for i in $(seq 1 10); do
  st=$(gh pr view -R gaia-react/create-gaia <N> --json state -q .state)
  [ "$st" = "MERGED" ] && break; sleep 15
done
[ "$st" = "MERGED" ] || { echo "create-gaia PR did not merge, investigate before tagging"; exit 1; }
git -C "$CG" fetch origin --quiet && git -C "$CG" checkout main --quiet && git -C "$CG" pull --ff-only origin main --quiet
git -C "$CG" tag "v<NEW_VERSION>"
```

Tag push, own Bash invocation, **literal path inlined** (same substitution as the branch push; not `$CG`):

```bash
git -C /abs/path/to/create-gaia push origin "v<NEW_VERSION>"
```

The tag push triggers `create-gaia`'s `publish.yml` (npm publish with `--provenance`). Confirm it before considering the release complete:

```bash
gh run list -R gaia-react/create-gaia --workflow=publish.yml --limit 1
npm view create-gaia@<NEW_VERSION> version    # registry CDN may lag a minute
```

### 14. Lockstep website

The marketing/docs site (`../website` relative to this repo) embeds three version references plus a public changelog entry that must match the release just cut. Update all of them before considering the release complete.

```bash
WEB="$(git rev-parse --show-toplevel)/../website"
[ -d "$WEB" ] || { echo "website checkout not found at $WEB, lockstep cannot complete here"; exit 1; }
WEB="$(git -C "$WEB" rev-parse --show-toplevel)"   # canonical absolute path
echo "website resolved to: $WEB"                   # ← note this literal path; inline it (NOT $WEB) into the push below
```

**GetStarted page**, update the `GAIA_VERSION` constant:

- `$WEB/src/pages/get-started/sections/GetStarted.tsx` → `const GAIA_VERSION = '<NEW_VERSION>';`

**Fitness page**, one string contains two version slots: `"GAIA v<installed> installed; v<available> available. Run /update-gaia to upgrade."`:

- **available**: always set to `<NEW_VERSION>`.
- **installed**: represents the `<major>.<minor>.0` baseline for the current minor series, but only advances to a new minor once that minor has at least one patch release:
  - If `patch(<NEW_VERSION>) > 0`: set installed to `<major>.<minor>.0` of `<NEW_VERSION>`.
  - If `patch(<NEW_VERSION>) === 0`: leave installed unchanged, the new minor has no patches yet; the previous minor's `.0` stays displayed.

Example: current is `installed=1.2.0, available=1.2.2`. On `1.3.0` → `installed=1.2.0, available=1.3.0`. On `1.3.1` → `installed=1.3.0, available=1.3.1`.

- `$WEB/src/pages/features/sections/Fitness.tsx` → `remediation: 'GAIA v<installed> installed; v<NEW_VERSION> available. Run /update-gaia to upgrade.'`

**Structured data (JSON-LD)**, the `SoftwareApplication` schema in the site's root `index.html` carries a `softwareVersion` field. Always set it to `<NEW_VERSION>` (the latest released version; no `v` prefix, matching the existing string form):

- `$WEB/index.html` → `"softwareVersion": "<NEW_VERSION>",`

**Public changelog page (release notes).** The three edits above are version strings; the human-readable "what's new" entry on the site's changelog page is a separate artifact owned by the `release-notes` skill. Generate it for the version just cut:

- Invoke the `release-notes` skill with `<NEW_VERSION>` (no leading `v`). It reads the graduated `## [<NEW_VERSION>]` block from `CHANGELOG.md`, translates it to adopter-facing notes, writes `$WEB/src/pages/changelog/releases/<NEW_VERSION>.ts` (the page auto-discovers the file via `import.meta.glob`; there is no index to update), and prints an editorial-decisions report.
- The report is a human gate: review the **Dropped** and **Consolidated** lists and resolve every **Needs a human ruling** item before accepting, then adjust the file per the maintainer's rulings.
- The skill only reads `CHANGELOG.md`; never edit the changelog here.

Stage the generated `<NEW_VERSION>.ts` alongside the three version edits so all four land in one website commit.

Commit and push directly to `main` in the website repo (no branch protection on `website`). Apply the sibling-repo push protocol from Step 13: the `add`/`commit` chain keeps `$WEB` and combines freely, but the `git push` runs in its **own Bash tool invocation** with the **literal path inlined**. A `git -C "$WEB" push origin main` resolves the target to the literal string `$WEB`, fails closed, and is denied as a home-repo push to `main`.

```bash
git -C "$WEB" add src/pages/get-started/sections/GetStarted.tsx \
               src/pages/features/sections/Fitness.tsx \
               index.html \
               src/pages/changelog/releases/<NEW_VERSION>.ts
git -C "$WEB" commit -m "chore: lockstep GAIA v<NEW_VERSION>"
```

Push, own Bash invocation, **literal path inlined** (substitute the path printed by the discovery step for the placeholder; not `$WEB`):

```bash
git -C /abs/path/to/website push origin main
```

**GitHub release body (adopter notes).** Step 12's tag fired `release.yml`, which created the GitHub release with the raw `## [<NEW_VERSION>]` CHANGELOG block as a fallback body. That block is contributor-facing (terse, internal, PR-numbered, and can carry duplicated sub-sections); overwrite it with the same adopter notes just generated. `render-release-md.mjs` derives markdown from the committed `<NEW_VERSION>.ts`, so the GitHub release and the website changelog never drift:

```bash
node "$WEB/scripts/render-release-md.mjs" <NEW_VERSION> > "/tmp/gh-notes-v<NEW_VERSION>.md"
gh release edit "v<NEW_VERSION>" -R gaia-react/gaia --notes-file "/tmp/gh-notes-v<NEW_VERSION>.md"
```

`gh release edit` is neither a push nor a `gh pr merge`, so the repo-scope and audit hooks do not apply; no literal-path treatment is needed here.

### 15. Lockstep docs

The documentation site (`../docs` relative to this repo, docs.gaiareact.com) shows the current GAIA version in its sidebar colophon. Update it to match the release just cut.

```bash
DOCS="$(git rev-parse --show-toplevel)/../docs"
[ -d "$DOCS/.git" ] || { echo "docs checkout not found at $DOCS, lockstep cannot complete here"; exit 1; }
DOCS="$(git -C "$DOCS" rev-parse --show-toplevel)"   # canonical absolute path
echo "docs resolved to: $DOCS"                       # ← note this literal path; inline it (NOT $DOCS) into the push below
```

- `$DOCS/src/version.ts` → `export const GAIA_VERSION = '<NEW_VERSION>';` (imported by `src/overrides/PageSidebar.astro`'s colophon)

Commit and push directly to `main` in the docs repo (mirror Step 14's website push; if docs enforces branch protection, route through a PR as in Step 11). Apply the sibling-repo push protocol from Step 13: the `add`/`commit` chain keeps `$DOCS` and combines freely, but the `git push` runs in its **own Bash tool invocation** with the **literal path inlined**.

```bash
git -C "$DOCS" add src/version.ts
git -C "$DOCS" commit -m "chore: lockstep GAIA v<NEW_VERSION>"
```

Push, own Bash invocation, **literal path inlined** (substitute the path printed by the discovery step for the placeholder; not `$DOCS`):

```bash
git -C /abs/path/to/docs push origin main
```

## Recovery: I tagged on the wrong commit

```bash
git tag -d "v<NEW_VERSION>"           # delete locally
git push origin :"v<NEW_VERSION>"     # only if already pushed
.gaia/cli/gaia-maintainer release commit-and-tag --tag      # re-tag from the actual merge commit
```
