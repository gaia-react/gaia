#!/usr/bin/env bash
# spec-renumber.sh: Renumber a SPEC. Renames the local SPEC folder, updates the
# inner SPEC.md frontmatter, rewrites the .gaia/local/specs/ledger.json ledger
# row, and best-effort re-keys the gate1/draft/session/lock/audit caches under
# .gaia/local/cache/. The inner SPEC.md keeps its name; any sibling artifacts in
# the folder move with it.
# Does NOT touch external state (branch names, GH issue titles, commit-message
# history), those are reported as next steps for the caller to handle consciously.
#
# Usage:
#   spec-renumber.sh <repo_root> <old_id> <new_id>
#
# Refuses if:
#   - repo_root is not a git working tree
#   - old/new id is not in SPEC-NNN form
#   - old SPEC folder is missing
#   - new id is already taken (per spec-allocator.sh self-heal scan)
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: spec-renumber.sh <repo_root> <old_id> <new_id>" >&2
  exit 2
fi

repo_root="$1"
old_id="$2"
new_id="$3"
allocator="${repo_root%/}/.specify/extensions/gaia/lib/spec-allocator.sh"

# Source the shared ledger-path lib from this script's own directory, never
# through repo_root: repo_root is the value whose trustworthiness is in
# question here, so loading a library by it would decide correctness with the
# input under test.
_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#
# Bracketed against a target that is present but UNPARSEABLE. A bare `.` under
# errexit abandons the shell AT the load, exit 2 with no diagnostic, and a
# trailing `|| true` does not save it on stock macOS /bin/bash 3.2.57, which
# aborts before the arm is ever evaluated: the refusal written below would never
# run. An interrupted update, an unresolved merge conflict, and a truncated
# write all leave exactly that state on disk. No probe of its own here, because
# the gaia_resolve_specs_dir call below already refuses when the function is
# absent, which is the degrade this load owes.
# shellcheck source=../../../../.gaia/scripts/ledger-path-lib.sh
set +e; [ -f "${_library_directory}/../../../../.gaia/scripts/ledger-path-lib.sh" ] && . "${_library_directory}/../../../../.gaia/scripts/ledger-path-lib.sh" 2>/dev/null; set -e
# The branch-naming library reads a SPEC number back out of a plan branch in
# every spelling GAIA mints, the worktree one included. Loaded the same
# bracketed way as the ledger-path lib above, for the same reason.
# shellcheck source=../../../../.gaia/scripts/branch-name-lib.sh
set +e; [ -f "${_library_directory}/../../../../.gaia/scripts/branch-name-lib.sh" ] && . "${_library_directory}/../../../../.gaia/scripts/branch-name-lib.sh" 2>/dev/null; set -e
if ! type gaia_branch_spec_number >/dev/null 2>&1; then
  echo "spec-renumber: the branch-naming library is unusable, so SPEC numbers held only on a branch cannot be read; refuse to renumber" >&2
  exit 4
fi

if ! git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
  echo "spec-renumber: $repo_root is not a git repository" >&2
  exit 3
fi

# repo_root names the tree this renumber runs in; the ledger and folder it
# rewrites are main's, because the state registry declares specs/ main-only.
# Resolve rather than trust: using repo_root directly could rename a folder
# in one tree while the ledger row lands in main's, forking the two. Refuse
# rather than fall back to the unresolved operand.
if ! specs_directory="$(gaia_resolve_specs_dir "$repo_root" 2>/dev/null)" || [ -z "$specs_directory" ]; then
  echo "spec-renumber: cannot resolve the main checkout for '$repo_root'; refuse to renumber (would fork the ledger across worktrees)" >&2
  exit 3
fi
ledger_path="${specs_directory}/ledger.json"
# main_root: the checkout that physically owns specs_directory, derived from the
# resolver's own contract (<main_root>/.gaia/local/specs) rather than a second
# resolution. The git mv/ls-files calls below touch paths under specs_directory, so
# they must run against the repo that contains them, not the raw repo_root
# operand, which can be a different worktree.
main_root="${specs_directory%/.gaia/local/specs}"

