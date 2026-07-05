#!/usr/bin/env bash
# audit-noop-detect.sh: shared deterministic no-op detection predicate for
# the three adversarial-audit fan-out surfaces (/gaia-spec SPEC audit,
# /gaia-plan decomposition audit, pre-merge code-review-audit). SPEC-025.
#
# When a dispatched `general-purpose` Agent no-ops (zero tool uses, its
# whole return is a harness-reminder-echo / output-style fragment), no
# findings file is written and the orchestration would otherwise proceed as
# if that lens found nothing. This helper answers, deterministically and
# from disk only, "is the expected structured audit output present and does
# it match this caller's valid result shape?" It never loads a finding,
# verdict, or draft BODY into the calling agent's reasoning context -- only
# a boolean crosses back (spec.md's "main never opens the verdict files"
# invariant).
#
# Usage:
#   audit-noop-detect.sh --shape <SHAPE> --path <PATH> [--audit-md <AUDIT_MD_PATH>]
#
#   --shape       one of the caller shape ids below (FC-2).
#   --path        file-backed shape: the expected output file, which the
#                 caller pre-cleared (`rm -f`) before dispatch, so presence
#                 is a fresh-write signal. return-conformance shape: a file
#                 on disk holding the dispatched agent's captured thin
#                 return text.
#   --audit-md    optional; honored ONLY for --shape applier-summary. When
#                 passed, that AUDIT.md path must also exist for a REAL
#                 classification (the 7c-with-directives dispatch). Ignored
#                 for every other shape.
#
# Caller shapes (FC-2), REAL iff:
#   spec-selfreview-file  file exists AND `jq -e .` parses AND (top-level is
#                         an array OR `.findings` is an array)
#   spec-findings-file    file exists AND `.findings` is an array (an empty
#                         array is REAL -- a lens that found nothing still
#                         writes one)
#   spec-verdict-file     file exists AND `.verdict` is one of confirmed /
#                         partial / refuted. Covers BOTH the 7b refuter and
#                         the completeness-critic refuter (identical shape).
#   applier-summary       parses AND (`.counts` present OR `.folded`
#                         present); plus --audit-md, when given, must exist
#   plan-findings         parses AND `.dimension` present AND `.findings`
#                         is an array
#   cra-specialist        trimmed content == "No violations found." OR the
#                         content carries a finding block, detected by a
#                         backticked `` `<path>:<line>` `` token. Deliberately
#                         does NOT key on a literal "Location:" label: the
#                         real specialist template emits markdown-bold
#                         "- **Location**: `path:line`" (code-review-audit.md),
#                         so a bare "Location:" substring never appears and
#                         keying on it would misclassify a real finding as a
#                         no-op.
#   cra-refuter           content contains a standalone verdict token
#                         REFUTED, DOWNGRADE, or STANDS
#
# Exit code IS the boolean: 0 = REAL (not a no-op), 1 = NO-OP, 2 = usage
# error (unknown --shape, missing --shape/--path). Also prints `real` or
# `noop` to stdout for human/log readability -- callers branch on the exit
# code, never on stdout.
#
# A harness-reminder-echo / output-style block / empty or whitespace-only
# return matches none of the above predicates, so it classifies NO-OP for
# every shape. That is the whole point of this helper.
#
# Pure and side-effect-free: never writes, never clears a path, never
# dispatches, never touches the network. Deterministic and safe to re-run.
# Clearing the expected path before dispatch (Directive #4) is the calling
# prose's job, not this helper's.
#
# DO NOT add `set -e` (matches plan-archive.sh / token-rollup.sh): this
# helper's whole logic is intentionally-non-zero-exiting `jq -e` / `grep`
# checks (a no-op IS exit 1), so `-e` would abort mid-check on the first
# falsey test instead of returning the boolean. Each predicate is guarded
# with `if`/`||` and the final exit code is computed explicitly.
set -uo pipefail

usage() {
  cat <<'EOF' >&2
usage: audit-noop-detect.sh --shape <SHAPE> --path <PATH> [--audit-md <AUDIT_MD_PATH>]

  --shape  one of: spec-selfreview-file, spec-findings-file,
           spec-verdict-file, applier-summary, plan-findings,
           cra-specialist, cra-refuter
  --path   file-backed shape: expected output file.
           return-conformance shape: captured-return temp file.
  --audit-md  optional; honored only for --shape applier-summary.

exit 0 = real, 1 = noop, 2 = usage error.
EOF
}

