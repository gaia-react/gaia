---
name: update-gaia
description: Pull the latest GAIA release into this project without clobbering customizations. Three-way merge per file using .gaia/manifest.json classes. Trigger when the user clicks the statusline `Run /update-gaia` indicator or asks "update GAIA", "pull the latest GAIA", "apply the new GAIA release".
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

### Step 7: Three-way merge

Run:

```bash
gaia update merge --baseline "$BASELINE_DIR" --latest "$LATEST_DIR" --manifest "$LATEST_MANIFEST" --json
```

Parse the JSON output. Shape (`UpdateMergeReport`):

```ts
{
  overwrite: string[];   // upstream-owned files written into the working tree
  skip: string[];        // user-owned or no-drift; left alone
  merge: string[];       // clean three-way merges written into the working tree
  add: string[];         // new files copied from latest
  delete: string[];      // upstream-deleted files; the CLI does NOT remove them
  conflicts: Array<{
    path: string;
    class: 'owned' | 'shared' | 'upstream';
    patch_path: string;  // .gaia-merge/<path>.patch
  }>;
}
```

For each entry:

- `overwrite[]`, `skip[]`, `merge[]`, `add[]`: **report counts only — no per-file narrative**. Do not read bytes; the CLI already wrote the correct file.
- `delete[]`: **ASK the user before removing** each path. The CLI surfaces these but never auto-deletes.
- `conflicts[]`: read the patch under `.gaia-merge/<path>.patch` and walk the user through the decision per file.

Do **not** read bytes for any file the CLI did not surface as a conflict or deletion.

The CLI's decision table is the canonical implementation of the rules originally documented here; if you need to inspect them, see `gaia/.gaia/cli/src/update/merge.ts`.

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

Then bust the update-check cache so the SessionStart prompt reflects the post-update state on the next session:

```bash
rm -f .gaia/cache/update-check.json
```

The next SessionStart hook fires the background refresher; the session after that sees no GAIA update available.

### Step 10: Next steps for the user

Tell the user:

1. Review any conflict patches in `.gaia-merge/` and reconcile manually. Delete the patch file once resolved.
2. Run the quality gate per `wiki/decisions/Quality Gate.md` to verify the updated code still passes.
3. Inspect the diff (`git diff`) before committing.
4. When satisfied, commit with `chore: update GAIA to $LATEST_TAG`.

Do **not** auto-commit on behalf of the user — they need to review the changes first.
