#!/usr/bin/env bash
# plan-resume-point.sh: Deterministic phase-level resume-point helper.
#
# A GAIA plan runs as a sequence of git-committed phases driven by a
# cold-startable orchestrator. On a cold restart (crash, context compaction,
# deliberate HALT) the orchestrator needs to know which phases are genuinely
# committed rather than re-running everything from Phase 1. This helper reads
# the plan's append-only PROGRESS.md ledger (falling back to a legacy live
# SUMMARY.md when PROGRESS.md is absent) and, for each phase, proves
# whether that phase's recorded commit is a genuine ancestor of the
# reconnected branch's HEAD. Git is the arbiter -- a ledger block is only a
# hint. On any ambiguity (missing block, unparseable SHA, non-existent SHA,
# unresolvable git context) this biases to re-run: it reports the phase
# incomplete, because re-running a phase that was in fact complete is merely
# wasteful, while skipping a phase that was not actually committed would
# silently drop real work.
#
# Usage:
#   plan-resume-point.sh --plan-dir <path> [--phases <M>] [--branch <ref>] \
#     [--git-dir <path>]
#
#   --plan-dir <path>  Directory holding PROGRESS.md (or a legacy live
#                       SUMMARY.md). Locates the ledger only; it is NOT the
#                       git context.
#   --phases <M>       Optional positive integer, the plan's total phase
#                       count. Present: the helper may echo M+1 to signal
#                       all-complete. Omitted (or not a positive integer):
#                       the helper never asserts all-complete; it echoes
#                       only the first gap beyond the recorded ledger
#                       blocks.
#   --branch <ref>     Git ref whose HEAD ancestry is checked against.
#                       Default HEAD.
#   --git-dir <path>   Directory to run git in (git -C <path>). Default:
#                       the current working directory. This decouples the
#                       git context (the reconnected worktree, where the
#                       commits live) from --plan-dir (the main checkout,
#                       where the plan folder lives).
#   Unknown flags are tolerated and ignored; never fatal.
#
# stdout (frozen):
#   <resume-point>              line 1: a bare integer, ALWAYS present
#   COMPLETE <n> <short-sha>    zero or more, ascending n, one per
#                                verified-complete phase
#
# Verified-complete phases are exactly 1 .. (resume-point - 1), contiguous.
# No other stdout; diagnostics (if any) go to stderr only.
#
# PROGRESS.md block format read (delimiter-agnostic, number-bounded,
# last-block-wins):
#   ## Phase <N>, <title>
#   Commit: <short-sha>
#
#   <notes...>
#
# Guarantees:
#   - Exit code is ALWAYS 0.
#   - Sources no sibling files; standalone so tests can invoke it directly
#     with --git-dir/--plan-dir pointing at fixtures.
set -uo pipefail

PLAN_DIR=""
PHASES=""
BRANCH="HEAD"
GIT_DIR="."

# ---------- parse args (unknown flags tolerated, never fatal) ----------
while [ "$#" -gt 0 ]; do
  case "$1" in
    --plan-dir|--phases|--branch|--git-dir)
      flag="$1"
      if [ "$#" -ge 2 ]; then
        val="$2"
        shift 2
      else
        val=""
        shift 1
      fi
      case "$flag" in
        --plan-dir) PLAN_DIR="$val" ;;
        --phases) PHASES="$val" ;;
        --branch) BRANCH="$val" ;;
        --git-dir) GIT_DIR="$val" ;;
      esac
      ;;
    *)
      shift 1
      ;;
  esac
done

# ---------- git ancestry check: git is the arbiter ----------
# Any non-zero result (not-an-ancestor, bad/non-existent object, unresolvable
# git context) reads as incomplete; only exit 0 counts as verified-complete.
_is_ancestor() {
  local sha="$1" ref="$2"
  [ -n "$sha" ] || return 1
  git -C "$GIT_DIR" merge-base --is-ancestor "$sha" "$ref" >/dev/null 2>&1
}

