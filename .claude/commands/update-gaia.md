---
name: update-gaia
description: Pull the latest GAIA release into this project without clobbering customizations. Three-way merge per file using .gaia/manifest.json classes.
---

Pull the latest GAIA release into this project without clobbering customizations. Does a three-way comparison per file (adopter / baseline / latest) and respects explicit classes in `.gaia/manifest.json`:

- **`owned`** — GAIA controls fully. Overwrites silently if unchanged from baseline; prompts if drifted.
- **`shared`** — GAIA seeds, you customize. Emits a `.gaia-merge/` patch for manual resolution on drift.
- **`wiki-owned`** — GAIA-seeded concept/decision/module wiki pages. Same drift handling as `shared`.
- **adopter-owned (implicit)** — anything not in the manifest, plus sentinels like `wiki/hot.md`, `wiki/log.md`, `CHANGELOG.md`, `.gaia/VERSION`, `.gaia/manifest.json`. Never touched.

Backups land in `.gaia-backup/<timestamp>/`. Conflict patches land in `.gaia-merge/`.

## Pre-flight: Branch check

```bash
git branch --show-current
```

If the current branch is `main` or `master`, create and switch to a new branch:

```bash
git checkout -b chore/update-gaia-$(date +%Y-%m-%d-%H-%M)
```

Otherwise proceed on the current branch.

## Step 1: Read baseline version

```bash
cat .gaia/VERSION 2>/dev/null || echo MISSING
```

If the file is missing, stop and tell the user:

> "No `.gaia/VERSION` found — this project was not scaffolded from GAIA, or the marker was deleted. Run `/gaia-init` on a fresh `create-gaia` scaffold first."

Persist the trimmed version as `BASELINE` (e.g., `1.0.0`).

## Step 2: Resolve latest release

```bash
gh release list --repo gaia-react/gaia --limit 1 --json tagName --jq '.[0].tagName'
```

Persist as `LATEST_TAG` (e.g., `v1.0.1`) and `LATEST` (strip leading `v`).

If `gh` is unavailable, fall back to:

```bash
curl -fsSL https://api.github.com/repos/gaia-react/gaia/releases/latest | jq -r .tag_name
```

If both fail, stop and ask the user to supply the target version explicitly.

## Step 3: Compare versions

- If `LATEST == BASELINE` → print "You are up to date on GAIA v$BASELINE." and exit.
- If `semver(LATEST) < semver(BASELINE)` → print a warning that the installed version is ahead of the latest release and exit. Never downgrade.

## Step 4: Show the release notes and confirm

Fetch the release body for `LATEST_TAG`:

```bash
gh release view "$LATEST_TAG" --repo gaia-react/gaia --json body --jq .body
```

Print the notes to the user. Then use `AskUserQuestion`:

- **Question**: "Update GAIA from v$BASELINE to $LATEST_TAG?"
- **Options**: `Proceed` / `Abort`.

On `Abort`, exit cleanly with no filesystem changes.

## Model selection

After the user confirms, determine the model for the execution agent:

- Compare `LATEST` major vs `BASELINE` major (leading integer).
- **Major bump** → spawn an **Opus agent** (`model: "opus"`).
- **Minor or patch bump** → spawn a **Sonnet agent** (`model: "sonnet"`).

Spawn the agent for Steps 5–10, passing `BASELINE`, `LATEST`, and `LATEST_TAG` as context.

---

## Steps 5–10 (execution agent)

### Step 5: Fetch baseline and latest tarballs

Cache under `.gaia/cache/` (gitignored) so repeated runs don't redownload:

```bash
mkdir -p .gaia/cache
for tag in "v$BASELINE" "$LATEST_TAG"; do
  dir=".gaia/cache/$tag"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
    gh release download "$tag" \
      --repo gaia-react/gaia \
      --pattern "gaia-${tag}.tar.gz" \
      --dir "$dir"
    tar -xzf "$dir/gaia-${tag}.tar.gz" -C "$dir" --strip-components=1
  fi
done
```

`BASELINE_DIR=".gaia/cache/v$BASELINE"`, `LATEST_DIR=".gaia/cache/$LATEST_TAG"`.

If the baseline tarball is unavailable (older release, pre-manifest), stop and explain — the adopter can manually cherry-pick changes by comparing their project to the `$LATEST_DIR`.

### Step 6: Load the latest manifest

