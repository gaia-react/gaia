---
name: gaia-release
description: Cut a new GAIA release — bump version, graduate CHANGELOG, regenerate manifest, open release PR, then tag on merge. Maintainer-only.
---

Cut a new GAIA release. Thin orchestrator over the `.gaia/cli/gaia-maintainer release` CLI namespace, which owns every deterministic step (preflight checks, semver bump, CHANGELOG graduation, wiki scrub, manifest regen, commit + tag dance). This command sequences the CLI subcommands and surfaces user-facing prompts where human judgment is required.

This command is **maintainer-only** — both this slash command and the `gaia-maintainer` binary are stripped from distributed tarballs by `.gaia/release-exclude` so adopters never see them. The adopter `gaia` binary has no `release` namespace at all; only `gaia-maintainer` does. Unlike `/gaia-init`, this command does not self-delete; it runs every release.

> [!important] `main` is protected
> Direct pushes to `main` are blocked. The release commit lands on a `release/v<NEW_VERSION>` branch, goes through a PR, and the tag is created on the merge commit _after_ it lands on `main`. The release PR is subject to the same CI gate (`Vitest and Playwright`, `Run Chromatic` — a few minutes) and `code-review-audit` merge handshake as any other PR. `gh pr merge --merge --auto` is the normal path: base-branch protection rejects a plain `--merge`, so `--auto` is required to queue the merge until checks pass. See `wiki/concepts/PR Merge Workflow.md`.

## Workflow

The CLI surface is the source of truth. The classification rules for `.gaia/manifest.json` live in code (`.gaia/cli/src/release/manifest.ts`); the on-disk manifest is the single source of truth for `/update-gaia` consumers.

### 1. Preflight

```bash
.gaia/cli/gaia-maintainer release preflight
```

Verifies: on `main`, clean working tree, `wiki/.state.json` matches HEAD (per the `gaia wiki state --json` `commits_ahead === 0` contract). Exits non-zero with an explanation on any failure. STOP and report; the maintainer fixes (commit, push, run `/gaia wiki sync`) and re-runs `/gaia-release`.

### 2. Determine the bump

```bash
.gaia/cli/gaia-maintainer release bump            # propose only
```

Prints `vCURRENT -> vNEXT (bump)` from a conventional-commit scan since the last tag. Highest severity wins; `BREAKING CHANGE` body lines or `!:` suffixes register as major.

If the proposal is **major**, present the breaking commits and ask the maintainer to confirm. Only proceed on explicit confirmation.

If **minor** or **patch** (or major-with-confirmation), apply:

```bash
.gaia/cli/gaia-maintainer release bump --auto     # writes package.json + .gaia/VERSION
```

`--auto` refuses major bumps without explicit confirmation; if the maintainer confirmed, proceed (the CLI surfaces the refusal as exit 1 — capture the proposed version and write package.json + `.gaia/VERSION` directly, or extend the runbook with a `--allow-major` flag if it becomes routine).

### 3. Quality gate

Run the quality gate per `wiki/decisions/Quality Gate.md`. Stop on failure — fix, recommit, re-run from Step 1.

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

The graduation is idempotent — re-running with the same version is a no-op.

### 6. Scrub adopter-facing wiki state

```bash
.gaia/cli/gaia-maintainer release scrub-wiki
```

Overwrites `wiki/hot.md` and `wiki/log.md` with release-clean content (full frontmatter required by `/gaia wiki lint`).

### 7. Regenerate the manifest

```bash
.gaia/cli/gaia-maintainer release manifest
```

Writes `.gaia/manifest.json`, sorted alphabetically. Walks `git ls-files`, subtracts `.gaia/release-exclude` patterns and adopter-owned sentinels, classifies the remainder as `owned` / `shared` / `wiki-owned`. Adopters use this manifest in `/update-gaia` to decide which files to overwrite, three-way merge, or leave alone.

### 7b. Rebuild the bundled CLIs

```bash
pnpm --filter @gaia-react/cli bundle
```

Rebuilds both `.gaia/cli/gaia` (adopter binary) and `.gaia/cli/gaia-maintainer` (maintainer binary, excluded from the tarball). Skip only when no `.gaia/cli/src/` files changed since the last release; when in doubt, rebuild — the script is fast and idempotent. The release tarball ships the committed `gaia` binary as-is, so a stale bundle ships a stale CLI.

### 8. Commit on the release branch

```bash
.gaia/cli/gaia-maintainer release commit-and-tag --commit
```

Stages `package.json`, `.gaia/VERSION`, `.gaia/manifest.json`, `CHANGELOG.md`, `wiki/hot.md`, `wiki/log.md` (and `wiki/.state.json` after the amend). The maintainer adds `.gaia/cli/gaia` and `.gaia/cli/gaia-maintainer` manually if Step 7b rebuilt them. Commits as `chore(release): vX.Y.Z`, captures the new SHA, updates `wiki/.state.json` to point at it, then amends the commit so the tree contains a self-referential state file. Adopters who scaffold via `create-gaia` get a state file that says "wiki is in sync at this release."

If the pre-commit hook fails, STOP and report — fix the issue and create a **new** commit; do not `--amend`.

### 9. Push the release branch and open the PR

```bash
git push -u origin "release/v<NEW_VERSION>"
gh pr create --base main --head "release/v<NEW_VERSION>" \
  --title "chore: release v<NEW_VERSION>" \
  --body "<release summary — link CHANGELOG entry, list highlights>"
```

### 10. Code-review-audit + marker handshake

The release PR is **not** exempt from the merge gate — `.claude/hooks/pr-merge-audit-check.sh` denies `gh pr merge` until a `code-review-audit` marker exists for the release commit's HEAD SHA. Run the four-step protocol in `wiki/concepts/PR Merge Workflow.md`: spawn `code-review-audit` on the branch, fix every Critical and Important finding, push (HEAD moves), re-spawn until the agent writes `.gaia/local/audit/<HEAD-sha>.ok`. Knip / react-doctor advisories never block the marker.

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
[ "$state" = "MERGED" ] || { echo "release PR did not merge — investigate before tagging"; exit 1; }
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

## Recovery: I tagged on the wrong commit

```bash
git tag -d "v<NEW_VERSION>"           # delete locally
git push origin :"v<NEW_VERSION>"     # only if already pushed
.gaia/cli/gaia-maintainer release commit-and-tag --tag      # re-tag from the actual merge commit
```
