#!/usr/bin/env bash
# audit-noop-detect.sh: shared deterministic no-op detection predicate for
# the three adversarial-audit fan-out surfaces (/gaia-spec SPEC audit,
# /gaia-plan decomposition audit, pre-merge code-review-audit).
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
#   audit-noop-detect.sh --shape <SHAPE> --path <PATH> [--audit-md <AUDIT_MD_PATH>] [--marker <MARKER_PATH>] [--findings <FINDINGS_PATH>] [--report-key <KEY>] [--expect-count <N> | --min-count <N>]
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
#   --marker      optional; honored ONLY for --shape audit-team-member. Its
#                 mechanics (the EARNED short-circuit, the REFUSAL sibling
#                 checked first) live in that shape's case arm below. Ignored
#                 for every other shape.
#   --findings    optional; honored ONLY for --shape audit-team-member. The
#                 member's findings sidecar
#                 (.gaia/local/audit/<audit-key>.<member>.findings.json --
#                 audit-key is the incremental base sha plus the acting tree's
#                 branch, .gaia/scripts/audit-key-lib.sh); see the case arm
#                 below for the lost-report gate this argument enables when
#                 passed, and its member-identity binding. Omit it to keep the
#                 marker-only short-circuit. Ignored for every other shape.
#   --report-key  optional; honored ONLY for --shape agent-report-file. Names
#                 the top-level object key holding the report array. Omit it
#                 when the agent writes a bare top-level array. Ignored for
#                 every other shape.
#   --expect-count / --min-count
#                 optional and mutually exclusive; honored ONLY for --shape
#                 agent-report-file. The caller's own denominator, asserted as
#                 an exact length or a floor. A non-integer, a negative value,
#                 or both flags together is a usage error rather than a silent
#                 permanent no-op. Ignored for every other shape.
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
#   agent-report-file     the generic contract for a dispatch composed at the
#                         point of need, which inherits none of the per-flow
#                         shapes above. File exists AND parses AND the report
#                         array resolves (the top-level value, or --report-key's
#                         value when passed) AND, when --expect-count or
#                         --min-count is passed, its length satisfies that
#                         assertion. An empty array with no count assertion is
#                         REAL, for the same reason spec-findings-file's is:
#                         the distinction being preserved is "the agent wrote
#                         nothing" versus "the agent wrote an empty answer",
#                         and only the second is a result. A caller that knows
#                         its own denominator asserts it, because existence-
#                         plus-parses alone is not sufficient: a truncated
#                         write parses fine and reads as a real result, which
#                         reproduces the same collapse one level down, inside a
#                         file that exists.
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
#   audit-team-member     the --marker path's REFUSAL sibling
#                         (`<marker-without-.ok>.refused`) holds a
#                         writer-produced refusal for the same member and
#                         digest, which classifies REFUSED (a distinct stdout
#                         token, exit 0), OR
#                         --marker path holds a writer-produced EARNED
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
# A refusal (audit-team-member only) is proof of life, never a no-op: see the
# refusal arm in that shape's case arm below for why it is checked before the
# earned family. The lost-report gate does not apply to it because a refusal
# with no sidecar is a differently-broken run, and re-dispatching returns the
# identical empty hand.
#
# Exit code IS the boolean: 0 = REAL (not a no-op), 1 = NO-OP, 2 = usage
# error (unknown --shape, missing --shape/--path). Also prints `real`,
# `refused`, or `noop` to stdout for human/log readability -- `refused` is a
# finer-grained label on the same exit-0 "not a no-op" verdict, so callers
# branch on the exit code, never on stdout.
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
usage: audit-noop-detect.sh --shape <SHAPE> --path <PATH> [--audit-md <AUDIT_MD_PATH>] [--marker <MARKER_PATH>] [--findings <FINDINGS_PATH>] [--report-key <KEY>] [--expect-count <N> | --min-count <N>]

  --shape  one of: spec-selfreview-file, spec-findings-file,
           spec-verdict-file, applier-summary, plan-findings,
           cra-specialist, cra-refuter, audit-team-member,
           agent-report-file
  --path   file-backed shape: expected output file.
           return-conformance shape: captured-return temp file.
  --audit-md  optional; honored only for --shape applier-summary.
  --marker    optional; honored only for --shape audit-team-member. Its
              `.refused` sibling is checked first and classifies refused.
  --findings  optional; honored only for --shape audit-team-member. The
              member's findings sidecar; when passed, the EARNED marker
              short-circuit also requires it (lost-report detection). It does
              not gate the refusal arm.
  --report-key   optional; honored only for --shape agent-report-file. The
                 top-level key holding the report array. Omit for a bare
                 top-level array.
  --expect-count optional; honored only for --shape agent-report-file. Exact
                 report length. Mutually exclusive with --min-count.
  --min-count    optional; honored only for --shape agent-report-file. Minimum
                 report length. Mutually exclusive with --expect-count.

