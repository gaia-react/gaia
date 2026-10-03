---
name: update-gaia
description: Pull the latest GAIA release into this project without clobbering customizations. Three-way merge per file using .gaia/manifest.json classes. Trigger when the user clicks the statusline `Run /update-gaia` indicator or asks "update GAIA", "pull the latest GAIA", "apply the new GAIA release".
---

Pull the latest GAIA release into this project without clobbering customizations. Does a three-way comparison per file (adopter / baseline / latest) and respects explicit classes in `.gaia/manifest.json`:

- **`owned`**: GAIA controls fully.
- **`shared`**: GAIA seeds, you customize.
- **`wiki-owned`**: GAIA-seeded concept/decision/module wiki pages.
- **adopter-owned (implicit)**: anything not in the manifest, plus sentinels like `wiki/hot.md`, `wiki/log.md`, `CHANGELOG.md`, `.gaia/VERSION`, `.gaia/manifest.json`. Never touched.

The first three take the same Step 7 rows. The class changes only two of them: which bucket a clean overwrite reports under (`owned` → `overwrite[]`, the other two → `merge[]`), and what happens when the release newly owns a path the adopter already has (`owned` backs up and overwrites, the other two fall through to the ordinary rows). Step 7 is authoritative.

Backups land in `.gaia-backup/<timestamp>/`. Conflict patches land in `.gaia-merge/`.

**After the commit.** This file runs the pre-flight through Step 4b, spawns the execution agent for Steps 5–10 (`references/merge-execution.md`), and then waits for the user. Once the user confirms the Step 10 commit, run Step 11 below.

## Pre-flight: Worktree check

This wrapper changes `.gaia/VERSION` and opens a PR, both belong on the main checkout, not a per-SPEC worktree branch. If invoked from a linked worktree, reject hard with a message that surfaces the cached version state from main so the user knows whether a GAIA update is even pending.

Detection (run this first, before anything else):

```bash
. .gaia/scripts/main-only-lib.sh
gaia_update_gaia_state_line() {
  local cache_file="$1"
  [ -f "$cache_file" ] && command -v jq >/dev/null 2>&1 || return 0
  local gaia_current gaia_latest gaia_has_update
  gaia_current="$(jq -r '.gaiaCurrent // ""' "$cache_file" 2>/dev/null)"
  gaia_latest="$(jq -r '.gaiaLatest // ""' "$cache_file" 2>/dev/null)"
  gaia_has_update="$(jq -r '.gaiaHasUpdate // false' "$cache_file" 2>/dev/null)"
  [ -n "$gaia_current" ] && [ -n "$gaia_latest" ] || return 0
  local update_phrase="not-available"
  [ "$gaia_has_update" = "true" ] && update_phrase="available"
  printf 'Cached on main: GAIA %s installed; latest %s (update %s).\n' "$gaia_current" "$gaia_latest" "$update_phrase"
}
gaia_refuse_if_worktree "/update-gaia" gaia_update_gaia_state_line || exit 1
```

If the detection does not fire, fall through to the existing `## Pre-flight: Branch check` section.

## Pre-flight: Branch check

```bash
git branch --show-current
```

If the current branch is `main` or `master`, set a flag (`SHOULD_CREATE_BRANCH=true`) but **do not create the branch yet**, creation is deferred until after the Step 4 "Proceed" confirmation. Steps 1-4 can exit early (already up to date, or the user aborts); branching before then leaves an orphan `chore/update-gaia-*` branch when there was nothing to update.

Otherwise set `SHOULD_CREATE_BRANCH=false` and proceed on the current branch.

## Step 1: Read baseline version

```bash
cat .gaia/VERSION 2>/dev/null || echo MISSING
```

If the file is missing, stop and tell the user:

> "No `.gaia/VERSION` found, this project was not scaffolded from GAIA, or the marker was deleted. Run `/gaia-init` on a fresh `create-gaia` scaffold first."

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

- If `LATEST == BASELINE`:
  - **First, detect an interrupted prior run.** If `.gaia/VERSION` differs from the last commit (`git diff --quiet HEAD -- .gaia/VERSION` exits non-zero, this catches a staged or unstaged bump), a previous `/update-gaia` already bumped the version but the update was never committed. Do **not** print "up to date", the bumped VERSION makes every re-run look current, so saying it dead-ends the user. Instead read the committed baseline (`git show HEAD:.gaia/VERSION`) for context and tell the user: the update to `v$LATEST` is already applied to the working tree but not committed. Review `git diff` and commit it (Step 10 guidance), or run `git checkout -- .gaia/VERSION` to discard the bump and re-run `/update-gaia` to start over. Exit.
  - Otherwise print "You are up to date on GAIA v$BASELINE." and exit.
