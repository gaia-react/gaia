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
specs_dir="${repo_root%/}/.gaia/local/specs"
ledger_path="${repo_root%/}/.gaia/local/specs/ledger.json"
allocator="${repo_root%/}/.specify/extensions/gaia/lib/spec-allocator.sh"

if ! git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
  echo "spec-renumber: $repo_root is not a git repository" >&2
  exit 3
fi

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

old_path="${specs_dir}/${old_id}"
new_path="${specs_dir}/${new_id}"
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
new_num=$((10#${new_id#SPEC-}))
old_num=$((10#${old_id#SPEC-}))
if [ -x "$allocator" ] || [ -f "$allocator" ]; then
  if bash "$allocator" highest "$repo_root" >/dev/null 2>&1; then
    while IFS= read -r n; do
      [ -z "$n" ] && continue
      if [ "$((10#$n))" -eq "$new_num" ]; then
        echo "spec-renumber: $new_id is already known (ledger/branch/filesystem)" >&2
        exit 4
      fi
    done < <(
      # Inline the same scan the allocator uses, minus the ledger row we are about to rewrite.
      jq -r --arg drop "$old_id" '.specs[] | select(.id != $drop) | .id' "$ledger_path" 2>/dev/null \
        | sed -nE 's|^SPEC-0*([0-9]+)$|\1|p' || true
      git -C "$repo_root" for-each-ref --format='%(refname:short)' \
        'refs/heads/spec-*' 'refs/remotes/*/spec-*' 2>/dev/null \
        | sed -nE 's|^.*/?spec-0*([0-9]+)(-.*)?$|\1|p' || true
      find "$specs_dir" -mindepth 2 -maxdepth 2 -type f -name 'SPEC.md' -print 2>/dev/null \
        | sed -nE 's|.*/SPEC-0*([0-9]+)/SPEC\.md$|\1|p' || true
    )
  fi
fi

# 1. Move the folder whole. Inner SPEC.md keeps its name; siblings ride along.
#    git mv when the inner SPEC.md is tracked, plain mv otherwise.
if git -C "$repo_root" ls-files --error-unmatch "$old_spec" >/dev/null 2>&1; then
  git -C "$repo_root" mv "$old_path" "$new_path"
else
  mv "$old_path" "$new_path"
fi

# 2. Rewrite frontmatter spec_id (and stamp renamed_from for traceability).
#    Operates on the YAML frontmatter block between the first two `---` lines.
tmp_spec="$(mktemp)"
awk -v new_id="$new_id" -v old_id="$old_id" '
  BEGIN { in_fm = 0; fm_count = 0; stamped = 0 }
  /^---[[:space:]]*$/ {
    fm_count++
    if (fm_count == 1) { in_fm = 1; print; next }
    if (fm_count == 2) {
      if (in_fm && !stamped) { print "renamed_from: " old_id; stamped = 1 }
      in_fm = 0; print; next
    }
  }
  in_fm && /^spec_id:[[:space:]]/ { print "spec_id: " new_id; next }
  { print }
' "$new_spec" > "$tmp_spec"
mv "$tmp_spec" "$new_spec"

# 3. Update ledger row in place.
if [ -f "$ledger_path" ]; then
  tmp_ledger="$(mktemp)"
  if jq --arg old "$old_id" --arg new "$new_id" '
        .specs |= map(
          if .id == $old then
            . + { id: $new, renamed_from: $old }
          else . end
        )
      ' "$ledger_path" > "$tmp_ledger"; then
    mv "$tmp_ledger" "$ledger_path"
  else
    rm -f "$tmp_ledger"
    echo "spec-renumber: failed to update ledger; reverting folder move" >&2
    if git -C "$repo_root" ls-files --error-unmatch "$new_spec" >/dev/null 2>&1; then
      git -C "$repo_root" mv "$new_path" "$old_path"
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
cache_dir="${repo_root%/}/.gaia/local/cache"

old_gate1="${cache_dir}/gate1-${old_id}.json"
new_gate1="${cache_dir}/gate1-${new_id}.json"
if [ -e "$old_gate1" ]; then
  if ! mv "$old_gate1" "$new_gate1" 2>/dev/null; then
    echo "spec-renumber: failed to re-key gate1 cache $old_gate1" >&2
  fi
fi

old_draft="${cache_dir}/draft-${old_id}.md"
new_draft="${cache_dir}/draft-${new_id}.md"
if [ -e "$old_draft" ]; then
  if ! mv "$old_draft" "$new_draft" 2>/dev/null; then
    echo "spec-renumber: failed to re-key draft cache $old_draft" >&2
  fi
fi

old_session="${cache_dir}/spec-session-${old_id}.json"
new_session="${cache_dir}/spec-session-${new_id}.json"
if [ -e "$old_session" ]; then
  if mv "$old_session" "$new_session" 2>/dev/null; then
    tmp_session="$(mktemp)"
    if jq --arg id "$new_id" '.spec_id = $id' "$new_session" > "$tmp_session" 2>/dev/null; then
      mv "$tmp_session" "$new_session"
    else
      rm -f "$tmp_session"
      echo "spec-renumber: failed to rewrite spec_id in $new_session" >&2
    fi
  else
    echo "spec-renumber: failed to re-key session cache $old_session" >&2
  fi
fi

old_lock="${cache_dir}/spec-session-${old_id}.lock"
new_lock="${cache_dir}/spec-session-${new_id}.lock"
if [ -e "$old_lock" ]; then
  if mv "$old_lock" "$new_lock" 2>/dev/null; then
    tmp_lock="$(mktemp)"
    if jq --arg id "$new_id" '.spec_id = $id' "$new_lock" > "$tmp_lock" 2>/dev/null; then
      mv "$tmp_lock" "$new_lock"
    else
      rm -f "$tmp_lock"
      echo "spec-renumber: failed to rewrite spec_id in $new_lock" >&2
    fi
  else
    echo "spec-renumber: failed to re-key session lock $old_lock" >&2
  fi
fi

old_audit="${cache_dir}/audit-${old_id}"
new_audit="${cache_dir}/audit-${new_id}"
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
if [ -n "$current_branch" ] && [[ "$current_branch" =~ spec-0*${old_num}(-|$) ]]; then
  new_branch="${current_branch//spec-$(printf '%03d' "$old_num")/spec-$(printf '%03d' "$new_num")}"
  echo "  - Current branch '$current_branch' references $old_id."
  echo "    Rename:   git -C $repo_root branch -m '$new_branch'"
fi

echo "  - Commit-message history is immutable; past commits keep $old_id refs."