for id in "$old_id" "$new_id"; do
  if [[ ! "$id" =~ ^SPEC-[0-9]+$ ]]; then
    echo "spec-renumber: invalid id '$id' (expected SPEC-NNN)" >&2
    exit 2
  fi
done

if [ "$old_id" = "$new_id" ]; then
  echo "spec-renumber: old and new ids are identical ($old_id)" >&2
  exit 2
fi

old_path="${specs_directory}/${old_id}"
new_path="${specs_directory}/${new_id}"
old_spec="${old_path}/SPEC.md"
new_spec="${new_path}/SPEC.md"

if [ ! -f "$old_spec" ]; then
  echo "spec-renumber: source SPEC file not found at $old_spec" >&2
  exit 4
fi

if [ -e "$new_path" ]; then
  echo "spec-renumber: target folder $new_path already exists" >&2
  exit 4
fi

# Reject if the new id is already known to the allocator (ledger / branch / filesystem).
new_number=$((10#${new_id#SPEC-}))
old_number=$((10#${old_id#SPEC-}))
if [ -x "$allocator" ] || [ -f "$allocator" ]; then
  if bash "$allocator" highest "$repo_root" >/dev/null 2>&1; then
    while IFS= read -r known_number; do
      [ -z "$known_number" ] && continue
      if [ "$((10#$known_number))" -eq "$new_number" ]; then
        echo "spec-renumber: $new_id is already known (ledger/branch/filesystem)" >&2
        exit 4
      fi
    done < <(
      # Inline the same scan the allocator uses, minus the ledger row we are about to rewrite.
      jq -r --arg drop "$old_id" '.specs[] | select(.id != $drop) | .id' "$ledger_path" 2>/dev/null \
        | sed -nE 's|^SPEC-0*([0-9]+)$|\1|p' || true
      # The test is a builtin prefilter so a branch that cannot name a
      # SPEC skips the subshells of the library; this scan runs under the ledger
      # lock, and a repository carries hundreds of refs.
      gaia_branch_list "$repo_root" | while IFS= read -r branch; do
        if [[ "$branch" == *spec-* ]]; then gaia_branch_spec_number "$branch"; fi
      done
      find "$specs_directory" -mindepth 2 -maxdepth 2 -type f -name 'SPEC.md' -print 2>/dev/null \
        | sed -nE 's|.*/SPEC-0*([0-9]+)/SPEC\.md$|\1|p' || true
    )
  fi
fi

# 1. Move the folder whole. Inner SPEC.md keeps its name; siblings ride along.
#    git mv when the inner SPEC.md is tracked, plain mv otherwise.
if git -C "$main_root" ls-files --error-unmatch "$old_spec" >/dev/null 2>&1; then
  git -C "$main_root" mv "$old_path" "$new_path"
else
  mv "$old_path" "$new_path"
fi

# 2. Rewrite frontmatter spec_id (and stamp renamed_from for traceability).
#    Operates on the YAML frontmatter block between the first two `---` lines.
temporary_spec_file="$(mktemp)"
awk -v new_id="$new_id" -v old_id="$old_id" '
  BEGIN { in_frontmatter = 0; frontmatter_delimiter_count = 0; stamped = 0 }
  /^---[[:space:]]*$/ {
    frontmatter_delimiter_count++
    if (frontmatter_delimiter_count == 1) { in_frontmatter = 1; print; next }
    if (frontmatter_delimiter_count == 2) {
      if (in_frontmatter && !stamped) { print "renamed_from: " old_id; stamped = 1 }
      in_frontmatter = 0; print; next
    }
  }
  in_frontmatter && /^spec_id:[[:space:]]/ { print "spec_id: " new_id; next }
  { print }
' "$new_spec" > "$temporary_spec_file"
mv "$temporary_spec_file" "$new_spec"

# 3. Update ledger row in place.
if [ -f "$ledger_path" ]; then
  temporary_ledger_file="$(mktemp)"
  if jq --arg old "$old_id" --arg new "$new_id" '
        .specs |= map(
          if .id == $old then
            . + { id: $new, renamed_from: $old }
          else . end
        )
      ' "$ledger_path" > "$temporary_ledger_file"; then
    mv "$temporary_ledger_file" "$ledger_path"
  else
    rm -f "$temporary_ledger_file"
    echo "spec-renumber: failed to update ledger; reverting folder move" >&2
    if git -C "$main_root" ls-files --error-unmatch "$new_spec" >/dev/null 2>&1; then
      git -C "$main_root" mv "$new_path" "$old_path"
    else
      mv "$new_path" "$old_path"
    fi
    exit 5
  fi
fi

# 4. Best-effort re-key of the id-bearing per-spec caches under
#    .gaia/local/cache/ (draft checkpoint, session-shape cache, liveness lock,
#    audit-findings directory). A missing cache is a normal no-op. A
#    cache-move failure is logged to stderr and does not revert the
#    folder/ledger move above; that move already succeeded and remains the
#    source of truth.
cache_directory="${repo_root%/}/.gaia/local/cache"

old_gate1="${cache_directory}/gate1-${old_id}.json"
new_gate1="${cache_directory}/gate1-${new_id}.json"
if [ -e "$old_gate1" ]; then
  if ! mv "$old_gate1" "$new_gate1" 2>/dev/null; then
    echo "spec-renumber: failed to re-key gate1 cache $old_gate1" >&2
  fi
fi

old_draft="${cache_directory}/draft-${old_id}.md"
new_draft="${cache_directory}/draft-${new_id}.md"
if [ -e "$old_draft" ]; then
  if ! mv "$old_draft" "$new_draft" 2>/dev/null; then
    echo "spec-renumber: failed to re-key draft cache $old_draft" >&2
  fi
fi

old_session="${cache_directory}/spec-session-${old_id}.json"
new_session="${cache_directory}/spec-session-${new_id}.json"
if [ -e "$old_session" ]; then
  if mv "$old_session" "$new_session" 2>/dev/null; then
    temporary_session_file="$(mktemp)"
    if jq --arg id "$new_id" '.spec_id = $id' "$new_session" > "$temporary_session_file" 2>/dev/null; then
      mv "$temporary_session_file" "$new_session"
    else
      rm -f "$temporary_session_file"
      echo "spec-renumber: failed to rewrite spec_id in $new_session" >&2
    fi
  else
    echo "spec-renumber: failed to re-key session cache $old_session" >&2
  fi
fi

old_lock="${cache_directory}/spec-session-${old_id}.lock"
new_lock="${cache_directory}/spec-session-${new_id}.lock"
if [ -e "$old_lock" ]; then
  if mv "$old_lock" "$new_lock" 2>/dev/null; then
    temporary_lock_file="$(mktemp)"
    if jq --arg id "$new_id" '.spec_id = $id' "$new_lock" > "$temporary_lock_file" 2>/dev/null; then
      mv "$temporary_lock_file" "$new_lock"
    else
      rm -f "$temporary_lock_file"
      echo "spec-renumber: failed to rewrite spec_id in $new_lock" >&2
    fi
  else
    echo "spec-renumber: failed to re-key session lock $old_lock" >&2
  fi
fi

old_audit="${cache_directory}/audit-${old_id}"
new_audit="${cache_directory}/audit-${new_id}"
if [ -e "$old_audit" ]; then
  if ! mv "$old_audit" "$new_audit" 2>/dev/null; then
    echo "spec-renumber: failed to re-key audit cache $old_audit" >&2
  fi
fi

echo "renumbered $old_id → $new_id"
echo
echo "Next steps (external state, not auto-updated):"

# Branch name, flag if the current branch references the old id.
current_branch="$(git -C "$repo_root" symbolic-ref --short -q HEAD || true)"
if [ -n "$current_branch" ] && [ "$(gaia_branch_spec_number "$current_branch")" = "$old_number" ]; then
  new_branch="${current_branch//spec-$(printf '%03d' "$old_number")/spec-$(printf '%03d' "$new_number")}"
  echo "  - Current branch '$current_branch' references $old_id."
  echo "    Rename:   git -C $repo_root branch -m '$new_branch'"
fi

echo "  - Commit-message history is immutable; past commits keep $old_id refs."
