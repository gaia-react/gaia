#!/usr/bin/env bash
# shellcheck shell=bash
#
# lint-hook-monitor-arming.sh: flag a command-reading PreToolUse guard that a
# `Monitor`-armed command walks straight past. Exit 0 when clean, 1 with a
# per-hook report on any hit, 2 on the check's own failure, and 130 or 143 when
# a SIGINT or SIGTERM interrupts it. Run it from anywhere:
# `bash .gaia/scripts/lint-hook-monitor-arming.sh [<repo_root>]`.
# gaia:maintainer-only:start
#
# Enforced by the sibling bats suite
# .gaia/scripts/tests/lint-hook-monitor-arming.bats, which the `Audit CI Tests`
# scripts shard runs, and folded into .gaia/tests/shell-lint.sh, whose `**/*.sh`
# and `.claude/settings.json` paths-filter entries between them arm it on both
# surfaces it reads.
# gaia:maintainer-only:end
#
# Why: a PreToolUse matcher is an unanchored regex over the TOOL NAME, so
# `"Bash"` never matches `"Monitor"`. Both tools hand the hook a raw shell
# command in the same `tool_input.command` field and run it in the same shell
# environment, so every command a `Bash`-matcher guard refuses is armable
# through `Monitor` with the guard never invoked. The bypass is silent in both
# directions: no denial, no diagnostic, and a merge or a removal that the layer
# was written to stop.
#
# THE TWO POSTURES, and which hook takes which. The split is not this gate's
# judgement: it reads the same blocking oracle
# .gaia/scripts/lint-hook-advisory-classification.sh and
# .gaia/scripts/lint-hook-jq-availability.sh read, out of
# .gaia/scripts/hook-registration-lib.sh, so a hook cannot be blocking for one
# gate and advisory for another.
#   blocking  -- the hook can stop a tool call, so the action it refuses is the
#                same action however it is armed, and the matcher owes
#                `Monitor`. Over-arming a denial costs a refusal on a watch
#                loop, which is loud and cheap; under-arming costs the bypass
#                above, which is silent.
#   advisory  -- the hook only records, so arming it on a second tool changes
#                WHAT IT COUNTS rather than what it protects: a watch that
#                names the verb, or one re-armed after its deadline, adds rows
#                for a single real action. A missing row is recoverable and a
#                wrong one is not distinguishable from a real one, so ARM A
#                leaves the decision to whoever owns the ledger and says
#                nothing about an advisory hook's matcher either way. Arm B
#                carries no such filter: an advisory hook on a Monitor-reaching
#                row whose body still pins `tool_name` to `Bash` is reported
#                the same as a blocking one, because a reader of the settings
#                diff cannot tell the posture apart from the row alone.
#
# TWO ARMS, because the repair has two halves and half of it is inert:
#   A. UNDER-ARMED MATCHER. A PreToolUse row whose matcher reaches `Bash` but
#      not `Monitor`, registering a blocking hook that reads
#      `tool_input.command`.
#   B. INERT INTERNAL GATE. A hook registered in a row whose matcher DOES reach
#      `Monitor`, whose body names `Bash` outside a comment and never GATES ON
#      `Monitor`. Widening the matcher alone leaves such a hook standing down
#      on its own `[ "$tool_name" = "Bash" ] || exit 0`, and the registration
#      then reads as armed while nothing reaches the payload. This arm is the
#      one a reader of the settings diff cannot see.
#
#      The two sides of this test are asymmetric on purpose. The Bash side is
#      a bare mention outside a comment: it over-reports on a body that spells
#      `Bash` for some other reason while admitting `Monitor` implicitly,
#      which is the safe direction, the report sends a human to read one hook
#      where the answer was already fine. The Monitor side cannot take that
#      shortcut, because a bare mention there is exactly the failure this arm
#      exists to catch: a deny-reason string or a comment that SAYS `Monitor`
#      while the hook's own `tool_name` test still admits `Bash` alone. So
#      Monitor admission is judged by a gating construct instead, a case-arm
#      pattern list ending in `)` (`Bash | Monitor)`) or an equality
#      comparison (`= "Monitor"`, `== "Monitor"`), and a hook that gates on
#      `tool_name` through neither shape reads as not admitting `Monitor` even
#      where the word appears elsewhere in its body. Honest limit: a gating
#      shape this check does not recognize, a `case` arm split across lines,
#      a lookup table keyed by tool name, reads as not-admitted too, which is
#      the over-report direction on this side as well and the safe one.
#
# SCOPE is the PreToolUse registrations in .claude/settings.json, derived rather
# than listed, so a newly registered hook carries the obligation the moment it
# is registered. The judgement is PER ROW rather than per hook, because the
# matcher is a property of the row: a hook registered in an
# `Edit|Write|MultiEdit` row and again in a `Bash` row owes `Monitor` on the
# second row alone.
#
# Matcher membership is tested by running the matcher as the ERE it is, against
# the literal tool name, which is the harness's own semantics rather than an
# approximation of them. A matcher grep cannot parse is a finding of the check
# itself (exit 2) rather than a silent no-match, since a no-match would exempt
# the row from both arms at once.
#
# Fail-closed by construction, at each stage guards-must-fail.md names:
#   discovery -- settings.json missing, unparseable, or registering no PreToolUse
#                hook exits 2; so does a surface where no row reaches `Bash`, or
#                where no registered hook is both blocking and command-reading,
#                rather than reporting clean over it
#   arming    -- the posture split comes from the shared oracle and the row set
#                from the registrations, so a hook cannot escape either by being
#                absent from a list this gate keeps. Honest limit: the subject
#                filter needs the literal `tool_input.command` in the hook's
#                OWN body (see `subjects` below), so a command read delegated
#                to a sourced helper carries no obligation this gate can see.
#   match     -- arm B judges `Monitor` admission by a gating construct (a
#                case-arm pattern list or an equality comparison), not by a
#                bare mention, so a deny-reason string or a header paragraph
#                naming `Monitor` does not satisfy it
#
# Bash 3.2 compatible. Never `cd` (beyond resolving this script's own location).

