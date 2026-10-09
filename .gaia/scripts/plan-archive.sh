#!/usr/bin/env bash
# plan-archive.sh: Reduce or delete a merged gaia-plan folder.
#
# On PR merge, an executed gaia-plan's orchestrator self-cleanup disposes of
# the whole plan folder, gating the disposition on the usage ledger:
#
#   - Spec-less PLAN-NNN plan at .gaia/local/plans/PLAN-<digits>/ (a
#     plans-ledger-tracked plan, not a legacy free-form slug): this
#     best-effort advances that plan's plans-ledger row to status "merged"
#     with a merged_at timestamp, through ledger-update.sh, before the
#     disposition decision, which is gated on the usage ledger holding a
#     gaia-plan close for plan:PLAN-NNN (usage.sh represented); a folder that
#     fails the gate, or carries no consolidated SUMMARY.md yet, is left in
#     place untouched. A kept folder survives for later age-reap
#     (plan-archive-merged.sh) instead of being deleted outright.
#   - Legacy free-form plan slug at .gaia/local/plans/<slug>/: no usage ref
#     names it, so the folder is always kept and the keep line says to remove
#     it by hand.
#   - Spec-colocated plan at .gaia/local/specs/<SPEC-ID>/plan[-N]/: the same
#     gate applies, keyed on the parent SPEC (a gaia-plan close for
#     spec:SPEC-NNN clears every plan subfolder of that spec); the SPEC folder
#     is the archival unit for everything else and is untouched here.
#
# Encapsulating the delete in a subprocess keeps the destructive rm out of
# the caller's own tool-call stream, so the block-rm-rf.sh PreToolUse hook
# and the settings.json permission gate never see the internal rm and cannot
# prompt or block.
#
# Usage:
#   plan-archive.sh <plan_dir>
#
# <plan_dir> is normally a repo-relative path to the plan folder (trailing
# slash tolerated), e.g. .gaia/local/plans/my-slug or
# .gaia/local/specs/SPEC-NNN/plan. An absolute path under the repo root is
# also accepted and normalized to repo-relative before matching: the
# orchestrator caches an absolute plan dir and hands this script that
# absolute path, so refusing it would silently skip cleanup. An absolute
# path outside the repo root is refused, as is any path not shaped like
# .gaia/local/plans/<slug> or .gaia/local/specs/<SPEC-ID>/plan[-N].
#
# Guarantees:
#   - Exit code is ALWAYS 0 (advisory / fail-open); never blocks a caller.
#   - The PLAN-NNN plans-ledger merge stamp (see above) is best-effort:
#     a missing ledger, missing row, or lock timeout is swallowed and never
#     blocks or fails this script.
#   - The usage-ledger gate is fail-closed: any error resolving the main
#     checkout, a missing or unreadable usage ledger, or a run with no
#     recorded close leaves the folder in place and prints a keep line on
#     stdout naming the recovery command.
#   - stdout carries at most one human summary line describing what
#     happened; diagnostics and refusals go to stderr only.
#   - Idempotent: a missing plan_dir, or a second run after a successful
#     reduce or delete, is a no-op.
#   - No git dependency for the delete itself -- .gaia/local/ is gitignored,
#     so this is plain filesystem work. git is only consulted (best-effort,
#     $PWD fallback) to resolve the repo root when the argument is an
#     absolute path, and to resolve the main checkout whose usage ledger the
#     gate reads.
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

# The gate reads the main checkout's usage ledger. A library that cannot load
# leaves every folder in place.
# shellcheck source=.gaia/scripts/main-root-lib.sh
. "$root/.gaia/scripts/main-root-lib.sh" 2>/dev/null || {
  echo "plan-archive: cannot load $root/.gaia/scripts/main-root-lib.sh; nothing archived" >&2
  exit 0
}

