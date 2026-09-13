#!/bin/bash
# PreToolUse Bash hook: DENY `gh pr merge` when the pull-request body records
# an audit residual disposition in a shape no command can find -- a
# recognized heading spelled as anything but its canonical form, or an entry
# beneath a canonical heading carrying no dedup key. This is a SHAPE check: it
# never judges whether a finding should have been recorded, and it detects
# nothing that was never written down.
#
# ARMED only when the tool call is `Bash`, the command carries a `gh pr
# merge` invocation (shared verb-arming decision, .claude/hooks/lib/verb-
# arming.sh), the merge is not aimed at a foreign repository
# (.claude/hooks/lib/repo-scope.sh), and the resolved pull-request body
# carries at least one heading from the closed recognizer set below.
# Everything else PERMITS silently: no `gh` on PATH, `gh` present but
# unauthenticated, unreachable, or returning no record (an empty body, a JSON
# null body, or a non-zero `gh pr view`), a merge-command shape the shared
# scanner declines to model (a branch-name reference, a non-first-command
# merge, a URL naming another repository), a foreign-repo merge, and a body
# carrying no recognized heading at all.
#
# DENIES when either holds, reported together in one refusal when both do:
#   - a heading in the RECOGNIZED-BUT-REFUSED set below is present (a
#     non-canonical spelling of a residual disposition), or
#   - a canonical heading has at least one entry unit beneath it (a top-level
#     bullet through the next top-level bullet, heading, or end of body)
#     carrying no dedup key anywhere within it.
#
# The refusal never echoes body text: no offending heading, no entry text, no
# `path=`, no excerpt. It carries only counts, line numbers, and the fixed
# canonical literals. No bypass flag and no environment escape exist; a false
# positive is escaped by renaming the heading or adding a key.
#
# FAIL-CLOSED on one arm only: an absent `jq` denies loudly (exit 2, plain
# text stderr, no JSON) rather than let a fail-open `jq`-dependent gate read
# as "nothing to check". Every other abstention above permits.
#
# See wiki/concepts/PR Merge Workflow.md and
# wiki/concepts/Audit Disposition and Debt Fix.md for the full contract.

# -uo, not -e: this must never abort before writing its deny JSON. Every
# error-prone command below is individually guarded (|| true, 2>/dev/null).
set -uo pipefail

input=$(cat)

# jq-availability arm: refuse loudly rather than fail open when the
# interpreter this hook reads its payload with is absent. The literal is
# `gh`, read off this gate's own arming predicate below: every call this gate
# binds invokes `gh`, so the ABSENCE of `gh` from tool_input proves the call
# sits outside the remit and it is allowed, exactly as a parsed non-merge is.
# Presence is not proof of membership, and that over-deny is the safe
# direction. What it cannot reach is a spelling the shell assembles
# (`g\h pr merge`). `.claude/hooks/lib/jq-availability.sh` owns the contract.
_jq_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _jq_lib_dir=''
# shellcheck source=lib/jq-availability.sh
[ -n "$_jq_lib_dir" ] && [ -f "$_jq_lib_dir/jq-availability.sh" ] && . "$_jq_lib_dir/jq-availability.sh" 2>/dev/null
if ! type gaia_require_jq >/dev/null 2>&1; then
  printf 'BLOCKED: audit-residual-shape-check.sh cannot load lib/jq-availability.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_require_jq 'the accepted-residual shape gate' "$input" tool_input 'gh'

tool_name=$(echo "$input" | jq -r '.tool_name // ""' 2>/dev/null)
[ "$tool_name" = "Bash" ] || exit 0

# Avoid the name `command`: it would shadow bash's builtin and break later
# `command -v` guards.
cmd=$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)

# Arm through the shared verb-arming decision, loaded from this hook's own
# on-disk location, never cwd. This runs BEFORE arming and before deny() is
# defined, so an unloadable library writes its own deny JSON inline, denying
# every Bash tool call rather than merge attempts alone: it runs before the
# gate knows whether the call is a `gh pr merge` at all.
_va_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
_va_ok=0
if [ -n "$_va_lib_dir" ] && [ -f "$_va_lib_dir/verb-arming.sh" ]; then
  # shellcheck source=/dev/null
  if . "$_va_lib_dir/verb-arming.sh" && type gaia_verb_armed >/dev/null 2>&1; then
    _va_ok=1
  fi
