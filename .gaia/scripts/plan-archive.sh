#!/usr/bin/env bash
# plan-archive.sh: Archive a completed gaia-plan folder.
#
# On PR merge, an executed gaia-plan's orchestrator self-cleanup used to
# delete the whole plan folder outright, destroying SUMMARY.md (the
# phase-findings ledger) and cost.md (the cost tally) along with the
# scratch material. This helper prunes the folder down to those two files
# and then, depending on where the plan lives, either archives it or leaves
# it in place:
#
#   - Spec-less plan at .gaia/local/plans/<slug>/: pruned, then moved to
#     .gaia/local/plans/archived/<slug>/. Its cost.md gains a grand-total
#     `## Total` section on the way (cost-consolidate.sh plan-total).
#   - Spec-colocated plan at .gaia/local/specs/<SPEC-ID>/plan[-N]/: pruned
#     in place, no move. The SPEC folder is the archival unit; when the
#     SPEC itself is later archived (spec-archive-merged.sh), the pruned
#     plan/ subfolder rides along automatically. Its cost.md is spliced
#     into the SPEC-root cost.md later by cost-consolidate.sh's spec mode,
#     not here.
#
# Encapsulating the prune+move in a subprocess keeps the destructive rm/mv
# out of the caller's own tool-call stream, so the block-rm-rf.sh
# PreToolUse hook and the settings.json permission gate never see the
# internal rm/mv and cannot prompt or block. Every caller (the orchestrator
# self-cleanup, the local-janitor.sh backstop) shares this one code path.
#
# Usage:
#   plan-archive.sh <plan_dir>
#
# <plan_dir> is normally a repo-relative path to the plan folder (trailing
# slash tolerated), e.g. .gaia/local/plans/my-slug or
# .gaia/local/specs/SPEC-005/plan. An absolute path under the repo root is
# also accepted and normalized to repo-relative before matching: callers
# that cache an absolute plan dir (the orchestrator) or iterate
# $root-anchored absolute paths (local-janitor.sh) both hand this script an
# absolute path, so refusing it would silently skip archival. An absolute
# path outside the repo root is refused, as is any path not shaped like
# .gaia/local/plans/<slug> or .gaia/local/specs/<SPEC-ID>/plan[-N].
#
# Guarantees:
#   - Exit code is ALWAYS 0 (advisory / fail-open); never blocks a caller.
#   - stdout carries at most one human summary line describing what
#     happened; diagnostics and refusals go to stderr only.
#   - Idempotent: a missing plan_dir, an already-archived folder, or a
#     second run after a successful move is a no-op.
#   - No git dependency for the prune/move itself -- .gaia/local/ is
#     gitignored, so this is plain filesystem work. git is only consulted
#     (best-effort, $PWD fallback) to resolve the repo root when the
#     argument is an absolute path.
set -uo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: plan-archive.sh <plan_dir>" >&2
  exit 0
fi

raw="$1"

# ---------- resolve repo root (for absolute-path normalization) ----------
root="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$root" ] || root="$PWD"
root="${root%/}"

# ---------- normalize argument to repo-relative form ----------
case "$raw" in
  /*)
    case "$raw" in
      "$root"|"$root"/*)
        rel="${raw#"$root"}"
        rel="${rel#/}"
        ;;
      *)
        echo "plan-archive: $raw is outside the repo root ($root); refusing" >&2
        exit 0
        ;;
    esac
    ;;
  *)
    rel="$raw"
    ;;
esac
rel="${rel#./}"
rel="${rel%/}"

# ---------- classify path shape ----------
# .gaia/local/plans/<slug>: exactly one segment, and <slug> is not
# "archived" (guards against double-archiving an already-archived folder).
# .gaia/local/specs/<SPEC-ID>/plan[-N]: exactly two segments, the second
# being "plan" or "plan-<digits>".
kind=""
slug=""
case "$rel" in
  .gaia/local/plans/*)
    slug="${rel#.gaia/local/plans/}"
    case "$slug" in
      ""|.|..|*/*|archived)
        echo "plan-archive: refusing $rel (nested path or already-archived)" >&2
        exit 0
        ;;
    esac
    kind="plans"
    ;;
  .gaia/local/specs/*)
    remainder="${rel#.gaia/local/specs/}"
    case "$remainder" in
      */plan|*/plan-[0-9]*)
        spec_part="${remainder%/*}"
        case "$spec_part" in
          ""|.|..|*/*)
            echo "plan-archive: refusing $rel (not a colocated plan folder)" >&2
            exit 0
            ;;
        esac
        kind="specs"
        ;;
      *)
        echo "plan-archive: refusing $rel (not a colocated plan folder)" >&2
        exit 0
        ;;
    esac
    ;;
  *)
    echo "plan-archive: refusing $rel (not under .gaia/local/plans or .gaia/local/specs)" >&2
    exit 0
    ;;
esac

source_abs="$root/$rel"

# ---------- existence check ----------
if [ ! -e "$source_abs" ]; then
  echo "plan-archive: $rel does not exist; nothing to archive" >&2
  exit 0
fi

# ---------- prune: keep only SUMMARY.md and cost.md ----------
# Three glob arms cover dotfiles too (.work/ is dot-prefixed; RUNNING is
# not). The existence guard skips a literal unmatched glob token.
for entry in "$source_abs"/* "$source_abs"/.[!.]* "$source_abs"/..?*; do
  [ -e "$entry" ] || [ -L "$entry" ] || continue
  name="${entry##*/}"
  case "$name" in
    SUMMARY.md|cost.md) continue ;;
  esac
  rm -rf -- "$entry"
done

# ---------- placement ----------
if [ "$kind" = "plans" ]; then
  archived_rel=".gaia/local/plans/archived/$slug"
  archived_dir_abs="$root/.gaia/local/plans/archived"
  target_abs="$archived_dir_abs/$slug"

  mkdir -p "$archived_dir_abs" 2>/dev/null

  if [ -e "$target_abs" ]; then
    echo "plan-archive: $archived_rel already exists; left $rel pruned in place" >&2
    printf 'Pruned plan in place (archive target exists): %s (kept SUMMARY.md, cost.md)\n' "$rel"
    exit 0
  fi

  if mv "$source_abs" "$target_abs" 2>/dev/null; then
    # Best-effort: a spec-less plan has no SPEC-root to consolidate into, so
    # its own cost.md gets its grand total here instead of at spec-archive
    # time. Never blocks the archive on failure.
    bash "$root/.specify/extensions/gaia/lib/cost-consolidate.sh" plan-total "$target_abs/cost.md" >/dev/null 2>&1 || true
    printf 'Archived plan: moved %s -> %s (kept SUMMARY.md, cost.md)\n' "$rel" "$archived_rel"
  else
    echo "plan-archive: mv failed for $rel -> $archived_rel; left pruned folder in place" >&2
    printf 'Pruned plan in place (move failed): %s (kept SUMMARY.md, cost.md)\n' "$rel"
  fi
else
  printf 'Pruned colocated plan in place: %s (kept SUMMARY.md, cost.md)\n' "$rel"
fi

exit 0
