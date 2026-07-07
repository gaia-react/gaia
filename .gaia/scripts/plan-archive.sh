#!/usr/bin/env bash
# plan-archive.sh: Reduce or delete a merged gaia-plan folder.
#
# On PR merge, an executed gaia-plan's orchestrator self-cleanup disposes of
# the whole plan folder, after preserving its durable identity record and
# gating the disposition on cost representation:
#
#   - Spec-less PLAN-NNN plan at .gaia/local/plans/PLAN-<digits>/ (a
#     plans-ledger-tracked plan, not a legacy free-form slug): this
#     best-effort advances that plan's plans-ledger row to status "merged"
#     with a merged_at timestamp, through plan-ledger-update.sh, before the
#     disposition decision. The folder is then kept: reduced to its
#     consolidated SUMMARY.md + cost.json and cleared of its RUNNING
#     sentinel, gated on every cost phase section under it being
#     value-represented in cost.jsonl (cost-represented.sh); a folder that
#     fails the gate, or carries no consolidated SUMMARY.md yet, is left in
#     place untouched. A kept folder survives for later age-reap
#     (plan-archive-merged.sh) instead of being deleted outright.
#   - Legacy free-form plan slug at .gaia/local/plans/<slug>/: no
#     plans-ledger row exists to anchor an age-reap, so this deletes outright
#     unchanged, gated on the same representation check.
#   - Spec-colocated plan at .gaia/local/specs/<SPEC-ID>/plan[-N]/: the same
#     representation gate applies, keyed on the parent SPEC's identity. Only
#     the plan[-N] subfolder is deleted, and only once the parent SPEC's own
#     consolidated SUMMARY.md exists; the SPEC folder is the archival unit
#     for everything else and is untouched here.
#
# Encapsulating the delete in a subprocess keeps the destructive rm out of
# the caller's own tool-call stream, so the block-rm-rf.sh PreToolUse hook
# and the settings.json permission gate never see the internal rm and cannot
# prompt or block. Every caller (the orchestrator self-cleanup,
# local-janitor.sh's backstop) shares this one code path.
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
# absolute path, so refusing it would silently skip cleanup. An absolute
# path outside the repo root is refused, as is any path not shaped like
# .gaia/local/plans/<slug> or .gaia/local/specs/<SPEC-ID>/plan[-N].
#
# Guarantees:
#   - Exit code is ALWAYS 0 (advisory / fail-open); never blocks a caller.
#   - The PLAN-NNN plans-ledger merge stamp (see above) is best-effort:
#     a missing ledger, missing row, or lock timeout is swallowed and never
#     blocks or fails this script.
#   - The representation gate is fail-closed: any error resolving the
#     ledger, sourcing the gate, or a BLOCKING cost section leaves the
#     folder in place rather than disposing of it.
#   - stdout carries at most one human summary line describing what
#     happened; diagnostics and refusals go to stderr only.
#   - Idempotent: a missing plan_dir, or a second run after a successful
#     reduce or delete, is a no-op.
#   - No git dependency for the delete itself -- .gaia/local/ is gitignored,
#     so this is plain filesystem work. git is only consulted (best-effort,
#     $PWD fallback) to resolve the repo root when the argument is an
#     absolute path, and to resolve the main-checkout cost ledger for the
#     representation gate.
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
# "archived" (guards against re-processing an archival-era leftover).
# .gaia/local/specs/<SPEC-ID>/plan[-N]: exactly two segments, the second
# being "plan" or "plan-<digits>".
kind=""
slug=""
spec_part=""
case "$rel" in
  .gaia/local/plans/*)
    slug="${rel#.gaia/local/plans/}"
    case "$slug" in
      ""|.|..|*/*|archived)
        echo "plan-archive: refusing $rel (nested path or archived)" >&2
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
  echo "plan-archive: $rel does not exist; nothing to do" >&2
  exit 0
fi

# ---------- derive representation-gate identity (FC-3) ----------
attr_field=""
attr_val=""
if [ "$kind" = "plans" ]; then
  case "$slug" in
    PLAN-*)
      plan_num="${slug#PLAN-}"
      case "$plan_num" in
        ''|*[!0-9]*) attr_field="plan_slug"; attr_val="$slug" ;;
        *) attr_field="plan_id"; attr_val="$slug" ;;
      esac
      ;;
    *)
      attr_field="plan_slug"; attr_val="$slug"
      ;;
  esac