fi
if [ "$_va_ok" -ne 1 ]; then
  jq -n --arg r "Accepted-residual shape gate: cannot load the shared verb-arming decision (.claude/hooks/lib/verb-arming.sh must exist, be readable, and define gaia_verb_armed). This check runs before the gate knows whether the tool call is a gh pr merge at all, so it denies every Bash tool call rather than merge attempts alone. Restore .claude/hooks/lib/verb-arming.sh (it ships with the framework; a missing or corrupted checkout is the usual cause) and retry." '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
fi

gate_verb_frag='gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
if gaia_verb_armed "$gate_verb_frag" 'gh pr merge' "$cmd"; then
  : # armed
else
  exit 0
fi

# Foreign-repo escape: a merge aimed at a different repository has no bearing
# on this repository's residual convention. Reuses the script-rooted lib
# directory resolved for the verb-arming load above, never a bare
# cwd-relative test.
[ -n "$_va_lib_dir" ] && [ -f "$_va_lib_dir/repo-scope.sh" ] && . "$_va_lib_dir/repo-scope.sh"
if type cmd_targets_foreign_repo >/dev/null 2>&1 \
   && cmd_targets_foreign_repo "$cmd"; then
  exit 0
fi

# Resolve the pull-request reference the merge names, through the shared
# scanner rather than a hand-rolled read of the command: two hand-rolled
# readings behind the sibling merge gate were both wrong in the permitting
# direction, which is why this is not optional.
command -v gh >/dev/null 2>&1 || exit 0

if ! type gaia_scan_gh_merge >/dev/null 2>&1; then
  exit 0
fi
gaia_scan_gh_merge "$cmd" || exit 0
ref="$GAIA_GH_MERGE_REF"