exit 0 = real (stdout `real`, or `refused` for a withheld clearance),
1 = noop, 2 = usage error.
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

# refused: a member that withheld clearance after a full review. Same exit-0
# "not a no-op" verdict as real(), with its own stdout token so a log or an
# operator reading it gets the right diagnosis instead of "no-op".
refused() {
  echo refused
  exit 0
}

SHAPE=""
TARGET_PATH=""
AUDIT_MD=""
MARKER_PATH=""
FINDINGS_PATH=""
REPORT_FIELD=""
EXPECT_COUNT=""
MIN_COUNT=""
# Presence is tracked separately from value. A caller interpolating an unset
# variable passes an EMPTY count, and testing the value alone reads that as
# "no count asked for", which silently drops the assertion and collapses the
# predicate back to existence-plus-parses. That is the exact failure this flag
# exists to close, so it must fail closed (a usage error) rather than open.
EXPECT_COUNT_SEEN=""
MIN_COUNT_SEEN=""

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
    --report-key)
      REPORT_FIELD="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --expect-count)
      EXPECT_COUNT="${2:-}"
      EXPECT_COUNT_SEEN=1
      shift 2 2>/dev/null || shift
      ;;
    --min-count)
      MIN_COUNT="${2:-}"
      MIN_COUNT_SEEN=1
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
  spec-selfreview-file|spec-findings-file|spec-verdict-file|applier-summary|plan-findings|cra-specialist|cra-refuter|audit-team-member|agent-report-file)
    ;;
  *)
    echo "audit-noop-detect: unknown --shape '$SHAPE'" >&2
    usage
    exit 2
    ;;
esac

# Count-assertion validation, ahead of every predicate so a malformed
# denominator can never be mistaken for a short report. The check is on the
# argument's form only; whether a shape honors a count is the shape's own
# business, matching how --audit-md, --marker, and --findings are ignored
# outside the one shape each serves.
if [ -n "$EXPECT_COUNT_SEEN" ] && [ -n "$MIN_COUNT_SEEN" ]; then
  echo "audit-noop-detect: --expect-count and --min-count are mutually exclusive" >&2
  usage
  exit 2
fi
# An unvalidated non-integer would make the jq comparison below compare a
# number against a string, which is always false, so every run would classify
# NO-OP and the caller would burn its one retry on a dispatch that was never
# broken. The empty string fails the other way, silently dropping the whole
# assertion, so both are rejected here. Gate on presence, never on value.
_acd_validate_count() {
  # <seen-flag> <value> <flag-name>
  [ -n "$1" ] || return 0
  case "$2" in
    *[!0-9]*|"")
      echo "audit-noop-detect: $3 must be a non-negative integer, got '$2'" >&2
      usage
      exit 2
      ;;
  esac
}
_acd_validate_count "$EXPECT_COUNT_SEEN" "$EXPECT_COUNT" --expect-count
_acd_validate_count "$MIN_COUNT_SEEN" "$MIN_COUNT" --min-count