- If `semver(LATEST) < semver(BASELINE)` → print a warning that the installed version is ahead of the latest release and exit. Never downgrade.

## Step 3b: Refuse a 1.x baseline

GAIA 2.0.0 moved the React app into `frontend/`, and the 2.x release manifest is keyed on those paths. A three-way merge from a 1.x baseline would read every baseline app path as an upstream deletion and offer to delete the adopter's app, so a 1.x project is migrated by the prompt at https://gaiareact.com/migrate and never by this command. Run this before the Step 4 prompt, so nothing has been created or pruned when it refuses:

```bash
BASELINE_MAJOR="${BASELINE%%.*}"
case "$BASELINE_MAJOR" in
  '' | *[!0-9]*)
    echo "REFUSED: .gaia/VERSION holds '$BASELINE', which is not a version. Fix .gaia/VERSION, then re-run /update-gaia."
    exit 1
    ;;
esac
if [ "$BASELINE_MAJOR" -lt 2 ]; then
  echo "REFUSED: this project is on GAIA $BASELINE. /update-gaia cannot cross the 2.0.0 layout change. Paste the prompt from https://gaiareact.com/migrate into a fresh session instead. Nothing was changed."
  exit 1
fi
```

On `REFUSED`, stop, relay the message, and do nothing else: no branch, no prune, no download.

## Step 4: Show the release notes and confirm

Show the human the **full baseline-to-latest CHANGELOG range**, not just the single latest tag's GitHub body, an adopter several versions behind needs every intervening entry. Read GAIA's own `CHANGELOG.md` at `$LATEST_TAG` (a plain markdown file, fetched no-auth from the raw URL, with a `gh` fallback) and extract every `## [x.y.z]` section strictly newer than `$BASELINE` through `$LATEST`:

```bash
changelog="$(curl -fsSL "https://raw.githubusercontent.com/gaia-react/gaia/$LATEST_TAG/CHANGELOG.md" 2>/dev/null)"
if [ -z "$changelog" ] && command -v gh >/dev/null 2>&1; then
  changelog="$(gh api "repos/gaia-react/gaia/contents/CHANGELOG.md?ref=$LATEST_TAG" \
    -H "Accept: application/vnd.github.raw" 2>/dev/null)"
fi

# Keep this awk program identical to the one in references/merge-execution.md Step 9.
range="$(printf '%s\n' "$changelog" | awk -v baseline="$BASELINE" -v latest="$LATEST" '
  function vcmp(a,b,   x,y,i){split(a,x,".");split(b,y,".");for(i=1;i<=3;i++){if((x[i]+0)>(y[i]+0))return 1;if((x[i]+0)<(y[i]+0))return -1}return 0}
  /^## \[Unreleased\]/           {printing=0; next}
  /^\[[^][]+\]:[[:space:]]*http/ {printing=0; next}
  /^## \[[0-9]+\.[0-9]+\.[0-9]+\]/ {
    v=$0; sub(/^## \[/,"",v); sub(/\].*/,"",v)
    printing=(vcmp(v,baseline)>0 && vcmp(v,latest)<=0)
  }
  printing {print}
')"

if [ -n "$range" ]; then
  printf '%s\n' "$range"
else
  # Fetch failed (offline, private, missing file): fall back to the single-tag
  # GitHub release body so the gate still has context.
  gh release view "$LATEST_TAG" --repo gaia-react/gaia --json body --jq .body
fi
```

The awk walks the version headers newest-first, prints the contiguous block from `$LATEST` down to (but not including) `$BASELINE`, and drops the `[Unreleased]` block and the bottom link-reference list. Print the range to the user. Then use `AskUserQuestion`:

- **Question**: "Update GAIA from v$BASELINE to $LATEST_TAG?"
- **Options**: `Proceed` / `Abort`.

On `Abort`, exit cleanly with no filesystem changes.

If `SHOULD_CREATE_BRANCH=true`, create and switch to the branch now that the user has confirmed:

```bash
git checkout -b "$(bash .gaia/scripts/branch-name-lib.sh name update "$LATEST_TAG")"
```

Otherwise stay on the current branch.

## Step 4b: Prune prior-run artifacts