```bash
LATEST_MANIFEST="$LATEST_DIR/.gaia/manifest.json"
```

Iterate keys of `.files`. For each `<path>, <class>` entry, apply the decision table below. Track counts per outcome for the summary.

### Step 7: Per-file decision table

For every file `P` in the latest manifest:

| Condition                                                                                        | Action                                                                                                                                                                                                                                      |
| ------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `adopter[P]` does not exist AND `baseline[P]` does not exist                                     | **New file**: copy `latest[P]` into the project (default yes; prompt if the user opted into step-through).                                                                                                                                  |
| `adopter[P]` does not exist AND `baseline[P]` exists                                             | Adopter deleted this file. **Respect**: skip.                                                                                                                                                                                               |
| `adopter[P] == baseline[P]`                                                                      | No drift. **Overwrite** with `latest[P]` silently (applies to all classes).                                                                                                                                                                 |
| `adopter[P] != baseline[P]` AND `latest[P] == baseline[P]`                                       | Drift only from adopter. **Skip** — upstream made no change.                                                                                                                                                                                |
| `adopter[P] != baseline[P]` AND `latest[P] != baseline[P]` AND class is `owned`                  | Show unified diff (`latest[P]` vs `adopter[P]`). Prompt: `skip` (default) / `overwrite` (copy latest, back up adopter to `.gaia-backup/`) / `backup-and-overwrite` (same as overwrite but retains adopter's content as `<path>.local` too). |
| `adopter[P] != baseline[P]` AND `latest[P] != baseline[P]` AND class is `shared` or `wiki-owned` | Do **not** auto-modify. Write `.gaia-merge/<path>.patch` containing a three-way diff (baseline / latest / adopter) so the user can resolve manually. Record the conflict in the summary.                                                    |

Files present in `baseline` but **absent** in `latest` (upstream deleted/renamed):

| Condition                   | Action                                                                           |
| --------------------------- | -------------------------------------------------------------------------------- |
| `adopter[P]` does not exist | Already gone. Skip.                                                              |
| `adopter[P] == baseline[P]` | Upstream removed it; your copy is pristine. Prompt: `delete` (default) / `keep`. |
| `adopter[P] != baseline[P]` | You customized it; upstream removed it. Prompt: `keep` (default) / `delete`.     |

File equality comparison: byte-for-byte (`cmp -s`). No line-ending normalization — the template is LF throughout.

Print per-file progress as you go:

```
[skip]      .claude/settings.json                 (shared, no drift)
[overwrite] .claude/skills/tdd/SKILL.md           (owned, pristine)
[merge]     wiki/decisions/Quality Gate.md        (wiki-owned, conflict → .gaia-merge/)
[add]       wiki/concepts/New Pattern.md          (new)
[keep]      app/utils/legacy.ts                   (upstream deleted, you customized)
```

### Step 8: Bump `.gaia/VERSION`

**Only** after the full walk completes without errors:

```bash
echo "$LATEST" > .gaia/VERSION
```

If the walk was aborted mid-way (user cancels, disk error), leave `.gaia/VERSION` at `BASELINE` so a re-run resumes cleanly. Any files already overwritten are safe — their new state is recorded via `.gaia-backup/`.

Also copy `.gaia/manifest.json` from `$LATEST_DIR/.gaia/manifest.json` into the project so the next `/update-gaia` has the right baseline.

### Step 9: Summary

Print a table:

```
GAIA update: v$BASELINE → $LATEST_TAG

  Overwritten:  <n>
  Added:        <n>
  Skipped:      <n>
  Conflicts:    <n>  (see .gaia-merge/)
  Deleted:      <n>
  Backed up:    <n>  (see .gaia-backup/<timestamp>/)
```

Then bust the statusline cache so the "Run /update-gaia (GAIA $LATEST available)" hint doesn't linger from the pre-update snapshot:

```bash
rm -f .gaia/cache/statusline-update-check.json
```

The next statusline render fires the background refresher; the render after that reflects the post-update state.

### Step 10: Next steps for the user

Tell the user:

1. Review any conflict patches in `.gaia-merge/` and reconcile manually. Delete the patch file once resolved.
2. Run `/audit-code` to verify the updated code still passes the quality gate.
3. Inspect the diff (`git diff`) before committing.
4. When satisfied, commit with `chore: update GAIA to $LATEST_TAG`.

Do **not** auto-commit on behalf of the user — they need to review the changes first.
