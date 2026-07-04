#!/usr/bin/env bash
# spec-archive-merged.sh: Sweep merged-but-unarchived SPEC artifacts into
# .gaia/local/specs/archived/. Safety net for the /gaia-spec close flow.
#
# Why this exists: archiving normally happens through /gaia-spec close
# (spec-close.md), which fires on the wiki-promote immediate-merge path or by
# hand. But a PR can merge out-of-band (the github.com button, another
# session), and "Keep in place" leaves the folder where it is. Either way the
# SPEC folder lingers in the active specs dir forever. This pass is the sweep
# that catches them. It runs right after spec-reconcile.sh at /gaia-spec step 2:
# reconcile advances specified -> merged from git first, then this pass moves
# the now-merged folders into archived/.
#
# Sweep criteria, per SPEC: a .gaia/local/specs/ledger.json row is archived when ALL hold:
#   - row status == "merged"
#   - an active artifact folder exists at .gaia/local/specs/<id>/ (the folder
#     is the archival unit; siblings move with it)
#   - NO pending wiki-promote drain cache at
#     .gaia/local/cache/wiki-promote/<id>.json (those have not promoted their
#     wiki content yet; the close flow drains them, so leave them be)
# A merged row with no active folder (e.g. a pre-folder SPEC) is skipped.
#
# Mechanics mirror spec-close.md Step 4 (Archive): stamp the folder's SPEC.md
# frontmatter (status: archived, archived_at: <ISO 8601 UTC>; everything else,
# including immutable: true, preserved), then mv the folder under archived/.
# A spec_closed telemetry event (disposition: archive) is appended per
# spec-close.md Step 6. The ledger row is left at "merged": disposition lives
# on the artifact, not the ledger (wiki/concepts/GAIA Spec.md, "Ledger status
# vocabulary").
#
# Best-effort and fail-open by contract, exactly like spec-reconcile.sh: a
# missing jq / ledger, a frontmatter-edit failure, an already-occupied archive
# target, or a telemetry-append failure never blocks a caller. Archiving is
# reversible (mv the folder back), so the default is silent-but-logged: one
# stdout line summarizing what moved, diagnostics to stderr.
#
# Usage:
#   spec-archive-merged.sh <repo_root>
#
# Exit: always 0 (advisory).
set -uo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: spec-archive-merged.sh <repo_root>" >&2
  exit 0
fi

repo_root="${1%/}"
ledger_path="${repo_root}/.gaia/local/specs/ledger.json"
specs_dir="${repo_root}/.gaia/local/specs"
cache_dir="${repo_root}/.gaia/local/cache/wiki-promote"
telemetry_path="${repo_root}/.gaia/local/telemetry/spec-pacing.jsonl"

# No ledger or no jq → nothing to do. (No git needed: specs are local/gitignored,
# so the move is a plain filesystem mv, never git mv.)
[ -f "$ledger_path" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# Candidate rows (local, cheap): merged but possibly still in the active dir.
merged_ids="$(jq -r '.specs[] | select(.status == "merged") | .id' "$ledger_path" 2>/dev/null || true)"
[ -n "$merged_ids" ] || exit 0

now="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
archived_dir="${specs_dir}/archived"
archived_list=""

# Stamp the archive disposition into a SPEC.md frontmatter block in place.
# Sets status -> archived and archived_at -> $now, injecting either key if the
# closing fence is reached without it. Every other line (incl. immutable: true)
# is copied verbatim. A file with no frontmatter is passed through untouched.
# Prints the rewritten document to stdout; returns non-zero only on awk error.
_stamp_frontmatter() {
  awk -v ts="$now" '
    BEGIN { infm = 0; status_done = 0; archived_done = 0 }
    NR == 1 && $0 == "---" { infm = 1; print; next }
    infm == 1 && $0 == "---" {
      if (status_done == 0) print "status: archived"
      if (archived_done == 0) print "archived_at: " ts
      infm = 0
      print
      next
    }
    infm == 1 && $0 ~ /^status:/ { print "status: archived"; status_done = 1; next }
    infm == 1 && $0 ~ /^archived_at:/ { print "archived_at: " ts; archived_done = 1; next }
    { print }
  ' "$1"
}

while IFS= read -r spec_id; do
  [ -n "$spec_id" ] || continue

  folder="${specs_dir}/${spec_id}"
  # Skip merged rows with no active folder (already archived, or never had one).
  [ -d "$folder" ] || continue

  # Leave specs whose wiki content has not been promoted yet; the close flow
  # owns their drain + disposition.
  [ -f "${cache_dir}/${spec_id}.json" ] && continue

  # Reap the merged SPEC's cache keyset (gate1/draft/session/audit). Best-effort
  # and fail-open, matching the rest of this script's contract; never purges
  # wiki-promote/<id>.json (guarded above).
  local_cache="${repo_root}/.gaia/local/cache"
  rm -f "${local_cache}/gate1-${spec_id}.json" \
        "${local_cache}/draft-${spec_id}.md" \
        "${local_cache}/spec-session-${spec_id}.json" 2>/dev/null
  rm -rf "${local_cache}/audit-${spec_id}" 2>/dev/null

  target="${archived_dir}/${spec_id}"
  if [ -e "$target" ]; then
    # Both an active and an archived folder exist for the same id: never clobber.
    # Leave the active folder for a human to reconcile.
    echo "spec-archive-merged: $spec_id already has an archived folder at $target; left active folder in place" >&2
    continue
  fi

  spec_md="${folder}/SPEC.md"
  if [ -f "$spec_md" ]; then
    tmp="$(mktemp)"
    if _stamp_frontmatter "$spec_md" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
      mv "$tmp" "$spec_md"
    else
      rm -f "$tmp"
      echo "spec-archive-merged: $spec_id frontmatter stamp failed; left active folder in place" >&2
      continue
    fi
  fi

  mkdir -p "$archived_dir"
  if ! mv "$folder" "$target" 2>/dev/null; then
    echo "spec-archive-merged: $spec_id folder move failed; left active folder in place" >&2
    continue
  fi

  # Telemetry: mirror spec-close.md Step 6's spec_closed event. drained is
  # always false here (specs with a pending drain cache are skipped above).
  # Failure to append never blocks the sweep.
  if ev="$(jq -nc --arg id "$spec_id" --arg ts "$now" \
      '{event: "spec_closed", spec_id: $id, disposition: "archive", drained: false, ts: $ts}' 2>/dev/null)"; then
    mkdir -p "$(dirname "$telemetry_path")" 2>/dev/null || true
    printf '%s\n' "$ev" >> "$telemetry_path" 2>/dev/null || true
  fi

  archived_list="${archived_list:+$archived_list, }${spec_id}"
done <<EOF
$merged_ids
EOF

[ -n "$archived_list" ] || exit 0

count="$(printf '%s' "$archived_list" | awk -F', ' '{print NF}')"
printf 'Archived %s merged SPEC(s): %s\n' "$count" "$archived_list"

# Best-effort profile recompute, mirroring spec-close.md Step 6's chain. Guarded
# on the CLI existing (absent in hermetic tests and on minimal clones); it
# self-short-circuits when mentorship is disabled. Never blocks the sweep.
gaia_cli="${repo_root}/.gaia/cli/gaia"
if [ -x "$gaia_cli" ]; then
  "$gaia_cli" telemetry compute-profile >/dev/null 2>&1 || true
fi

exit 0