set -uo pipefail

readonly PROG="lint-hook-monitor-arming"

readonly SETTINGS=".claude/settings.json"

# names_outside_comments <needle> <hook_script_path>
#
# Succeed when the fixed string appears on a line that is not a full-line
# comment. Every hook in this tree discusses the payload fields it reads in its
# header, so a search that counted comments would read a paragraph about
# `tool_input.command` as a read of it, and a paragraph naming `Monitor` as an
# arm for it.
names_outside_comments() {
  awk -v needle="$1" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^#/) next
      if (index(line, needle)) { found = 1; exit }
    }
    END { exit(found ? 0 : 1) }
  ' "$2"
}

# admits_monitor <hook_script_path>
#
# Succeed when the hook body GATES ON `Monitor` as a tool_name value, rather
# than merely naming it: a case-arm pattern list ending in `)` that carries
# `Monitor` as one of its bar-separated words (`Bash | Monitor)`), or an
# equality comparison against it (`= "Monitor"`, `== "Monitor"`). A bare
# mention -- a deny-reason string describing the widening, a comment, a
# variable name -- satisfies neither shape.
#
# Both patterns are anchored on shell grammar rather than on the word alone,
# because a prose mention can stand anywhere in a code line and an unanchored
# search over the same line reads it as a gate. The case-arm pattern is
# anchored at the (already comment-stripped and leading-whitespace-stripped)
# START of the line: a real case arm's pattern list IS the line up to its
# `)`, so requiring the match to start at position 0 excludes `Monitor`
# appearing after other prose on the same line, `(Bash or Monitor)` inside a
# deny-reason string included. The equality pattern requires a whitespace
# character immediately before the `=`/`==`: valid bash assignment
# (`reason="...Monitor..."`) carries no space before its `=`, while a `[ ]` or
# `[[ ]]` comparison (`[ "$tool_name" = "Monitor" ]`) requires one, so the
# space is the discriminator between the two shapes rather than an assumption
# about spacing style.
#
# This is deliberately not names_outside_comments('Monitor', ...), which the
# Bash side of arm B still uses: over-reporting on the Bash side sends a human
# to read one hook where the answer was already fine, which is cheap and
# recoverable. Under-reporting on the Monitor side is the failure this arm
# exists to catch in the first place, a hook whose deny-reason string SAYS
# Monitor while its own tool_name test still admits Bash alone, so a bare
# substring match cannot back this side.
admits_monitor() {
  awk '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^#/) next
      if (line ~ /^([A-Za-z_][A-Za-z_0-9]*[[:space:]]*\|[[:space:]]*)*Monitor[[:space:]]*(\|[[:space:]]*[A-Za-z_][A-Za-z_0-9]*[[:space:]]*)*\)/) { found = 1; exit }
      if (line ~ /[[:space:]]==?[[:space:]]*"?Monitor"?([^A-Za-z0-9_]|$)/) { found = 1; exit }
    }
    END { exit(found ? 0 : 1) }
  ' "$1"
}

