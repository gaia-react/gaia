#!/usr/bin/env bash
# gauge.sh: deterministic pre-flight depth gauge for the Comprehensive Audit
# phase of /health-audit. Decides how deep the audit goes -- skip, scoped, or
# full -- from the diff since the last release tag, before any specialist
# lens is dispatched. Running it twice against the same unchanged tree must
# yield byte-identical depth/lens output, which is why this is a deterministic
# script and not an LLM prose protocol.
#
# Usage: bash .gaia/cli/health/comprehensive/gauge.sh [--comprehensive-full] [--major]
#
#   --comprehensive-full  force depth=full, source=force-flag (overrides the diff)
#   --major                explicit major-release intent -> depth=full, source=major
#
# Writes .gaia/local/audit/comprehensive/gauge.json (creating the dir first),
# echoes a one-line summary to stdout (`depth=<d> lenses=<csv> source=<s>`),
# and exits 0. Reads/writes nothing outside .gaia/local/audit/comprehensive/;
# makes no network calls. Runs from the repo root (the caller's cwd); every
# path below is repo-relative.
#
# Sibling bats suite: .gaia/scripts/tests/comprehensive-gauge.bats.

set -euo pipefail

readonly COMPREHENSIVE_FULL_CHURN_FILES=150
readonly GAUGE_OUT_DIR=".gaia/local/audit/comprehensive"
readonly GAUGE_OUT="$GAUGE_OUT_DIR/gauge.json"

force_full=false
major_flag=false
for arg in "$@"; do
  case "$arg" in
    --comprehensive-full) force_full=true ;;
    --major) major_flag=true ;;
  esac
done

# ---------- Baseline resolution ----------
# --match 'v*' keeps the baseline provably a release tag: coexisting spec/*
# tags point at tree objects and must not be selected.
TAG="$(git describe --tags --match 'v*' --abbrev=0 2>/dev/null || true)"

# ---------- Diff surface + churn ----------
# The whole .gaia framework tree (not just cli/scripts) so the path-to-lens
# table's .gaia/** (all other) -> TIDY row is a reachable partition member.
# The manifest is release-generated (an audit target, not a change trigger);
# .gaia/local is gitignored but excluded defensively.
changed_files=()
churn_files=0
if [ -n "$TAG" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] && changed_files+=("$f")
  done < <(git diff --name-only "$TAG"..HEAD -M -- \
    .claude .gaia .specify/extensions/gaia \
    ':!.gaia/manifest.json' ':!.gaia/local')
  churn_files=${#changed_files[@]}
fi

# ---------- Path -> lens classification (most-specific glob wins) ----------
classify_lens() {
  case "$1" in
    .claude/commands/health-audit.md|.gaia/cli/health/*) echo "SELF" ;;
    .claude/*) echo "FEAT" ;;
    .gaia/cli/*|.gaia/scripts/*|.specify/extensions/gaia/*) echo "DIST" ;;
    .gaia/*) echo "TIDY" ;;
    *) echo "" ;;
  esac
}

hit_feat=false
hit_dist=false
hit_tidy=false
hit_self=false
for f in ${changed_files[@]+"${changed_files[@]}"}; do
  case "$(classify_lens "$f")" in
    SELF) hit_self=true ;;
    FEAT) hit_feat=true ;;
    DIST) hit_dist=true ;;
    TIDY) hit_tidy=true ;;
  esac
done

# Canonical order FEAT,DIST,TIDY,SELF -- byte-identical output across runs.
scoped_lenses=()
[ "$hit_feat" = true ] && scoped_lenses+=("FEAT")
[ "$hit_dist" = true ] && scoped_lenses+=("DIST")
[ "$hit_tidy" = true ] && scoped_lenses+=("TIDY")
[ "$hit_self" = true ] && scoped_lenses+=("SELF")

# ---------- Depth decision (first match wins) ----------
full_lenses='["FEAT","DIST","TIDY","SELF"]'

if [ "$force_full" = true ]; then
  depth=full; src=force-flag; lenses_json="$full_lenses"
  rationale="--comprehensive-full forces full"
elif [ -z "$TAG" ]; then
  depth=full; src=no-tag; lenses_json="$full_lenses"
  rationale="no resolvable last-release tag; defaulting to full"
elif [ "$major_flag" = true ]; then
  depth=full; src=major; lenses_json="$full_lenses"
  rationale="explicit major-release intent"
elif [ "$churn_files" -gt "$COMPREHENSIVE_FULL_CHURN_FILES" ]; then
  depth=full; src=churn; lenses_json="$full_lenses"
  rationale="$churn_files framework files changed since $TAG (> $COMPREHENSIVE_FULL_CHURN_FILES threshold)"
elif [ "$churn_files" -eq 0 ]; then
  # `src` is quoted here (unlike its bare siblings above) because `diff` is also a
  # command name, which trips SC2209's "did you mean src=$(diff)" heuristic.
  depth=skip; src="diff"; lenses_json="[]"
  rationale="no framework-facing changes since $TAG"
else
  depth=scoped; src="diff"
  lenses_json="$(jq -nc '$ARGS.positional' --args ${scoped_lenses[@]+"${scoped_lenses[@]}"})"
  lens_csv="$(IFS=,; echo "${scoped_lenses[*]}")"
  rationale="$churn_files framework file(s) changed since $TAG; scoped to $lens_csv"
fi

# ---------- Write gauge.json (FROZEN schema; jq -n, never string interpolation) ----------
mkdir -p "$GAUGE_OUT_DIR"
jq -n \
  --arg depth "$depth" \
  --argjson lenses "$lenses_json" \
  --arg source "$src" \
  --arg rationale "$rationale" \
  --arg baseline_tag "$TAG" \
  --argjson churn_files "$churn_files" \
  '{depth: $depth, lenses: $lenses, source: $source, rationale: $rationale, baseline_tag: $baseline_tag, churn_files: $churn_files}' \
  > "$GAUGE_OUT"

# ---------- Stdout summary ----------
case "$depth" in
  full) summary_lenses="FEAT,DIST,TIDY,SELF" ;;
  skip) summary_lenses="" ;;
  scoped) summary_lenses="$(IFS=,; echo "${scoped_lenses[*]}")" ;;
esac
echo "depth=$depth lenses=$summary_lenses source=$src"
