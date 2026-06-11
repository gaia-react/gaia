---
name: update-gaia
description: Pull the latest GAIA release into this project without clobbering customizations. Three-way merge per file using .gaia/manifest.json classes. Trigger when the user clicks the statusline `Run /update-gaia` indicator or asks "update GAIA", "pull the latest GAIA", "apply the new GAIA release".
---

Pull the latest GAIA release into this project without clobbering customizations. Does a three-way comparison per file (adopter / baseline / latest) and respects explicit classes in `.gaia/manifest.json`:

- **`owned`**: GAIA controls fully. Overwrites silently if unchanged from baseline; prompts if drifted.
- **`shared`**: GAIA seeds, you customize. Emits a `.gaia-merge/` patch for manual resolution on drift.
- **`wiki-owned`**: GAIA-seeded concept/decision/module wiki pages. Same drift handling as `shared`.
- **adopter-owned (implicit)**: anything not in the manifest, plus sentinels like `wiki/hot.md`, `wiki/log.md`, `CHANGELOG.md`, `.gaia/VERSION`, `.gaia/manifest.json`. Never touched.

Backups land in `.gaia-backup/<timestamp>/`. Conflict patches land in `.gaia-merge/`.

## Pre-flight: Worktree check

This wrapper changes `.gaia/VERSION` and opens a PR, both belong on the main checkout, not a per-SPEC worktree branch. If invoked from a linked worktree, reject hard with a message that surfaces the cached version state from main so the user knows whether a GAIA update is even pending.

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
    cached_line="Cached state unavailable on main; symlinks may be broken, run \`.gaia/cli/gaia setup link-worktree\` to repair."
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

## Step 4: Show the release notes and confirm

Fetch the release body for `LATEST_TAG`:

```bash
gh release view "$LATEST_TAG" --repo gaia-react/gaia --json body --jq .body
```

Print the notes to the user. Then use `AskUserQuestion`:

- **Question**: "Update GAIA from v$BASELINE to $LATEST_TAG?"
- **Options**: `Proceed` / `Abort`.

On `Abort`, exit cleanly with no filesystem changes.

If `SHOULD_CREATE_BRANCH=true`, create and switch to the branch now that the user has confirmed:

```bash
git checkout -b chore/update-gaia-$(date +%Y-%m-%d-%H-%M)
```

Otherwise stay on the current branch.

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
  [ -d "$dir" ] && continue
  mkdir -p "$dir"
  if ! gh release download "$tag" \
      --repo gaia-react/gaia \
      --pattern "gaia-${tag}.tar.gz" \
      --dir "$dir" \
    || ! tar -xzf "$dir/gaia-${tag}.tar.gz" -C "$dir" --strip-components=1; then
    rm -rf "$dir"
    echo "FETCH_FAILED $tag"
  fi