# ---------- file-backed shapes: absent path is always NO-OP ----------
case "$SHAPE" in
  spec-selfreview-file|spec-findings-file|spec-verdict-file|agent-report-file)
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

  agent-report-file)
    # `--arg` rather than interpolation: the key and the count cross into jq as
    # data, so a caller value carrying jq syntax cannot become jq program text.
    # That is also why the count arrives as a string and is compared through
    # `tonumber`. The two count flags are mutually exclusive (enforced above),
    # so concatenating them yields whichever one was passed, or the empty
    # string when neither was, and the empty case never reaches `--arg n`
    # because no count test is built for it.
    #
    # `try getpath` rather than `.[$f]`: indexing a non-object top level raises,
    # and a raise leaves jq's exit status meaning something other than "the
    # predicate was false". Catching it to null collapses that case onto the
    # same false the wrong-key case already produces, so every not-a-report
    # shape classifies NO-OP through one path.
    # shellcheck disable=SC2016  # $f is jq's --arg binding, not a shell expansion.
    _acd_report='if $f == "" then . else (try getpath([$f]) catch null) end'
    if [ -n "$EXPECT_COUNT_SEEN" ]; then
      _acd_count_test="and (($_acd_report | length) == (\$n | tonumber))"
    elif [ -n "$MIN_COUNT_SEEN" ]; then
      _acd_count_test="and (($_acd_report | length) >= (\$n | tonumber))"
    else
      _acd_count_test=""
    fi
    if jq -e --arg f "$REPORT_FIELD" --arg n "${EXPECT_COUNT}${MIN_COUNT}" \
         "($_acd_report | type == \"array\") $_acd_count_test" \
         "$TARGET_PATH" >/dev/null 2>&1; then
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
    # Resolve the clearance reader from this script's own on-disk location
    # (.gaia/scripts -> ../../.claude/hooks/lib), never from cwd. Hoisted above
    # both marker arms below so the refusal check and the earned check read
    # markers through the same writer-shape reader.
    _acd_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.claude/hooks/lib" 2>/dev/null && pwd)"
    if [ -n "$_acd_lib" ] && [ -f "$_acd_lib/audit-clearance.sh" ]; then
      # shellcheck source=/dev/null
      . "$_acd_lib/audit-clearance.sh"
    fi

    # ---------- refusal arm (checked FIRST) ----------
    # A refusing member writes `<digest>[.<member>].refused` and no `.ok`, so
    # the caller's --marker path names a file that will never exist for this
    # run. Derive its refusal sibling and settle the classification there: a
    # deliberately-written blocking artifact is the strongest proof of life the
    # protocol has, and calling it a no-op spends the single retry re-running a
    # member that was never broken. Refusal-first also matches the merge gate's
    # own precedence, so the crash window that leaves both markers on disk
    # classifies the same way in both readers.
    if [ -n "$MARKER_PATH" ]; then
      _acd_refused_path="${MARKER_PATH%.ok}.refused"
      if [ -f "$_acd_refused_path" ]; then
        _acd_r_base="$(basename "$_acd_refused_path")"
        _acd_r_stem="${_acd_r_base%.refused}"
        _acd_r_digest="${_acd_r_stem%%.*}"
        _acd_r_member_part="${_acd_r_stem#"$_acd_r_digest"}"
        if [ -z "$_acd_r_member_part" ]; then
          _acd_r_member="code-audit-frontend"
        else
          _acd_r_member="${_acd_r_member_part#.}"
        fi
        # With jq absent the body cannot be inspected, so existence alone
        # settles it -- the same degradation the earned arm below already
        # applies.
        if ! command -v jq >/dev/null 2>&1; then
          refused
        fi
        if command -v clearance_refusal_acceptable >/dev/null 2>&1 \
           && clearance_refusal_acceptable "$_acd_refused_path" "$_acd_r_member" "$_acd_r_digest"; then
          refused
        fi
      fi
    fi

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
      # The clearance reader is sourced at the top of this branch.
      if command -v clearance_acceptable >/dev/null 2>&1; then
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
    # same hazard gaia-react/gaia#748 removed from the success-present guard, not a
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