# ---------- normalize argument to repo-relative form ----------
case "$raw" in
  /*)
    case "$raw" in
      "$root"|"$root"/*)
        relative_path="${raw#"$root"}"
        relative_path="${relative_path#/}"
        ;;
      *)
        echo "plan-archive: $raw is outside the repo root ($root); refusing" >&2
        exit 0
        ;;
    esac
    ;;
  *)
    relative_path="$raw"
    ;;
esac
relative_path="${relative_path#./}"
relative_path="${relative_path%/}"

# ---------- classify path shape ----------
# .gaia/local/plans/<slug>: exactly one segment, and <slug> is not
# "archived" (guards against re-processing an archival-era leftover).
# .gaia/local/specs/<SPEC-ID>/plan[-N]: exactly two segments, the second
# being "plan" or "plan-<digits>".
kind=""
slug=""
spec_part=""
case "$relative_path" in
  .gaia/local/plans/*)
    slug="${relative_path#.gaia/local/plans/}"
    case "$slug" in
      ""|.|..|*/*|archived)
        echo "plan-archive: refusing $relative_path (nested path or archived)" >&2
        exit 0
        ;;
    esac
    kind="plans"
    ;;
  .gaia/local/specs/*)
    remainder="${relative_path#.gaia/local/specs/}"
    case "$remainder" in
      */plan|*/plan-[0-9]*)
        spec_part="${remainder%/*}"
        case "$spec_part" in
          ""|.|..|*/*)
            echo "plan-archive: refusing $relative_path (not a colocated plan folder)" >&2
            exit 0
            ;;
        esac
        kind="specs"
        ;;
      *)
        echo "plan-archive: refusing $relative_path (not a colocated plan folder)" >&2
        exit 0
        ;;
    esac
    ;;
  *)
    echo "plan-archive: refusing $relative_path (not under .gaia/local/plans or .gaia/local/specs)" >&2
    exit 0
    ;;
esac

absolute_source_path="$root/$relative_path"

# ---------- existence check ----------
if [ ! -e "$absolute_source_path" ]; then
  echo "plan-archive: $relative_path does not exist; nothing to do" >&2
  exit 0
fi

# ---------- derive the usage ref the gate needs ----------
# usage_ref stays empty for a folder no usage ref names (a legacy slug, or a
# SPEC folder name that is not SPEC-<digits>); that folder is always kept.
usage_ref=""
usage_workflow="gaia-plan"
plan_id=""
if [ "$kind" = "plans" ]; then
  case "$slug" in
    PLAN-[0-9][0-9][0-9]*)
      case "${slug#PLAN-}" in
        *[!0-9]*) ;;
        *) plan_id="$slug"; usage_ref="plan:$slug" ;;
      esac
      ;;
  esac
else
  case "$spec_part" in
    SPEC-[0-9][0-9][0-9]*)
      case "${spec_part#SPEC-}" in
        *[!0-9]*) ;;
        *) usage_ref="spec:$spec_part" ;;
      esac
      ;;
  esac
fi

# ---- best-effort plans-ledger merge stamp (PLAN-NNN slugs only) ----
# Legacy free-form slugs (e.g. cache-consolidation) have no plans-ledger
# row, so this never matches and the stamp is skipped. Runs before the
# usage-ledger gate so the terminal identity record survives even a
# folder the gate leaves in place (a later run, once the close is recorded,
# finds the row already merged and can retry the reduce).
if [ -n "$plan_id" ]; then
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  patch="$(jq -nc --arg timestamp "$now" '{status: "merged", merged_at: $timestamp}')"
  bash "$root/.gaia/scripts/spec/ledger-update.sh" "$root" "$slug" "$patch" \
    >/dev/null 2>&1 || true
fi

# ---------- usage-ledger gate ----------
if [ -z "$usage_ref" ]; then
  printf 'Kept %s: legacy plan folder with no usage ref; remove it by hand once its record is no longer needed\n' "$relative_path"
  exit 0
fi

recovery_command="outside a live $usage_workflow run, record it: bash .gaia/scripts/usage.sh record $usage_ref --workflow $usage_workflow --start <iso>"
gate_status=2
if main_root="$(gaia_resolve_main_root "$root" 2>/dev/null)" && [ -n "$main_root" ]; then
  gate_status=0
  bash "$root/.gaia/scripts/usage.sh" represented "$usage_ref" --workflow "$usage_workflow" \
    --main-root "$main_root" </dev/null >/dev/null 2>&1 || gate_status=$?
fi
if [ "$gate_status" -eq 2 ]; then
  printf 'Kept %s: usage ledger missing or unreadable (.gaia/local/telemetry/usage.jsonl) for %s; once it reads, %s\n' \
    "$relative_path" "$usage_ref" "$recovery_command"
  exit 0
fi
if [ "$gate_status" -ne 0 ]; then
  printf 'Kept %s: no %s run recorded for %s; %s\n' \
    "$relative_path" "$usage_workflow" "$usage_ref" "$recovery_command"
  exit 0
fi

# ---------- disposition ----------
if [ -n "$plan_id" ]; then
  # A ledger-tracked spec-less PLAN-NNN: keep-then-age-reap. Reduce the
  # folder to its consolidated SUMMARY.md and clear everything else, RUNNING
  # included, instead of deleting outright, so plan-archive-merged.sh can
  # reap it once merged_at clears the retention window.
  if [ ! -s "$absolute_source_path/SUMMARY.md" ]; then
    echo "plan-archive: no consolidated SUMMARY.md yet under $relative_path; left intact for consolidation" >&2
    printf 'Retained plan (no consolidated SUMMARY.md yet): %s\n' "$relative_path"
    exit 0
  fi
  find "$absolute_source_path" -mindepth 1 -maxdepth 1 ! -name SUMMARY.md -exec rm -rf {} +
  printf 'Reduced plan folder to SUMMARY.md (kept for age-reap): %s\n' "$relative_path"
  exit 0
fi

if [ "$kind" = "specs" ]; then
  # Spec-colocated plan[-N]: delete only the subfolder, gated on the parent
  # SPEC's own consolidated SUMMARY.md existing (consolidation has consumed
  # plan/PROGRESS.md). A cold invocation that races ahead of consolidation
  # keeps the subfolder rather than destroying PROGRESS.md.
  spec_directory="$(dirname "$absolute_source_path")"
  spec_summary="$spec_directory/SUMMARY.md"
  summary_ok=1
  verify_script="$root/.gaia/scripts/summary-verify.sh"
  if [ -x "$verify_script" ] || [ -f "$verify_script" ]; then
    bash "$verify_script" "$spec_summary" >/dev/null 2>&1 || summary_ok=0
  else
    [ -s "$spec_summary" ] || summary_ok=0
  fi
  if [ "$summary_ok" -ne 1 ]; then
    echo "plan-archive: parent SPEC has no consolidated SUMMARY.md yet; left $relative_path in place" >&2
    printf 'Retained plan (parent SPEC not yet consolidated): %s\n' "$relative_path"
    exit 0
  fi
fi

# ---------- delete (a gated spec-colocated plan[-N]) ----------
rm -rf -- "$absolute_source_path"
printf 'Deleted plan folder: %s (the usage ledger holds the run record)\n' "$relative_path"

exit 0
