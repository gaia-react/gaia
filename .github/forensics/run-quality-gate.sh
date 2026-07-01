#!/usr/bin/env bash
# run-quality-gate.sh: Quality Gate runner for the forensics
# triage workflow. Executes each gate step in order, halts on the first
# failure, and writes a JSON summary the workflow YAML feeds into the
# `handle-needs-human.sh` reason-code `gate-failure` path (UAT-005).
#
# Usage:
#   run-quality-gate.sh <output-summary-file>
#
# Steps (in order, halt-on-first-fail):
#   1. pnpm install --frozen-lockfile  (deps tree precondition)
#   2. pnpm typecheck
#   3. pnpm lint
#   4. pnpm test --run                  (vitest only; playwright is out of
#                                        scope for the triage gate, see
#                                        task-quality-gate-runner.md)
#   5. pnpm knip
#
# Output JSON:
#   On failure:
#     { "passed": false, "failed_step": "<step>",
#       "exit_code": <int>, "log_excerpt": "<≤50 lines, ≤2000 chars>" }
#   On pass:
#     { "passed": true,
#       "steps_run": ["install", "typecheck", "lint", "test", "knip"] }
#
# Exit code: 0 on pass, 1 on any step failure. The workflow YAML uses the
# exit code to short-circuit; the JSON summary feeds the issue comment.
#
# Knip caveat:
#   .claude/rules/knip.md says "do not run mid-task / as part of the
#   Quality Gate, in-progress exports flag as false positives". That
#   advice targets human/IDE Quality Gate use during active development.
#   In the triage workflow the candidate fix is fully committed before
#   this script runs, so knip's incomplete-export-graph failure mode
#   does NOT apply. Knip IS in scope here and is treated identically to
#   lint/test failures.
#
# Dependencies:
#   pnpm, bootstrapped by an earlier workflow step (this script does not
#   set up pnpm itself).
#
# Local maintainer use:
#   .github/forensics/run-quality-gate.sh /tmp/qg.json
#   …validates a candidate fix branch the same way the workflow does
#   before manually opening a PR.

set -uo pipefail

usage() {
  echo "usage: run-quality-gate.sh <output-summary-file>" >&2
  exit 2
}

[ "$#" -eq 1 ] || usage
summary_file="$1"

# Ensure parent dir exists; fail fast if the path is invalid.
summary_parent="$(dirname "$summary_file")"
[ -d "$summary_parent" ] || { echo "run-quality-gate.sh: parent dir does not exist: $summary_parent" >&2; exit 2; }

work_dir=$(mktemp -d 2>/dev/null) || { echo "run-quality-gate.sh: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$work_dir"' EXIT

# ---------------------------------------------------------------------------
# JSON-string escaping. Pure bash; avoids the jq dependency for a runner
# that already pulls pnpm + node into scope. Handles backslash, double
# quote, and control bytes (newline / CR / tab → \n \r \t; other 0x00-0x1f
# bytes → \u00XX). Trailing newlines in the input are preserved.
# ---------------------------------------------------------------------------
json_escape() {
  local in="$1"
  local out=""
  local i ch code
  for (( i = 0; i < ${#in}; i++ )); do
    ch="${in:i:1}"
    case "$ch" in
      '\') out+='\\' ;;
      '"') out+='\"' ;;
      $'\n') out+='\n' ;;
      $'\r') out+='\r' ;;
      $'\t') out+='\t' ;;
      *)
        printf -v code '%d' "'$ch"
        if [ "$code" -lt 32 ]; then
          out+="$(printf '\\u%04x' "$code")"
        else
          out+="$ch"
        fi
        ;;
    esac
  done
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Run one gate step. Captures merged stderr+stdout to a per-step log.
# On non-zero exit:
#   - Trims the log to the last 50 lines AND ≤2000 chars (whichever is
#     tighter, comment-fitting is the hard constraint).
#   - Writes the failure summary JSON.
#   - Returns 1 (caller propagates).
# On zero exit: returns 0 silently.
#
# Args:
#   $1: step name (matches the spec's vocabulary: install/typecheck/lint/test/knip)
#   $2..$N: command + args
# ---------------------------------------------------------------------------
run_step() {
  local step="$1"
  shift
  local log_file="$work_dir/${step}.log"
  local exit_code=0

  echo "::group::quality-gate: ${step}"
  # Run the command and capture its exit code DIRECTLY. Using
  # `if "$@"; then ... fi` would clobber `$?` by the time we read it
  # (the `else` / `fi` body itself contributes to `$?`).
  "$@" >"$log_file" 2>&1
  exit_code=$?
  echo "::endgroup::"
  if [ "$exit_code" -eq 0 ]; then
    return 0
  fi
  echo "::error::quality-gate step '${step}' failed (exit ${exit_code})"

  # Trim: last 50 lines, then cap at 2000 chars from the END (the tail is
  # where the actual error message lives).
  local excerpt
  excerpt="$(tail -n 50 "$log_file")"
  local max_chars=2000
  if [ "${#excerpt}" -gt "$max_chars" ]; then
    excerpt="${excerpt: -$max_chars}"
  fi

  local escaped
  escaped="$(json_escape "$excerpt")"

  cat >"$summary_file" <<JSON
{
  "passed": false,
  "failed_step": "${step}",
  "exit_code": ${exit_code},
  "log_excerpt": "${escaped}"
}
JSON
  return 1
}

# ---------------------------------------------------------------------------
# Steps. Halt-on-first-fail: each `run_step` returns 1 to bubble up here
# via `|| exit 1`; we never proceed past a failure. Order matches the
# task spec.
# ---------------------------------------------------------------------------
run_step install   pnpm install --frozen-lockfile || exit 1
run_step typecheck pnpm typecheck                  || exit 1
run_step lint      pnpm lint                       || exit 1
run_step test      pnpm test --run                 || exit 1
run_step knip      pnpm knip                       || exit 1

# All-green summary.
cat >"$summary_file" <<'JSON'
{
  "passed": true,
  "steps_run": ["install", "typecheck", "lint", "test", "knip"]
}
JSON

exit 0
