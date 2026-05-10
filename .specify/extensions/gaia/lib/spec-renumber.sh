#!/usr/bin/env bash
# spec-renumber.sh — Renumber a SPEC. Renames the local SPEC file, updates its
# frontmatter, and rewrites the .gaia/specs.json ledger row. Does NOT touch
# external state (branch names, GH issue titles, commit-message history) — those
# are reported as next steps for the caller to handle consciously.
#
# Usage:
#   spec-renumber.sh <repo_root> <old_id> <new_id>
#
# Refuses if:
#   - repo_root is not a git working tree
#   - old/new id is not in SPEC-NNN form
#   - old SPEC file is missing
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
ledger_path="${repo_root%/}/.gaia/specs.json"
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

old_path="${specs_dir}/${old_id}.md"
new_path="${specs_dir}/${new_id}.md"

if [ ! -f "$old_path" ]; then
  echo "spec-renumber: source SPEC file not found at $old_path" >&2
  exit 4
fi

if [ -e "$new_path" ]; then
  echo "spec-renumber: target file $new_path already exists" >&2
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
      find "$specs_dir" -maxdepth 1 -type f -name 'SPEC-*.md' -print 2>/dev/null \
        | sed -nE 's|.*/SPEC-0*([0-9]+)\.md$|\1|p' || true
    )
  fi
fi

# 1. Move the file.
mv "$old_path" "$new_path"

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
' "$new_path" > "$tmp_spec"
mv "$tmp_spec" "$new_path"

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
    echo "spec-renumber: failed to update ledger; reverting file move" >&2
    mv "$new_path" "$old_path"
    exit 5
  fi
fi

echo "renumbered $old_id → $new_id"
echo
echo "Next steps (external state — not auto-updated):"

# Branch name — flag if the current branch references the old id.
current_branch="$(git -C "$repo_root" symbolic-ref --short -q HEAD || true)"
if [ -n "$current_branch" ] && [[ "$current_branch" =~ spec-0*${old_num}(-|$) ]]; then
  new_branch="${current_branch//spec-$(printf '%03d' "$old_num")/spec-$(printf '%03d' "$new_num")}"
  echo "  - Current branch '$current_branch' references $old_id."
  echo "    Rename:   git -C $repo_root branch -m '$new_branch'"
fi

# GH issue title — flag if the SPEC frontmatter has a stamped issue url.
issue_url="$(awk '/^---[[:space:]]*$/{c++; if(c==2)exit} /^gh_issue_url:/{sub(/^gh_issue_url:[[:space:]]*/,""); print}' "$new_path" || true)"
if [ -n "$issue_url" ]; then
  echo "  - GH issue $issue_url was titled with $old_id."
  echo "    Update:   gh issue edit <number> --title '$new_id: <intent>'"
fi

echo "  - Commit-message history is immutable — past commits keep $old_id refs."