done
```

`BASELINE_DIR=".gaia/cache/v$BASELINE"`, `LATEST_DIR=".gaia/cache/$LATEST_TAG"`.

The block prints `FETCH_FAILED <tag>` for any tag whose download or extraction did not complete, and removes the partial cache dir so a re-run retries cleanly. On any `FETCH_FAILED`, **stop, do not proceed to Step 6**:

- `FETCH_FAILED $LATEST_TAG`: the latest release is unreachable (network, auth, or a missing release asset). Tell the user, then re-run once it is reachable.
- `FETCH_FAILED v$BASELINE`: the baseline tarball is unavailable (older release, pre-manifest). The three-way merge needs a baseline, so stop and explain the adopter can manually cherry-pick changes by comparing their project to `$LATEST_DIR`.

### Step 6: Load the latest manifest

```bash
LATEST_MANIFEST="$LATEST_DIR/.gaia/manifest.json"
```

Iterate keys of `.files`. For each `<path>, <class>` entry, apply the decision table below. Track counts per outcome for the summary.

### Step 7: Three-way merge

Apply the decision table directly, there is no CLI for this step.

**Setup:**

```bash
BACKUP_DIR=".gaia-backup/$(date +%Y%m%d-%H%M%S)"
mkdir -p .gaia-merge "$BACKUP_DIR"
```

Track seven lists plus a `package.json` sub-report internally (`UpdateMergeReport`):

```ts
{
  overwrite: string[];   // owned files overwritten with latest
  skip: string[];        // no change needed; left alone
  merge: string[];       // clean shared/wiki-owned merges written into the working tree
  add: string[];         // new files copied from latest
  removed: string[];     // adopter deleted a baseline file; deletion respected, left absent
  delete: string[];      // files removed upstream; surfaced but NOT auto-deleted
  conflicts: Array<{
    path: string;
    class: 'owned' | 'shared' | 'wiki-owned';
    patch_path: string;  // .gaia-merge/<path>.patch
  }>;
  packageJson: {         // field-aware result for package.json (Step 7a)
    applied: string[];      // managed keys GAIA changed that the adopter still tracked at the baseline pin, written to the working tree
    conflicts: string[];    // managed keys GAIA changed but the adopter independently re-pinned, left as the adopter's, noted
    suggestions: string[];  // managed keys GAIA added, or changed but the adopter had removed, surfaced opt-in, never applied
    notes_path?: string;    // .gaia-merge/package.json.notes when conflicts or suggestions exist
  };
  pnpmWorkspace: {       // field-aware result for pnpm-workspace.yaml (Step 7b)
    applied: string[];      // managed keys / overrides+allowBuilds entries GAIA changed that the adopter still tracked, written to the working tree
    conflicts: string[];    // managed keys / entries GAIA changed but the adopter independently re-pinned, left as the adopter's, noted
    suggestions: string[];  // managed keys / entries GAIA added, or changed but the adopter had removed, surfaced opt-in, never applied
    notes_path?: string;    // .gaia-merge/pnpm-workspace.yaml.notes when conflicts or suggestions exist
  };
}
```

**Iterate every `<path>: <class>` entry in `$LATEST_MANIFEST`'s `.files` object, except `package.json` and `pnpm-workspace.yaml`**, both are handled field-aware below (`package.json` in **Step 7a**, `pnpm-workspace.yaml` in **Step 7b**). A whole-file `cmp`/`diff` can't separate adopter identity and intentional removals from the real upstream delta, and `pnpm-workspace.yaml` is a mixed file (GAIA-authored supply-chain / resolution settings plus adopter-extensible `overrides` and `allowBuilds` maps) that drifts the moment an adopter adds one override. Skip both during this walk.

Let `A` = working-tree `<path>`, `B` = `$BASELINE_DIR/<path>`, `L` = `$LATEST_DIR/<path>`. Use `cmp -s` for equality; `mkdir -p` before writing.

**Match in declared order, first matching row wins.** Baseline presence (`B`) is the discriminator for a missing working-tree file: `A` missing with `B` also missing means the file is genuinely new in the latest release and gets added; `A` missing with `B` present means the adopter deliberately deleted a file that shipped in their baseline, so the deletion is respected and the file is left absent. The `B` ≅ `L` row (no upstream change) short-circuits every class before any conflict is declared, an adopter-drifted file the release never touched has nothing to merge, so it stays as-is and emits no patch.

| Class                   | Condition                                              | Action                                                   | List                                                         |
| ----------------------- | ------------------------------------------------------ | -------------------------------------------------------- | ------------------------------------------------------------ |
| any                     | `A` missing and `B` missing (genuinely new in latest)  | Copy `L` → `<path>`                                      | `add[]`                                                      |
| any                     | `A` missing and `B` exists (adopter deleted it)        | No-op, respect the deletion, leave absent                | `removed[]`                                                  |
| `owned`                 | `B` missing (`A` exists; release newly owns this path) | Back up `A` to `$BACKUP_DIR/<path>`; copy `L` → `<path>` | `overwrite[]`                                                |
| any                     | `B` ≅ `L` (no upstream change)                         | No-op                                                    | `skip[]`                                                     |
| any                     | `A` ≅ `B` (no adopter drift)                           | Back up `A` to `$BACKUP_DIR/<path>`; copy `L` → `<path>` | `owned` → `overwrite[]`; `shared` / `wiki-owned` → `merge[]` |
| any                     | `A` ≅ `L` (adopter already at latest)                  | No-op                                                    | `skip[]`                                                     |
| `owned`                 | `A` ≠ `B` and `A` ≠ `L`                                | `diff -u "$A" "$L" > .gaia-merge/<path>.patch`           | `conflicts[]`                                                |
| `shared` / `wiki-owned` | `A` ≠ `B` and `A` ≠ `L`                                | `diff -u "$A" "$L" > .gaia-merge/<path>.patch`           | `conflicts[]`                                                |

**After iterating the manifest,** collect deletions: files present under `$BASELINE_DIR` with no corresponding key in `$LATEST_MANIFEST`'s `.files`. Split each by working-tree presence: a file still present in the working tree goes to `delete[]` (surfaced for the user to confirm, never auto-removed); a file the adopter has already removed (working-tree absent) is already reconciled, so record it in `removed[]` count-only with no prompt. This mirrors the per-key table's `delete` vs `removed` split for upstream-dropped files.

**Handling results:**

- `overwrite[]`, `skip[]`, `merge[]`, `add[]`, `removed[]`: **report counts only, no per-file narrative.** Do not read file bytes.
- `delete[]`: **ask the user before removing** each path.
- `conflicts[]`: read the patch at `.gaia-merge/<path>.patch` and walk the user through the decision per file.
- `packageJson`: populated by **Step 7a**. The `applied[]` keys are already written to the working tree (report counts only); walk the user through `conflicts[]` (re-pinned keys) and mention `suggestions[]` (added / removed-then-changed deps) as opt-in, both detailed in `.gaia-merge/package.json.notes`.
- `pnpmWorkspace`: populated by **Step 7b**. Same shape and handling as `packageJson`, detailed in `.gaia-merge/pnpm-workspace.yaml.notes`.

### Step 7a: Field-aware `package.json` merge

`package.json` is classed `shared`, but a whole-file three-way merge produces pure noise for it: **every** adopter diverges it at init (`gaia-init` rewrites `name` / `description` / `author` and resets `version`), and GAIA bumps its own `version` on **every** release, so `A ≠ B`, `A ≠ L`, and `B ≠ L` all hold on every release, and the generic table emits a full-file conflict patch dominated by identity fields no adopter wants from GAIA. Merge it at JSON-key granularity instead, acting only on the genuine upstream delta `B → L`.

Let `A` = working-tree `package.json`, `B` = `$BASELINE_DIR/package.json`, `L` = `$LATEST_DIR/package.json`.

**Adopter-owned keys, never compared, merged, or patched.** Every top-level key **except** the managed sections below is the adopter's, left exactly as-is: `name`, `version`, `description`, `author`, `private`, `type`, `bin`, `sideEffects`, and anything else. Identity drift is invisible to this step.

**Managed sections, three-way merged per entry:**

- **Object sections, merged per entry key:** `dependencies`, `devDependencies`, `scripts`, `engines`.
- **Scalar / whole-value keys, merged as a single value:** `packageManager`.

Resolution, `overrides`, and build-approval (`allowBuilds`) settings live in `pnpm-workspace.yaml`, classed `owned` and merged by the generic Step 7 walk, not here. pnpm 11 reads them only from there; the `package.json` `pnpm` field and a top-level `overrides` key are not pnpm-managed `package.json` sections.

For each managed entry key `k` (within its section), with `Bk` / `Lk` / `Ak` its value in baseline / latest / adopter:

| Condition on `k`                                           | Meaning                                          | Action                                                                            | Bucket          |
| ---------------------------------------------------------- | ------------------------------------------------ | --------------------------------------------------------------------------------- | --------------- |
| in `B` and `L`, `Bk == Lk`                                 | GAIA didn't change it                            | **No-op.** The adopter's value stands, kept, re-pinned, **or removed.**           | ,               |
| in `B` and `L`, `Bk != Lk`, adopter has `k` and `Ak == Bk` | GAIA changed the pin; adopter still at baseline  | **Apply** `Lk` to the working tree                                                | `applied[]`     |
| in `B` and `L`, `Bk != Lk`, adopter has `k` and `Ak != Bk` | GAIA changed it; adopter re-pinned independently | **Conflict.** Leave `Ak`; note both pins. Never silently override an adopter pin. | `conflicts[]`   |
| in `B` and `L`, `Bk != Lk`, adopter removed `k`            | GAIA changed a dep the adopter dropped           | **Suggestion.** Do **not** re-add. Note as opt-in.                                | `suggestions[]` |
| in `L`, not in `B`                                         | GAIA **added** it                                | **Suggestion.** Do **not** auto-insert. Note as opt-in.                           | `suggestions[]` |
| in `B`, not in `L`                                         | GAIA **removed** it                              | If the adopter still has `k`, leave it (adopter's choice).                        | ,               |

**The load-bearing row is the first one:** a dependency the adopter removed (present in `B`, absent from `A`) is **never re-added** unless GAIA itself changed it this release _and_ the adopter opts in. The default everywhere is to respect the adopter's value. This is the JSON-key analog of the file-level "respect adopter deletions" rule the generic table already enforces.

**Compute the per-key verdicts** with `jq` (covers the object sections):

```bash
jq -n \
  --slurpfile a package.json \
  --slurpfile b "$BASELINE_DIR/package.json" \
  --slurpfile l "$LATEST_DIR/package.json" '
  ($a[0]) as $A | ($b[0]) as $B | ($l[0]) as $L
  | [["dependencies"],["devDependencies"],["scripts"],["engines"]] as $sections
  | [ $sections[] as $sp
      | (($B | getpath($sp)) // {}) as $bs
      | (($L | getpath($sp)) // {}) as $ls
      | (($A | getpath($sp)) // {}) as $as
      | (($bs + $ls) | keys_unsorted | unique)[] as $k
      | { section: ($sp | join(".")), key: $k, baseline: $bs[$k], latest: $ls[$k], adopter: $as[$k],
          verdict:
            (if ($bs | has($k)) and ($ls | has($k)) then
               (if $bs[$k] == $ls[$k] then "noop"
                elif ($as | has($k) | not) then "suggest-removed"
                elif $as[$k] == $bs[$k] then "apply"
                else "conflict" end)
             elif ($ls | has($k)) then "suggest-add"
             else "noop" end) }
      | select(.verdict != "noop") ]'
```

Apply the same rule to the scalar `packageManager` by hand: `B == L` → no-op; `B != L` and `A == B` → apply; `B != L` and `A != B` → conflict; in `L` only → suggest-add; in `B` only → no-op.

**Apply clean changes (`applied[]`):** edit the single line for `k` in the working-tree `package.json` so its value becomes `Lk`, using the **Edit** tool, preserve the adopter's formatting and key order. Do **not** reserialize the file with `jq` write-back; that reorders keys and buries the real change in noise.

**Record conflicts + suggestions:** if either bucket is non-empty, write a human-readable `.gaia-merge/package.json.notes` listing, per key: the section, the key, the adopter / baseline / latest values, and the recommended action. Set `notes_path`. This file is informational, the adopter reconciles re-pin conflicts by hand and accepts or ignores suggestions. It is **not** a `diff -u` patch and is **not** added to the file-level `conflicts[]` bucket.

**Net effect:**

- **Version-only release** (no managed-key delta) → identity ignored, zero applied/conflicts/suggestions → **clean skip, no notes file.** Fixes the every-release noise.
- **Dep-bump release** → only the entries GAIA actually changed (and that the adopter still tracks) are applied; re-pin conflicts and added/removed-dep suggestions go to the notes file, never re-adding a dependency the adopter removed, never overwriting an adopter pin.

### Step 7b: Field-aware `pnpm-workspace.yaml` merge

`pnpm-workspace.yaml` is classed `shared`, but it is a **mixed** file, so a whole-file three-way merge produces the same noise `package.json` does. It carries GAIA-authored settings (`minimumReleaseAge`, `trustPolicy`, `trustPolicyExclude`, `minimumReleaseAgeExclude`, `publicHoistPattern`, `savePrefix`, `strictPeerDependencies`) **and** adopter-extensible maps (`overrides`, `allowBuilds`). pnpm 11 reads dependency overrides and build approvals only from here, so any adopter who adds a single override drifts the file and eats a full-file conflict patch on every release that touches it. Merge it at YAML-key / map-entry granularity instead, acting only on the genuine upstream delta `B → L`.

Let `A` = working-tree `pnpm-workspace.yaml`, `B` = `$BASELINE_DIR/pnpm-workspace.yaml`, `L` = `$LATEST_DIR/pnpm-workspace.yaml`.

**Presence triage first** (older baselines predate pnpm 11 and have no `pnpm-workspace.yaml`). Match the first row that applies; only the last row runs the field-aware merge:

| Condition                       | Action                                                                                                  |
| ------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `L` missing                     | Upstream dropped the file; fold into the Step 7 deletion sweep (`delete[]`). Skip 7b.                    |
| `A` missing and `B` missing     | Genuinely new; copy `L` → `pnpm-workspace.yaml`. Record in `add[]`. Skip 7b.                             |
| `A` missing and `B` exists      | Adopter deleted it; respect the deletion, leave absent. Record in `removed[]`. Skip 7b.                  |
| `A` exists and `B` missing      | No baseline to field-merge against; `diff -u A L > .gaia-merge/pnpm-workspace.yaml.patch`. Surface as a conflict. Skip 7b. |
| `A`, `B`, `L` all exist         | Run the field-aware merge below.                                                                        |

**Compute the per-key / per-entry verdicts** with the bundled CLI (it parses all three files with `js-yaml` and never writes the YAML):

```bash
.gaia/cli/gaia update merge-workspace \
  --baseline "$BASELINE_DIR/pnpm-workspace.yaml" \
  --latest "$LATEST_DIR/pnpm-workspace.yaml" \
  --current pnpm-workspace.yaml \
  --json
```

The command exits non-zero with a structured error if any file is missing or not valid YAML (for example the adopter introduced a syntax error). On a non-zero exit, fall back to a whole-file conflict patch (`diff -u A L > .gaia-merge/pnpm-workspace.yaml.patch`) and surface it as a conflict; do not proceed with the JSON path.

The JSON report is `{ applied, conflicts, suggestions }`. Each item is `{ kind: 'key' | 'entry', section?, key, baseline?, latest?, adopter?, reason? }`. The CLI iterates only `keys(B) ∪ keys(L)` per managed key and per `overrides` / `allowBuilds` entry, so an adopter-only override or build approval is never visited, never clobbered. The seven GAIA-managed keys are compared whole-value; the two map sections are compared per entry. Both use the identical verdict table as Step 7a (`apply` / `conflict` / `suggest-add` / `suggest-removed`).

**Apply clean changes (`applied[]`):** for each item, edit the working-tree `pnpm-workspace.yaml` so the key's (or entry's) value becomes `latest`, using the **Edit** tool. Preserve the file's comments, key order, and quote style; change only the value text. Do **not** reserialize the file (`js-yaml` `dump` strips every comment). A whole-value list change replaces the list block; a scalar or map-entry change edits the single line.

**Record conflicts + suggestions:** if either bucket is non-empty, write a human-readable `.gaia-merge/pnpm-workspace.yaml.notes` listing, per item: the section (if any), the key, the adopter / baseline / latest values, and the recommended action. Set `notes_path`. This file is informational; the adopter reconciles re-pin conflicts by hand and accepts or ignores suggestions. It is **not** a `diff -u` patch and is **not** added to the file-level `conflicts[]` bucket.

**Net effect:**

- **No managed-key delta** (overrides / allowBuilds / settings unchanged by the release) → zero applied/conflicts/suggestions → **clean skip, no notes file.**
- **Settings or override change** → only the keys / entries GAIA actually changed (and that the adopter still tracks) are applied; re-pin conflicts and added/removed suggestions go to the notes file, never re-adding a key the adopter removed, never overwriting an adopter override.

### Step 8: Count trailer invalidations

The version bump itself is deferred to Step 9 (after the summary prints) so an interrupted run stays resumable, see that step for the rationale. First, while `BASELINE` still names the installed version, count open PRs whose `GAIA-Audit` trailer is stamped with it. The upcoming bump invalidates them, they re-run the full CI audit on their next push:

```bash
INVALIDATED_COUNT=0
if command -v gh >/dev/null 2>&1; then
  OLD_VERSION="$BASELINE"
  pr_list=$(gh pr list --state open --json number,headRefOid 2>/dev/null || true)
  if [ -n "$pr_list" ]; then
    while IFS= read -r sha; do
      [ -z "$sha" ] && continue
      msg=$(git log -1 --format='%B' "$sha" 2>/dev/null || true)
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

### Step 8b: Migrate SPEC artifacts to per-SPEC folders

SPEC artifacts live in per-SPEC folders: `.gaia/local/specs/<spec_id>/SPEC.md` (archived: `.gaia/local/specs/archived/<spec_id>/`). `.gaia/local/specs/**` is adopter-owned data the three-way merge never touches, so the freshly-updated runbooks reference the folder layout while the adopter's existing specs may still be flat files. Run the migration script to fold any flat specs into the folder layout. It is idempotent, a no-op when specs are already foldered or none exist, so run it unconditionally:

```bash
spec_folderize_out=$(bash .specify/extensions/gaia/lib/spec-folderize.sh 2>&1)
spec_folderize_rc=$?
```

Parse the result for the Step 9 summary:

- The script writes `spec-folderize: migrated <n> SPEC artifact(s) ...` to stderr on a successful migration. Persist `<n>` as `SPECS_MIGRATED`. On a no-op (already foldered or no specs) the script exits `0` with a `nothing to migrate` line, set `SPECS_MIGRATED=0`.
- Exit code `4` is a migration conflict: a flat `SPEC-<id>.md` **and** a folder `<id>/SPEC.md` both exist for the same id. The script names both conflicting paths on stderr and changes nothing. **Do not swallow this and do not auto-resolve it.** Capture the conflicting ids/paths from `$spec_folderize_out`, set `SPECS_MIGRATED="conflict"`, and surface it in Step 9 as a blocking action item the user must reconcile by hand.
- Any other non-zero exit (`2` usage, `3` unresolvable repo root) is a script-invocation error. **Do not hard-stop here**, that would discard the Step 9 summary covering every file already merged. Capture `$spec_folderize_out`, set `SPECS_MIGRATED="error"`, and route it through Step 9 as a blocking action item (same handling as the exit-`4` conflict).

### Step 9: Summary

Print a table:

```
GAIA update: v$BASELINE → $LATEST_TAG

  Overwritten:  <n>
  Added:        <n>
  Removed:      <n>  (files you deleted; left absent, deletion respected)
  Skipped:      <n>
  Conflicts:    <n>  (see .gaia-merge/)
  Deleted:      <n>  (removed upstream; surfaced, not auto-deleted)
  package.json: <a> applied, <c> conflicts, <s> suggestions  (field-aware; see .gaia-merge/package.json.notes)
  pnpm-workspace.yaml: <a> applied, <c> conflicts, <s> suggestions  (field-aware; see .gaia-merge/pnpm-workspace.yaml.notes)
  Backed up:    <n>  (see .gaia-backup/<timestamp>/)
  Specs migrated: <n>  (flat .gaia/local/specs files folded into per-SPEC folders)
  Trailer invalidations: <n>  (open PRs stamped v$BASELINE will re-audit on next push)
```

When all three `package.json` counts are zero, render that row as `package.json: no managed-key changes (clean skip)` and omit the notes reference. Apply the same rule to the `pnpm-workspace.yaml` row: `pnpm-workspace.yaml: no managed-key changes (clean skip)` when all three of its counts are zero. If 7b fell back to a whole-file conflict patch (presence triage or a parse failure), render the row as `pnpm-workspace.yaml: whole-file conflict (see .gaia-merge/pnpm-workspace.yaml.patch)` instead.

Use `SPECS_MIGRATED` for the `Specs migrated` row. If it is `"conflict"`, emit the row as `Specs migrated: conflict, see action item below` and, after the table, print a blocking action item naming the conflicting ids/paths from `$spec_folderize_out`:

> **Action required:** SPEC migration could not complete. A flat `SPEC-<id>.md` and a folder `<id>/SPEC.md` exist for the same id: <conflicting paths>. Resolve by hand (keep one, remove the other), then re-run `bash .specify/extensions/gaia/lib/spec-folderize.sh` to finish the migration. The freshly-updated runbooks reference the folder layout, so leaving this unresolved breaks SPEC tooling.

If `SPECS_MIGRATED` is `"error"`, emit the row as `Specs migrated: error, see action item below` and, after the table, print a blocking action item carrying the script-invocation failure from `$spec_folderize_out`:

> **Action required:** SPEC migration could not run, the `spec-folderize.sh` script errored: <`$spec_folderize_out`>. The GAIA file merge completed and is summarized above; only the SPEC-artifact migration was skipped. Fix the reported error, then re-run `bash .specify/extensions/gaia/lib/spec-folderize.sh` to finish the migration. The freshly-updated runbooks reference the folder layout, so leaving this unresolved breaks SPEC tooling.

If `INVALIDATED_COUNT` is `"unknown"`, emit instead:

```
  Trailer invalidations: unknown  (gh unavailable, open PRs with GAIA-Audit stamps may re-audit)
```

If `INVALIDATED_COUNT` is greater than 0, also print after the table:

> **Note:** $INVALIDATED_COUNT open PR(s) carry a `GAIA-Audit` trailer stamped with v$BASELINE. On their next push, CI re-runs the full audit (one extra billing cycle per PR). This is intentional, a newer GAIA agent version may catch issues the prior version missed. To minimize re-audit churn, merge or close these PRs before updating GAIA.

The merge walk is complete and the summary is recorded, so finalize the version. Write the new version and refresh the manifest:

```bash
echo "$LATEST" > .gaia/VERSION
```

Also copy `.gaia/manifest.json` from `$LATEST_DIR/.gaia/manifest.json` into the project so the next `/update-gaia` has the right baseline. Unresolved conflict patches, re-pin notes, or a SPEC-migration action item do **not** block this bump, they are follow-ups the user resolves against the already-recorded update; `.gaia/VERSION` tracks the file merge, which is done.

Deferring the bump to this point (rather than before the walk) keeps an interrupted run resumable: any abort during the walk (user cancels, disk error) leaves `.gaia/VERSION` at `BASELINE`, and because the merge is idempotent (already-merged files match latest and skip), a re-run picks up cleanly. Overwritten files are safe, their prior state is in `.gaia-backup/`. Step 3 catches the remaining window where the bump landed but the user has not yet committed.

Then bust the update-check cache so the SessionStart prompt reflects the post-update state on the next session. Use the Write tool to overwrite `.gaia/cache/update-check.json` with `gaiaCurrent` set to `$LATEST`, `gaiaLatest` set to `$LATEST`, `gaiaHasUpdate` set to `false`, `outdatedCount` set to `0`, and `checkedAt` set to the current Unix timestamp. If the cache file does not exist, skip this step.

The next SessionStart hook fires the background refresher; the session after that sees no GAIA update available.

### Step 10: Next steps for the user

Tell the user:

1. Review any conflict patches in `.gaia-merge/` and reconcile manually. Delete the patch file once resolved. If `.gaia-merge/package.json.notes` or `.gaia-merge/pnpm-workspace.yaml.notes` exists, reconcile the re-pin conflicts and decide on the suggestions, then delete it.
2. If the `package.json` or `pnpm-workspace.yaml` merge applied any change (a dependency / `packageManager` bump, or an override / `allowBuilds` / resolution-setting change), run `pnpm install` to sync `pnpm-lock.yaml` before the quality gate.
3. Run the quality gate per `wiki/decisions/Quality Gate.md` to verify the updated code still passes.
4. Inspect the diff (`git diff`) before committing.
5. When satisfied, commit with `chore: update GAIA to $LATEST_TAG`.

Do **not** auto-commit on behalf of the user, they need to review the changes first.

---

## Steps 11–12 (orchestrator, after the user commits)

The execution agent's work ends at Step 10, it returns its `UpdateMergeReport` and the orchestrator relays the summary. Steps 11-12 run in the **orchestrator**, not the spawned agent: they depend on the Step 10 commit, which is the user's manual action and lands after the one-shot agent has already returned. Run them once that commit exists.

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
      --title "chore: update GAIA to $LATEST_TAG" \
      --body "Pulls GAIA $LATEST_TAG into the project. Per-file outcomes are in the update summary above."
  fi
fi
```

If `gh` is unavailable or errors, tell the user to open the PR manually: `$branch` → `main`.

### Step 12: Flag a stale CI audit workflow

`.github/workflows/code-review-audit.yml` is **not** synced by `/update-gaia`, it installs and updates only via `/setup-gaia-ci`. A project that enabled GAIA CI on an older release therefore keeps whatever audit workflow shipped then, frozen, even after this update pulls a newer template. A stale workflow still audits in-scope PRs correctly, but an older copy may not stamp the `GAIA-Audit` status on out-of-scope (docs/metadata-only) PRs, which includes the update PR just opened. The merge gate's out-of-scope bypass keeps that PR mergeable regardless, but the workflow is worth refreshing.

Probe for drift and advise only when the installed workflow is behind:

```bash
audit_drift="$(.gaia/cli/gaia setup-ci check-audit-drift --json 2>/dev/null \
  | jq -r '.state // "unknown"' 2>/dev/null || echo unknown)"
if [ "$audit_drift" = "drifted" ]; then
  echo "Heads up: .github/workflows/code-review-audit.yml is out of date vs the $LATEST_TAG template. Run /setup-gaia-ci to refresh it so the CI audit stamps the GAIA-Audit status correctly (including on out-of-scope PRs). The merge gate's out-of-scope bypass keeps this docs-only update PR mergeable in the meantime."
fi
```

`in_sync` means nothing to do; `missing` means GAIA CI is not installed (the merge gate falls back to the local `code-review-audit` agent, or the out-of-scope bypass for docs/metadata-only PRs), so stay silent. Only `drifted` warrants the nudge.
