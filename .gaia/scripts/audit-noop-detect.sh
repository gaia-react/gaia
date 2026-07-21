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
#   audit-noop-detect.sh --shape <SHAPE> --path <PATH> [--audit-md <AUDIT_MD_PATH>] [--marker <MARKER_PATH>] [--findings <FINDINGS_PATH>]
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
#   --marker      optional; honored ONLY for --shape audit-team-member. A
#                 writer-produced EARNED clearance at this path short-circuits
#                 classification to REAL without inspecting --path: the
#                 dispatched member already wrote its clearance marker (a clean
#                 pass, or an advisory member's non-Critical dirty pass). When
#                 --findings is also passed, that durable report must be
#                 present too before the marker authorizes REAL. Ignored for
#                 every other shape.
#   --findings    optional; honored ONLY for --shape audit-team-member. The
#                 member's findings sidecar
#                 (.gaia/local/audit/<base-sha>.<member>.findings.json), the
#                 durable report of record a specialized member writes on every
#                 LOCAL pass, clean or withheld. When passed, the --marker
#                 short-circuit additionally requires this file to exist and,
#                 with jq available, to parse with a `.findings` array AND a
#                 `.member` equal to the member the marker filename names. That
#                 identity binding matters: the orchestrator hand-builds one
#                 sidecar path per dispatched member and those paths differ
#                 only by the member infix, so a shape-only check would let one
#                 member's sidecar vouch for another's lost report.
#                 A member whose report never reached the orchestrator leaves
#                 its marker present and this artifact absent, so requiring
#                 BOTH is what makes a LOST REPORT detectable instead of
#                 indistinguishable from a clean pass: marker-presence alone
#                 would authorize REAL and suppress the retry, leaving the
#                 orchestrator holding a green gate and zero visible findings.
#                 Omit it to keep the marker-only short-circuit: the default
#                 member keys its durable detail to a different artifact, and a
#                 run whose base sha did not resolve writes no sidecar at all.
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
#   audit-team-member     --marker path holds a writer-produced EARNED
#                         clearance (a clean or non-blocking-dirty pass already
#                         wrote it) AND, when --findings is passed, that
#                         durable report of record is present and attributed to
#                         the same member, OR the
#                         captured return in --path carries a backticked
#                         `` `<path>:<line>` `` finding-location token (any
#                         Code Audit Team member's shared Output Format
#                         template bolds every reported finding's Location
#                         field this way, blocking or not), OR the return
#                         carries code-audit-frontend's terse LOCAL
#                         return-contract preamble, the literal string
#                         "Remaining in-scope:". Covers every real outcome a
#                         top-level member can return: clean, advisory-dirty,
#                         blocking-dirty full report, and blocking-dirty terse
#                         ledger-pointer. A bare harness-reminder / output-
#                         style echo carries none of the three and classifies
#                         NO-OP.
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
usage: audit-noop-detect.sh --shape <SHAPE> --path <PATH> [--audit-md <AUDIT_MD_PATH>] [--marker <MARKER_PATH>] [--findings <FINDINGS_PATH>]

  --shape  one of: spec-selfreview-file, spec-findings-file,
           spec-verdict-file, applier-summary, plan-findings,
           cra-specialist, cra-refuter, audit-team-member
  --path   file-backed shape: expected output file.
           return-conformance shape: captured-return temp file.
  --audit-md  optional; honored only for --shape applier-summary.
  --marker    optional; honored only for --shape audit-team-member.
  --findings  optional; honored only for --shape audit-team-member. The
              member's findings sidecar; when passed, the marker
              short-circuit also requires it (lost-report detection).

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
MARKER_PATH=""
FINDINGS_PATH=""

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
    --marker)
      MARKER_PATH="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --findings)
      FINDINGS_PATH="${2:-}"
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
  spec-selfreview-file|spec-findings-file|spec-verdict-file|applier-summary|plan-findings|cra-specialist|cra-refuter|audit-team-member)
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
    # Here-string, not a `printf | grep -q` pipe: see the audit-team-member
    # branch below for the full SIGPIPE/pipefail rationale -- the same
    # large-content hazard applies to every shape in this file.
    elif grep -Eq '`[^`]+:[0-9]+`' <<<"$content"; then
      real
    else
      noop
    fi
    ;;

  cra-refuter)
    [ -f "$TARGET_PATH" ] || noop
    content="$(cat "$TARGET_PATH" 2>/dev/null)"
    # Here-string, not a `printf | grep -q` pipe: see the audit-team-member
    # branch below for the full SIGPIPE/pipefail rationale -- the same
    # large-content hazard applies to every shape in this file.
    if grep -Eq '\b(REFUTED|DOWNGRADE|STANDS)\b' <<<"$content"; then
      real
    else
      noop
    fi
    ;;

  audit-team-member)
    # The marker is conditional (withheld on a blocking finding), unlike the
    # file-backed shapes above whose file always writes on any real
    # completion, so its absence alone cannot mean no-op. Check it first as a
    # same-cost short-circuit; fall through to content inspection either way
    # it does not conclusively rule NO-OP on its own.
    #
    # Short-circuit to real ONLY when $MARKER_PATH is a writer-produced EARNED
    # clearance: the body parses, provenance is "earned", and the body digest
    # equals the filename key. A legacy or hand-written marker is not
    # writer-shaped, so it falls through to the content inspection below
    # (unchanged). Marker existence alone no longer authorizes real. With jq
    # absent the body cannot be inspected, so existence degrades to real as
    # before.
    if [ -n "$MARKER_PATH" ] && [ -f "$MARKER_PATH" ]; then
      # Derive the audited member and digest from the marker FILENAME up front:
      # pure parameter expansion plus basename, needing no sourced lib, so BOTH
      # the findings gate and the clearance check below bind to the same
      # identity. The detector is only ever handed the `.ok` earned marker path
      # (a refusal or a member's non-blocking-dirty pass never reaches here), so
      # stripping just `.ok` is the whole job: the remaining stem is `<digest>`
      # (default member) or `<digest>.<member>` (a specialist).
      _acd_base="$(basename "$MARKER_PATH")"
      _acd_stem="${_acd_base%.ok}"
      _acd_digest="${_acd_stem%%.*}"
      _acd_member_part="${_acd_stem#"$_acd_digest"}"
      if [ -z "$_acd_member_part" ]; then
        _acd_member="code-audit-frontend"
      else
        _acd_member="${_acd_member_part#.}"
      fi

      # Lost-report gate. When the caller names the member's durable findings
      # sidecar, the marker alone no longer authorizes REAL. A member whose
      # report never reached the orchestrator still wrote its marker, so
      # keying on marker-presence would classify REAL, suppress the one-shot
      # retry, and leave the operator holding a green gate with no findings to
      # act on, including the Suggestions the clean-pass contract requires them
      # to resolve or acknowledge. The sidecar is the report of record, so
      # demanding BOTH is what separates a real clean pass from a lost one.
      #
      # The predicate binds to the audited MEMBER, not merely to the shape. The
      # orchestrator hand-builds one sidecar path per dispatched member and
      # those paths differ only by the member infix, so a shape-only check
      # would let member A's sidecar vouch for member B's lost report, exactly
      # the failure this gate exists to close. It matches what the clearance
      # check below already demands of the marker, so both arms of the same
      # short-circuit agree on whether filename-derived identity is trusted.
      # An EMPTY findings array is valid and REAL: a member that genuinely
      # found nothing still writes one.
      _acd_findings_ok=1
      if [ -n "$FINDINGS_PATH" ]; then
        _acd_findings_ok=0
        if [ -f "$FINDINGS_PATH" ]; then
          if command -v jq >/dev/null 2>&1; then
            if jq -e --arg m "$_acd_member" \
                 '(.member == $m) and (.findings | type == "array")' \
                 "$FINDINGS_PATH" >/dev/null 2>&1; then
              _acd_findings_ok=1
            fi
          else
            # jq absent: existence degrades to acceptance, matching the marker
            # arm's own jq-absent degradation just below.
            _acd_findings_ok=1
          fi
        fi
      fi
      if [ "$_acd_findings_ok" -eq 1 ] && ! command -v jq >/dev/null 2>&1; then
        real
      fi
      # Resolve the clearance reader from this script's own on-disk location
      # (.gaia/scripts -> ../../.claude/hooks/lib), never from cwd.
      _acd_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.claude/hooks/lib" 2>/dev/null && pwd)"
      if [ -n "$_acd_lib" ] && [ -f "$_acd_lib/audit-clearance.sh" ]; then
        # shellcheck source=/dev/null
        . "$_acd_lib/audit-clearance.sh"
        if [ "$_acd_findings_ok" -eq 1 ] \
           && clearance_acceptable "$MARKER_PATH" "$_acd_member" "$_acd_digest" \
           && [ "$(clearance_field "$MARKER_PATH" provenance)" = "earned" ]; then
          real
        fi
      fi
    fi
    [ -f "$TARGET_PATH" ] || noop
    content="$(cat "$TARGET_PATH" 2>/dev/null)"
    # Here-string, not a `printf | grep -q` pipe: under `pipefail`, grep -q's
    # early exit on a large early match SIGPIPEs the upstream writer, and the
    # pipeline's exit code collapses to that SIGPIPE, not grep's match. A
    # full audit report comfortably exceeds the pipe buffer, so this is the
    # same hazard #748 removed from the success-present guard, not a
    # theoretical one. shellcheck disable=SC2016 (literal backticks, not a
    # command substitution).
    # shellcheck disable=SC2016
    if grep -Eq '`[^`]+:[0-9]+`' <<<"$content"; then
      real
    elif grep -Fq 'Remaining in-scope:' <<<"$content"; then
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