Three gitignored directories accumulate across updates: `.gaia-backup/`, `.gaia/local/cache/shared/update-gaia/`, and `.gaia-merge/`. Prune the prior runs' leftovers here, at the start of a confirmed update and **before this run creates any of its own artifacts** (Step 5 populates the cache, Step 7 creates `$BACKUP_DIR`), so the current run's fresh safety net is never touched. This runs only after the Step 4 `Proceed`, so an abort, an already-up-to-date exit, and the interrupted-prior-run case Step 3 surfaces (whose backups and patches are still in flight) never reach it.

```bash
# .gaia-backup/: prior runs' pre-overwrite copies. Once an update is committed,
# git history is the durable recovery, so prior backups are redundant. This run
# creates its own $BACKUP_DIR in Step 7.
rm -rf .gaia-backup

# .gaia/local/cache/shared/update-gaia/: keep the baseline tarball (v$BASELINE
# is this run's baseline, reused by Step 5 instead of re-downloading). Delete
# every other cached tag dir. The loop only ever touches tag dirs here,
# update-check.json and serena-guard/ live one level up at shared/,
# structurally outside this glob.
if [ -d .gaia/local/cache/shared/update-gaia ]; then
  for d in .gaia/local/cache/shared/update-gaia/*/; do
    [ -d "$d" ] || continue
    [ "$(basename "$d")" = "v$BASELINE" ] && continue
    rm -rf "$d"
  done
fi

# .gaia-merge/: conflict patches + .notes the operator resolves by hand (Step
# 11). Remove only when empty; a populated dir holds unresolved action items, so
# never delete it, warn and name the leftovers instead.
if [ -d .gaia-merge ]; then
  if [ -n "$(ls -A .gaia-merge 2>/dev/null)" ]; then
    echo "Heads up: .gaia-merge/ still holds unresolved patches from a prior run, NOT deleted:"
    ls -A .gaia-merge
    echo "Resolve or delete them by hand, then re-run /update-gaia."
  else
    rmdir .gaia-merge
  fi
fi
```

## Model selection

After the user confirms, determine the model for the execution agent:

- Compare `LATEST` major vs `BASELINE` major (leading integer).
- **Major bump** → spawn an **Opus agent** (`model: "opus"`).
- **Minor or patch bump** → spawn a **Sonnet agent** (`model: "sonnet"`).

Spawn the agent for Steps 5–10, passing `BASELINE`, `LATEST`, and `LATEST_TAG`. Its prompt tells it to read `.claude/skills/update-gaia/references/merge-execution.md` in full before starting Step 5 (in chunks if the Read tool refuses the size, but every chunk before Step 5) and follow it exactly. It must finish reading before Step 5 because the Step 7 walk can overwrite this skill's own files partway through the run, and the agent keeps executing the copy it read.

---

## Step 11 (orchestrator, after the user commits)

The execution agent's work ends at Step 10, it returns its `UpdateMergeReport` and the orchestrator relays the summary. Step 11 runs in the **orchestrator**, not the spawned agent: it depends on the Step 10 commit, which is the user's manual action and lands after the one-shot agent has already returned. Run it once that commit exists.

### Step 11: Open a pull request

After the Step 10 commit lands, `/update-gaia` must not leave the branch stranded, open a PR so the update can be reviewed and merged.

The orchestrator waits for the user to confirm the Step 10 commit landed before pushing, the `git rev-list` guard below is only a backstop for the empty-branch case, not a replacement for that confirmation.

Push the branch and open a PR, but only if it has no open PR already, a re-run of `/update-gaia` on the same branch updates the existing PR instead of duplicating it:

```bash
branch="$(git branch --show-current)"

# The update must be committed first (Step 10). No commits ahead of main → finish Step 10.
if [ "$(git rev-list --count main.."$branch" 2>/dev/null || echo 0)" -eq 0 ]; then
  echo "Nothing committed ahead of main, commit the update (Step 10) before opening a PR."
  exit 0
elif ! git push -u origin "$branch"; then
  echo "Push failed, resolve the push error, then open the PR manually: $branch → main."
else
  existing="$(gh pr list --head "$branch" --state open --json number --jq '.[0].number // empty' 2>/dev/null)"
  if [ -n "$existing" ]; then
    echo "PR #$existing already open for $branch, pushed the new commit to it."
  else
    gh pr create --base main --head "$branch" \
      --title "chore(gaia): update to $LATEST_TAG" \
      --body "Pulls GAIA $LATEST_TAG into the project. Per-file outcomes are in the update summary above."
  fi
fi
```

If `gh` is unavailable or errors, tell the user to open the PR manually: `$branch` → `main`.