pr_arg=""
case "$ref" in
  '')
    # gh's own current-branch default.
    pr_arg=""
    ;;
  *[!0-9]*)
    # Not a bare integer: only an unambiguous home-repository URL is read
    # further. Anything else (a branch name) is declined.
    if [[ "$ref" =~ ^[hH][tT][tT][pP][sS]?:// ]] \
       && type gaia_gh_merge_ref_to_home_pr >/dev/null 2>&1 \
       && gaia_gh_merge_ref_to_home_pr "$ref"; then
      pr_arg="$GAIA_HOME_PR_NUMBER"
    else
      exit 0
    fi
    ;;
  *)
    pr_arg="$ref"
    ;;
esac

if [ -n "$pr_arg" ]; then
  raw="$(gh pr view "$pr_arg" --json body 2>/dev/null)" || exit 0
else
  raw="$(gh pr view --json body 2>/dev/null)" || exit 0
fi
[ -n "$raw" ] || exit 0
# `.body // ""` reads a JSON null body (no body at all) the same as an empty
# string; either permits.
body="$(printf '%s' "$raw" | jq -r '.body // ""' 2>/dev/null)" || exit 0
[ -n "$body" ] || exit 0

deny() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

# ---------------------------------------------------------------------------
# C1: the closed recognizer set, as plainly-greppable literal data. The two
# canonical spellings, then the recognized-but-refused set as two
# index-aligned parallel arrays: REFUSED_REPLACEMENTS[i] (one of "accept",
# "waive", or "both") names which canonical literal(s) below replace
# REFUSED_HEADINGS[i]. This is a description of a hand-audited set, not a
# generator; widening it is a human decision recorded elsewhere, never a
# threshold applied here.
# ---------------------------------------------------------------------------
CANON_ACCEPT='## Accepted residuals (recorded, not fixed)'
CANON_WAIVE='## Out-of-scope machinery findings (recorded, not filed)'

REFUSED_HEADINGS=(
  '## Accepted residuals'
  '## Accepted residual'
  '## Audit rounds and accepted residuals'
  '## Noted, not filed'
  '## Noted, not fixed'
  '## Accepted and noted, not fixed'
  '## Accepted residual (recorded, not fixed)'
  '## Accepted audit residual'
  '## Accepted audit residuals'
  '## Recorded, not fixed'
  '## Recorded, not fixed here'
  '## Waived findings'
)
REFUSED_REPLACEMENTS=(
  accept
  accept
  accept
  both
  accept
  accept
  accept
  accept
  accept
  accept
  accept
  waive
)

# C2's entry-unit boundary and C3's frozen key grammar.
heading_re='^#{1,6}[[:space:]]'
top_bullet_re='^([-*+]|[0-9]{1,9}[.)])[[:space:]]'
key_re='<!-- gaia-debt-key: v1 class=[^ ]+ path=[^ ]+ line=[0-9]+ -->'

offending_count=0
accept_replace_count=0
waive_replace_count=0
both_replace_count=0
keyless_count=0
keyless_lines=""

unit_open=0
unit_start_line=0
unit_keyed=0
in_canonical=0

# Closes the currently open entry unit (a no-op when none is open), scoring
# it keyless when C3's grammar never appeared inside it.
close_unit() {
  if [ "$unit_open" = 1 ] && [ "$unit_keyed" != 1 ]; then
    keyless_count=$((keyless_count + 1))
    if [ -n "$keyless_lines" ]; then
      keyless_lines="${keyless_lines}, ${unit_start_line}"
    else
      keyless_lines="$unit_start_line"
    fi
  fi
  unit_open=0
  unit_keyed=0
}

# One pass, 1-indexed. A here-string, not a piped subshell, so the counters
# above survive the loop. `|| [ -n "$raw_line" ]` picks up a final line with
# no trailing newline.
line_no=0
while IFS= read -r raw_line || [ -n "$raw_line" ]; do
  line_no=$((line_no + 1))

  if [[ "$raw_line" =~ $heading_re ]]; then
    close_unit
    in_canonical=0
    trimmed="$(printf '%s' "$raw_line" | sed -e 's/[[:space:]]*$//')"
    if [ "$trimmed" = "$CANON_ACCEPT" ] || [ "$trimmed" = "$CANON_WAIVE" ]; then
      in_canonical=1
    else
      i=0
      n=${#REFUSED_HEADINGS[@]}
      while [ "$i" -lt "$n" ]; do
        if [ "$trimmed" = "${REFUSED_HEADINGS[$i]}" ]; then
          offending_count=$((offending_count + 1))
          case "${REFUSED_REPLACEMENTS[$i]}" in
            accept) accept_replace_count=$((accept_replace_count + 1)) ;;
            waive) waive_replace_count=$((waive_replace_count + 1)) ;;
            both) both_replace_count=$((both_replace_count + 1)) ;;
          esac
          break
        fi
        i=$((i + 1))
      done
    fi
    continue
  fi

  [ "$in_canonical" = 1 ] || continue

  if [[ "$raw_line" =~ $top_bullet_re ]]; then
    close_unit
    unit_open=1
    unit_start_line=$line_no
    unit_keyed=0
    if [[ "$raw_line" =~ $key_re ]]; then
      unit_keyed=1
    fi
  elif [ "$unit_open" = 1 ]; then
    if [[ "$raw_line" =~ $key_re ]]; then
      unit_keyed=1
    fi
  fi
done <<< "$body"
close_unit

[ "$offending_count" -gt 0 ] || [ "$keyless_count" -gt 0 ] || exit 0

reason="PR merge gate: this pull request's body records an audit residual disposition in a shape no command can find."

if [ "$offending_count" -gt 0 ]; then
  reason="${reason}

Offending heading count: ${offending_count} (recognized but non-canonical spelling(s))."
  if [ "$accept_replace_count" -gt 0 ]; then
    reason="${reason}
${accept_replace_count} heading(s) must be renamed to: ${CANON_ACCEPT}"
  fi
  if [ "$waive_replace_count" -gt 0 ]; then
    reason="${reason}
${waive_replace_count} heading(s) must be renamed to: ${CANON_WAIVE}"
  fi
  if [ "$both_replace_count" -gt 0 ]; then
    reason="${reason}
${both_replace_count} heading(s) are ambiguous on the accept/waive axis; rename each to whichever of ${CANON_ACCEPT} or ${CANON_WAIVE} matches its meaning."
  fi
fi

if [ "$keyless_count" -gt 0 ]; then
  reason="${reason}

Keyless entry count: ${keyless_count}. Opening-bullet line number(s): ${keyless_lines}. Add a dedup key (the wrapped <!-- gaia-debt-key: v1 class=... path=... line=... --> form) anywhere within each named entry."
fi

reason="${reason}

No bypass flag and no environment escape exists for this gate. Fix the heading spelling, add the missing key(s), and retry gh pr merge."

deny "$reason"