# matcher_reaches <matcher> <tool_name>
#
# Succeed when the registration's matcher selects the named tool. An EMPTY or
# absent matcher selects every tool, which is what the harness does with one,
# so it reaches both names here rather than neither.
#
# Status 2 from grep is a BAD MATCHER rather than a no-match, and the caller
# turns it into the check's own failure: a matcher this gate silently read as
# matching nothing would exempt its row from both arms, which is the one
# outcome a gate against a silent bypass must not produce.
matcher_reaches() {
  local matcher="$1" tool="$2"
  [ -n "$matcher" ] || return 0
  grep -qE -- "$matcher" <<<"$tool" 2>/dev/null
  case "$?" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

main() {
  local root
  if [ "$#" -gt 1 ]; then
    printf '%s: too many arguments\n' "$PROG" >&2
    printf 'usage: bash .gaia/scripts/%s.sh [<repo_root>]\n' "$PROG" >&2
    return 2
  fi
  if [ "$#" -eq 1 ]; then
    root="$1"
    if [ ! -d "$root" ]; then
      printf '%s: not a directory: %s\n' "$PROG" "$root" >&2
      return 2
    fi
  else
    root="$(git rev-parse --show-toplevel 2>/dev/null)" || root=''
    if [ -z "$root" ]; then
      printf '%s: not inside a git repository and no <repo_root> given\n' "$PROG" >&2
      return 2
    fi
  fi

  if ! command -v jq >/dev/null 2>&1; then
    printf '%s: jq is required to read %s and is not on PATH\n' "$PROG" "$SETTINGS" >&2
    return 2
  fi
  if [ ! -f "$root/$SETTINGS" ]; then
    printf '%s: settings file not found: %s\n' "$PROG" "$SETTINGS" >&2
    return 2
  fi
  if ! jq -e . "$root/$SETTINGS" >/dev/null 2>&1; then
    printf '%s: %s is missing, unreadable, or not valid JSON\n' "$PROG" "$SETTINGS" >&2
    return 2
  fi

  # One row per registered command, carrying the matcher its row was written
  # with. The row index rides along so a report names which of several
  # same-matcher rows carries the hit.
  local rows
  rows="$(
    jq -r '
      .hooks.PreToolUse // []
      | to_entries[]
      | .key as $row
      | (.value.matcher // "") as $matcher
      | (.value.hooks // [])[]
      | .command // empty
      | "\($row)\t\($matcher)\t\(.)"
    ' "$root/$SETTINGS" 2>/dev/null
  )"
  if [ -z "$rows" ]; then
    printf '%s: discovery found no hook registered on PreToolUse in %s.\n' "$PROG" "$SETTINGS" >&2
    printf 'This tree registers dozens; an empty set is a broken read of the registration\n' >&2
    printf 'shape, and every row below it would then grade as correct having been compared\n' >&2
    printf 'against nothing.\n' >&2
    return 2
  fi

  local bash_registrations=0 subjects=0
  local unarmed='' inert=''
  local line row matcher command hook path
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    row="${line%%	*}"
    line="${line#*	}"
    matcher="${line%%	*}"
    command="${line#*	}"

    case "$command" in
      *.claude/hooks/*) ;;
      *) continue ;;
    esac
    hook="$(gaia_hook_name_from_command "$command")"
    [ -n "$hook" ] || continue
    path="$root/.claude/hooks/$hook"
    # A registration naming a script that is not present is a separate defect
    # with its own owner; skipping it keeps this check speaking only about the
    # arming question.
    [ -f "$path" ] || continue

    local reaches_bash=0 reaches_monitor=0
    matcher_reaches "$matcher" Bash
    case "$?" in
      0) reaches_bash=1 ;;
      1) reaches_bash=0 ;;
      *)
        printf '%s: PreToolUse row %s carries a matcher grep cannot read as an ERE: %s\n' \
          "$PROG" "$row" "$matcher" >&2
        printf 'A matcher this gate cannot evaluate would exempt its row from both arms, so it\n' >&2
        printf 'fails the check rather than passing it. Repair the matcher.\n' >&2
        return 2
        ;;
    esac
    matcher_reaches "$matcher" Monitor
    case "$?" in
      0) reaches_monitor=1 ;;
      1) reaches_monitor=0 ;;
      *)
        printf '%s: PreToolUse row %s carries a matcher grep cannot read as an ERE: %s\n' \
          "$PROG" "$row" "$matcher" >&2
        return 2
        ;;
    esac

    if [ "$reaches_monitor" -eq 1 ]; then
      # Arm B. A hook that names neither tool has nothing to stand it down, so
      # the widened matcher reaches its payload read on its own.
      if names_outside_comments 'Bash' "$path" &&
        ! admits_monitor "$path"; then
        inert="$inert$hook	row $row arms Monitor, but the hook body admits Bash alone
"
      fi
    fi

    [ "$reaches_bash" -eq 1 ] || continue
    bash_registrations=$((bash_registrations + 1))

    names_outside_comments 'tool_input.command' "$path" || continue
    gaia_hook_blocks "$path" || continue
    subjects=$((subjects + 1))

    [ "$reaches_monitor" -eq 1 ] && continue
    unarmed="$unarmed$hook	row $row matcher '$matcher' reaches Bash but not Monitor
"
  done <<EOF
$rows
EOF

  if [ "$bash_registrations" -eq 0 ]; then
    printf '%s: discovery found no PreToolUse registration whose matcher reaches Bash.\n' "$PROG" >&2
    printf 'This tree registers many; an empty set is the matcher evaluation failing rather\n' >&2
    printf 'than a layer that binds no shell command, and every row would grade as correct\n' >&2
    printf 'having been skipped.\n' >&2
    return 2
  fi
  if [ "$subjects" -eq 0 ]; then
    printf '%s: discovery found no blocking, command-reading PreToolUse hook on a Bash row.\n' "$PROG" >&2
    printf 'This tree registers many that deny outright on the command they are handed, so an\n' >&2
    printf 'empty subject set is the blocking oracle in .gaia/scripts/hook-registration-lib.sh\n' >&2
    printf 'or the command-read probe failing to read a hook body. The obligation would then\n' >&2
    printf 'bind nothing.\n' >&2
    return 2
  fi

  local findings=0 entry
  if [ -n "$unarmed" ]; then
    printf '%s: blocking PreToolUse guards a Monitor-armed command walks past:\n' "$PROG" >&2
    printf '%s' "$unarmed" | while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      printf '  .claude/hooks/%s\n' "$entry" >&2
    done
    findings=1
  fi
  if [ -n "$inert" ]; then
    printf '%s: hooks whose matcher arms Monitor while the hook itself stands down on it:\n' "$PROG" >&2
    printf '%s' "$inert" | while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      printf '  .claude/hooks/%s\n' "$entry" >&2
    done
    findings=1
  fi

  if [ "$findings" -ne 0 ]; then
    printf '\n%s: the Monitor tool hands a hook the same raw shell command in the same\n' "$PROG" >&2
    printf 'tool_input.command field and runs it in the same shell environment, so a guard\n' >&2
    printf 'bound to Bash alone refuses nothing a caller arms through Monitor. Widen the\n' >&2
    printf "row's matcher to reach both, AND widen whatever tool_name test the hook carries,\n" >&2
    printf 'or neither half does anything on its own.\n' >&2
    return 1
  fi
  printf '%s: clean\n' "$PROG"
  return 0
}

# The PreToolUse name spelling and the blocking oracle are shared with
# .gaia/scripts/lint-hook-jq-availability.sh and
# .gaia/scripts/lint-hook-advisory-classification.sh, which ask different
# questions of the same two answers. Rooted at this script's own on-disk
# location so it resolves however the gate is invoked.
_gaia_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || _gaia_lib_dir=''
if [ -z "$_gaia_lib_dir" ] || [ ! -f "$_gaia_lib_dir/hook-registration-lib.sh" ]; then
  printf '%s: cannot load hook-registration-lib.sh beside this script\n' "$PROG" >&2
  exit 2
fi
# shellcheck source=hook-registration-lib.sh
. "$_gaia_lib_dir/hook-registration-lib.sh"

trap 'exit 130' INT
trap 'exit 143' TERM

main "$@"