# ---------- last-block-wins Commit: anchor extraction for phase $1 ----------
# Number-bounded ("## Phase 3" never matches "## Phase 30") and
# delimiter-agnostic (comma, dash, space, paren, or EOL all terminate the
# number). The Commit: anchor is the first non-blank content line under the
# heading; a non-Commit first content line (an anchor-less/legacy block, or
# a HALTED block) leaves the anchor empty for that occurrence. Each matching
# heading resets the anchor, so the LAST occurrence of "## Phase <N>" wins.
_commit_anchor() {
  local want="$1"
  awk -v want="$want" '
    {
      is_phase_heading = 0
      if ($0 ~ /^## Phase [0-9]+/) {
        hn = $0
        sub(/^## Phase /, "", hn)
        sub(/[^0-9].*$/, "", hn)
        is_phase_heading = 1
      }
    }
    is_phase_heading {
      if (hn + 0 == want) { inblk = 1; firstcontent = 1; sha = ""; next }
      else               { inblk = 0; next }
    }
    /^## / { inblk = 0 }
    inblk && firstcontent {
      if ($0 ~ /^[[:space:]]*$/) next
      firstcontent = 0
      if ($0 ~ /^Commit:[[:space:]]*/) {
        line = $0
        sub(/^Commit:[[:space:]]*/, "", line)
        split(line, a, /[[:space:]]/)
        sha = a[1]
      }
    }
    END { print sha }
  ' "$ledger"
}

# ---------- locate the ledger ----------
# PROGRESS.md is the live ledger. A legacy live SUMMARY.md (pre-rename
# format) is a fallback ONLY for a plan running across the rename boundary;
# once PROGRESS.md exists it always wins.
ledger=""
if [ -n "$PLAN_DIR" ]; then
  if [ -s "$PLAN_DIR/PROGRESS.md" ]; then
    ledger="$PLAN_DIR/PROGRESS.md"
  elif [ -s "$PLAN_DIR/SUMMARY.md" ]; then
    ledger="$PLAN_DIR/SUMMARY.md"
  fi
fi

if [ -z "$ledger" ] || [ ! -s "$ledger" ]; then
  echo 1
  exit 0
fi

# ---------- resolve the upper bound ----------
# --phases wins when it is a positive integer; a non-integer (or absent)
# degrades to the recorded-blocks bound, which never asserts all-complete.
phases_valid=0
upper_from_phases=0
case "$PHASES" in
  ''|*[!0-9]*) : ;;
  *)
    upper_from_phases=$((10#$PHASES))
    if [ "$upper_from_phases" -gt 0 ]; then
      phases_valid=1
    fi
    ;;
esac

if [ "$phases_valid" = "1" ]; then
  upper="$upper_from_phases"
else
  recorded_max="$(awk '
    /^## Phase [0-9]+/ {
      hn = $0
      sub(/^## Phase /, "", hn)
      sub(/[^0-9].*$/, "", hn)
      if (hn + 0 > max) max = hn + 0
    }
    END { print max + 0 }
  ' "$ledger")"
  [ -n "$recorded_max" ] || recorded_max=0
  upper="$recorded_max"
fi

# ---------- walk phases 1..upper, first gap caps the resume point ----------
resume=$((upper + 1))
complete_lines=""
n=1
while [ "$n" -le "$upper" ]; do
  sha="$(_commit_anchor "$n")"
  if [ -n "$sha" ] && _is_ancestor "$sha" "$BRANCH"; then
    if [ -z "$complete_lines" ]; then
      complete_lines="COMPLETE $n $sha"
    else
      complete_lines="$complete_lines
COMPLETE $n $sha"
    fi
    n=$((n + 1))
  else
    resume=$n
    break
  fi
done

echo "$resume"
if [ -n "$complete_lines" ]; then
  printf '%s\n' "$complete_lines"
fi

exit 0
