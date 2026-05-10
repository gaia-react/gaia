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

## Pre-flight: Worktree check

This wrapper changes `.gaia/VERSION` and opens a PR — both belong on the main checkout, not a per-SPEC worktree branch. If invoked from a linked worktree, reject hard with a message that surfaces the cached version state from main so the user knows whether a GAIA update is even pending.

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
      gaia_current="$(jq -r '.gaiaCurrent // ""' "$cache_file" 2>/dev/null)"
      gaia_latest="$(jq -r '.gaiaLatest // ""' "$cache_file" 2>/dev/null)"
      gaia_has_update="$(jq -r '.gaiaHasUpdate // false' "$cache_file" 2>/dev/null)"
      if [ -n "$gaia_current" ] && [ -n "$gaia_latest" ]; then
        update_phrase="not-available"
        if [ "$gaia_has_update" = "true" ]; then update_phrase="available"; fi
        cached_line="Cached on main: GAIA $gaia_current installed; latest $gaia_latest (update $update_phrase)."
      fi
    fi
    cat <<EOF
/update-gaia must run from the main checkout, not a worktree.

Worktree:       $current_root
Main checkout:  $main_root

$cached_line

Run \`cd $main_root\` then re-invoke /update-gaia.
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

Do **not** read bytes for any file the CLI did not surface as a conflict or deletion. The decision table baked into `gaia update merge` is canonical; the JSON it emits is the contract the skill walks.

### Step 8: Bump `.gaia/VERSION`

**Only** after the full walk completes without errors:

```bash
echo "$LATEST" > .gaia/VERSION
```

If the walk was aborted mid-way (user cancels, disk error), leave `.gaia/VERSION` at `BASELINE` so a re-run resumes cleanly. Any files already overwritten are safe — their new state is recorded via `.gaia-backup/`.

Also copy `.gaia/manifest.json` from `$LATEST_DIR/.gaia/manifest.json` into the project so the next `/update-gaia` has the right baseline.

Then count open PRs whose `GAIA-Audit` trailer is stamped with the old version — these will be invalidated by the version bump and will re-run the full CI audit on their next push:

```bash
INVALIDATED_COUNT=0
if command -v gh >/dev/null 2>&1; then
  OLD_VERSION="$BASELINE"
  pr_list=$(gh pr list --state open --json number,headRefOid 2>/dev/null || true)
  if [ -n "$pr_list" ]; then
    while IFS= read -r sha; do
      [ -z "$sha" ] && continue
      msg=$(git -C "$repo_root" log -1 --format='%B' "$sha" 2>/dev/null || true)
      if echo "$msg" | grep -qE "^GAIA-Audit:[[:space:]]+${OLD_VERSION}[[:space:]]+[0-9a-f]{40}"; then
        INVALIDATED_COUNT=$((INVALIDATED_COUNT + 1))
      fi
    done < <(echo "$pr_list" | jq -r '.[].headRefOid' 2>/dev/null || true)
  fi
else
  INVALIDATED_COUNT="unknown"
fi
```

Persist `INVALIDATED_COUNT` for Step 9.

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
  Trailer invalidations: <n>  (open PRs stamped v$BASELINE will re-audit on next push)
```

If `INVALIDATED_COUNT` is `"unknown"`, emit instead:

```
  Trailer invalidations: unknown  (gh unavailable — open PRs with GAIA-Audit stamps may re-audit)
```

If `INVALIDATED_COUNT` is greater than 0, also print after the table:

> **Note:** $INVALIDATED_COUNT open PR(s) carry a `GAIA-Audit` trailer stamped with v$BASELINE. On their next push, CI re-runs the full audit (one extra billing cycle per PR). This is intentional — a newer GAIA agent version may catch issues the prior version missed. To minimize re-audit churn, merge or close these PRs before updating GAIA.

Then bust the update-check cache so the SessionStart prompt reflects the post-update state on the next session. Use the Write tool to overwrite `.gaia/cache/update-check.json`, preserving `gaiaCurrent`, `gaiaLatest`, and `gaiaHasUpdate` from the existing cache (read it first), but setting `outdatedCount` to `0` and `checkedAt` to the current Unix timestamp. If the cache file does not exist, skip this step.

The next SessionStart hook fires the background refresher; the session after that sees no GAIA update available.

### Step 10: Next steps for the user

Tell the user:

1. Review any conflict patches in `.gaia-merge/` and reconcile manually. Delete the patch file once resolved.
2. Run the quality gate per `wiki/decisions/Quality Gate.md` to verify the updated code still passes.
3. Inspect the diff (`git diff`) before committing.
4. When satisfied, commit with `chore: update GAIA to $LATEST_TAG`.

Do **not** auto-commit on behalf of the user — they need to review the changes first.