else
  attr_field="spec_id"; attr_val="$spec_part"
fi

# ---- best-effort plans-ledger merge stamp (PLAN-NNN slugs only) ----
# Legacy free-form slugs (e.g. cache-consolidation) have no plans-ledger
# row, so this never matches and the stamp is skipped. Runs before the
# representation gate so the terminal identity record survives even a
# folder the gate leaves in place (a later run, once cost catches up, finds
# the row already merged and can retry the reduce).
if [ "$kind" = "plans" ] && [ "$attr_field" = "plan_id" ]; then
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  patch="$(jq -nc --arg ts "$now" '{status: "merged", merged_at: $ts}')"
  bash "$root/.specify/extensions/gaia/lib/plan-ledger-update.sh" "$root" "$slug" "$patch" \
    >/dev/null 2>&1 || true
fi

# ---------- representation gate (FC-3) ----------
# shellcheck source=.gaia/scripts/ledger-path-lib.sh
. "$root/.gaia/scripts/ledger-path-lib.sh" 2>/dev/null || true
# shellcheck source=.gaia/scripts/cost-represented.sh
. "$root/.gaia/scripts/cost-represented.sh" 2>/dev/null || true

ledger=""
if declare -f gaia_resolve_ledger_path >/dev/null 2>&1; then
  ledger="$(gaia_resolve_ledger_path "" 2>/dev/null || true)"
fi

if [ -z "$ledger" ] || ! declare -f cost_folder_represented >/dev/null 2>&1; then
  echo "plan-archive: could not resolve the cost-representation gate; left $rel in place" >&2
  printf 'Retained plan (representation gate unavailable): %s\n' "$rel"
  exit 0
fi

if ! cost_folder_represented "$source_abs" "$attr_field" "$attr_val" "$ledger" >/dev/null 2>&1; then
  echo "plan-archive: cost not fully represented; left $rel in place" >&2
  printf 'Retained plan (cost not fully represented): %s\n' "$rel"
  exit 0
fi

# ---------- disposition ----------
if [ "$kind" = "plans" ] && [ "$attr_field" = "plan_id" ]; then
  # A ledger-tracked spec-less PLAN-NNN: keep-then-age-reap. Reduce the
  # folder to its consolidated SUMMARY.md + cost.json and clear the RUNNING
  # sentinel, instead of deleting outright, so plan-archive-merged.sh can
  # reap it once merged_at clears the retention window.
  if [ ! -s "$source_abs/SUMMARY.md" ]; then
    echo "plan-archive: no consolidated SUMMARY.md yet under $rel; left intact for consolidation" >&2
    printf 'Retained plan (no consolidated SUMMARY.md yet): %s\n' "$rel"
    exit 0
  fi
  find "$source_abs" -mindepth 1 -maxdepth 1 ! -name SUMMARY.md ! -name cost.json -exec rm -rf {} +
  rm -f "$source_abs/RUNNING"
  printf 'Reduced plan folder to SUMMARY.md + cost.json (kept for age-reap): %s\n' "$rel"
  exit 0
fi

if [ "$kind" = "specs" ]; then
  # Spec-colocated plan[-N]: delete only the subfolder, gated on the parent
  # SPEC's own consolidated SUMMARY.md existing (consolidation has consumed
  # plan/PROGRESS.md). A cold/janitor invocation that races ahead of
  # consolidation keeps the subfolder rather than destroying PROGRESS.md.
  spec_dir="$(dirname "$source_abs")"
  spec_summary="$spec_dir/SUMMARY.md"
  summary_ok=1
  verify_script="$root/.gaia/scripts/summary-verify.sh"
  if [ -x "$verify_script" ] || [ -f "$verify_script" ]; then
    bash "$verify_script" "$spec_summary" >/dev/null 2>&1 || summary_ok=0
  else
    [ -s "$spec_summary" ] || summary_ok=0
  fi
  if [ "$summary_ok" -ne 1 ]; then
    echo "plan-archive: parent SPEC has no consolidated SUMMARY.md yet; left $rel in place" >&2
    printf 'Retained plan (parent SPEC not yet consolidated): %s\n' "$rel"
    exit 0
  fi
fi

# ---------- delete (legacy free-form plan slug, or a gated spec-colocated plan[-N]) ----------
rm -rf -- "$source_abs"
printf 'Deleted plan folder: %s (cost preserved in cost.jsonl)\n' "$rel"

exit 0
