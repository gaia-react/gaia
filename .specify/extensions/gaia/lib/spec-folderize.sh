#!/usr/bin/env bash
# spec-folderize.sh — Migrate flat SPEC artifacts into per-SPEC folders.
#
# A SPEC artifact lives at .gaia/local/specs/<spec_id>/SPEC.md (and, when
# archived, .gaia/local/specs/archived/<spec_id>/SPEC.md). This script moves
# any legacy flat .gaia/local/specs/SPEC-NNN.md (and archived/SPEC-NNN.md)
# into that folder shape. The folder is the archival unit — moving it carries
# all sibling artifacts (REPORT.md, evidence) with it.
#
# Usage:
#   spec-folderize.sh [--dry-run] [<repo_root>]
#
#   <repo_root>   defaults to `git rev-parse --show-toplevel`
#   --dry-run     print the planned moves to stdout, change nothing
#
# Behavior:
#   - Each flat regular file SPEC-NNN.md is moved to SPEC-NNN/SPEC.md.
#     `.gaia/local/specs/` and `.gaia/local/specs/archived/` are both scanned.
#   - Tracked files (git ls-files --error-unmatch) move with `git mv`;
#     untracked files (the common adopter case — specs are gitignored) move
#     with plain `mv`.
#   - Idempotent: a SPEC already at <id>/SPEC.md is skipped. Running twice is
#     a no-op. Contents are moved byte-for-byte; no frontmatter edits.
#   - Stdout carries only the dry-run plan; all diagnostics go to stderr.
#
# Exit codes:
#   0  ok, or no-op (already foldered / nothing to migrate / --dry-run)
#   2  usage error
#   3  repo root not resolvable
#   4  migration conflict (both flat SPEC-<id>.md and folder <id>/SPEC.md
#      exist for the same id — never guess, never overwrite)
#
# macOS-first: no GNU coreutils assumptions.
set -euo pipefail

dry_run=0
repo_root=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      dry_run=1
      shift
      ;;
    --*)
      echo "spec-folderize: unknown option '$1'" >&2
      echo "usage: spec-folderize.sh [--dry-run] [<repo_root>]" >&2
      exit 2
      ;;
    *)
      if [ -n "$repo_root" ]; then
        echo "spec-folderize: unexpected extra argument '$1'" >&2
        echo "usage: spec-folderize.sh [--dry-run] [<repo_root>]" >&2
        exit 2
      fi
      repo_root="$1"
      shift
      ;;
  esac
done

if [ -z "$repo_root" ]; then
  if ! repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    echo "spec-folderize: cannot resolve repo root (not in a git work tree); pass <repo_root>" >&2
    exit 3
  fi
fi

if [ ! -d "$repo_root" ]; then
  echo "spec-folderize: repo root '$repo_root' is not a directory" >&2
  exit 3
fi

repo_root="${repo_root%/}"
specs_dir="${repo_root}/.gaia/local/specs"

# Resolve once whether we are inside a git work tree rooted at (or above)
# repo_root; only then is per-file tracked detection / `git mv` meaningful.
in_git_tree=0
if git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  in_git_tree=1
fi

moved=0
planned=0

# Migrate every flat SPEC-NNN.md regular file directly under $1 into
# $1/SPEC-NNN/SPEC.md. $1 is either the specs dir or its archived/ subdir.
folderize_dir() {
  local dir="$1"
  [ -d "$dir" ] || return 0

  local flat id folder target
  for flat in "$dir"/SPEC-*.md; do
    # No glob match → bash leaves the pattern literal; skip it.
    [ -e "$flat" ] || continue
    # Only flat regular files are migration candidates.
    [ -f "$flat" ] || continue

    id="$(basename "$flat" .md)"
    folder="$dir/$id"
    target="$folder/SPEC.md"

    if [ -e "$target" ]; then
      echo "spec-folderize: conflict — both flat and foldered artifact exist for $id:" >&2
      echo "  flat:   $flat" >&2
      echo "  folder: $target" >&2
      exit 4
    fi

    if [ "$dry_run" -eq 1 ]; then
      echo "mv $flat $target"
      planned=$((planned + 1))
      continue
    fi

    mkdir -p "$folder"
    if [ "$in_git_tree" -eq 1 ] && git -C "$repo_root" ls-files --error-unmatch "$flat" >/dev/null 2>&1; then
      git -C "$repo_root" mv "$flat" "$target"
    else
      mv "$flat" "$target"
    fi
    moved=$((moved + 1))
  done
}

folderize_dir "$specs_dir"
folderize_dir "$specs_dir/archived"

if [ "$dry_run" -eq 1 ]; then
  if [ "$planned" -eq 0 ]; then
    echo "spec-folderize: nothing to migrate (no flat SPEC files)" >&2
  fi
  exit 0
fi

if [ "$moved" -eq 0 ]; then
  echo "spec-folderize: nothing to migrate (no flat SPEC files)" >&2
  exit 0
fi

echo "spec-folderize: migrated $moved SPEC artifact(s) into per-SPEC folders" >&2
exit 0