# real / noop: print the human-readable classification and exit with the
# boolean contract. `exit` inside a function ends the whole process (bash
# functions are not subshells), so these terminate the script immediately.
real() {
  echo real
  exit 0
}

noop() {
  echo noop
  exit 1
}

SHAPE=""
TARGET_PATH=""
AUDIT_MD=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --shape)
      SHAPE="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --path)
      TARGET_PATH="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --audit-md)
      AUDIT_MD="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    *)
      echo "audit-noop-detect: unrecognized argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [ -z "$SHAPE" ] || [ -z "$TARGET_PATH" ]; then
  echo "audit-noop-detect: --shape and --path are required" >&2
  usage
  exit 2
fi

case "$SHAPE" in
  spec-selfreview-file|spec-findings-file|spec-verdict-file|applier-summary|plan-findings|cra-specialist|cra-refuter)
    ;;
  *)
    echo "audit-noop-detect: unknown --shape '$SHAPE'" >&2
    usage
    exit 2
    ;;
esac

# ---------- file-backed shapes: absent path is always NO-OP ----------
case "$SHAPE" in
  spec-selfreview-file|spec-findings-file|spec-verdict-file)
    [ -f "$TARGET_PATH" ] || noop
    ;;
esac

case "$SHAPE" in

  spec-selfreview-file)
    # Top-level array OR `.findings` is an array. The `or` short-circuits in
    # jq, so `.findings` is never evaluated (and never errors) when the
    # top-level value is already an array.
    if jq -e 'type == "array" or (.findings | type == "array")' "$TARGET_PATH" >/dev/null 2>&1; then
      real
    else
      noop
    fi
    ;;

  spec-findings-file)
    # Empty `.findings` array is REAL: a lens that genuinely found nothing
    # still writes `{"dimension":...,"findings":[]}`.
    if jq -e '.findings | type == "array"' "$TARGET_PATH" >/dev/null 2>&1; then
      real
    else
      noop
    fi
    ;;

  spec-verdict-file)
    if jq -e '.verdict as $v | ["confirmed","partial","refuted"] | index($v)' "$TARGET_PATH" >/dev/null 2>&1; then
      real
    else
      noop
    fi
    ;;

  applier-summary)
    [ -f "$TARGET_PATH" ] || noop
    if jq -e '(.counts != null) or (.folded != null)' "$TARGET_PATH" >/dev/null 2>&1; then
      if [ -n "$AUDIT_MD" ] && [ ! -f "$AUDIT_MD" ]; then
        noop
      else
        real
      fi
    else
      noop
    fi
    ;;

  plan-findings)
    [ -f "$TARGET_PATH" ] || noop
    if jq -e '(.dimension != null) and (.findings | type == "array")' "$TARGET_PATH" >/dev/null 2>&1; then
      real
    else
      noop
    fi
    ;;

  cra-specialist)
    [ -f "$TARGET_PATH" ] || noop
    content="$(cat "$TARGET_PATH" 2>/dev/null)"
    trimmed="$(printf '%s' "$content" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    # The grep pattern below is a literal backtick-delimited path:line
    # regex, not a command sub.
    # shellcheck disable=SC2016
    if [ "$trimmed" = "No violations found." ]; then
      real
    elif printf '%s' "$content" | grep -Eq '`[^`]+:[0-9]+`'; then
      real
    else
      noop
    fi
    ;;

  cra-refuter)
    [ -f "$TARGET_PATH" ] || noop
    content="$(cat "$TARGET_PATH" 2>/dev/null)"
    if printf '%s' "$content" | grep -Eq '\b(REFUTED|DOWNGRADE|STANDS)\b'; then
      real
    else
      noop
    fi
    ;;

esac

# Unreachable: every shape branch above exits via real/noop. Guard anyway so
# a future shape added to the catalog without a body fails loudly (usage
# error) instead of silently falling through with an unset exit code.
echo "audit-noop-detect: internal error: shape '$SHAPE' matched no predicate" >&2
exit 2
