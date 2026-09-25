#!/usr/bin/env bash
# shellcheck shell=bash
#
# lint-hook-jq-availability.sh: flag a PreToolUse hook that parses its payload
# with jq and, when jq is absent, fails OPEN. Exit 0 when clean, 1 with a
# per-hook report on any hit, 2 on the check's own failure, and 130 or 143 when
# a SIGINT or SIGTERM interrupts it. Run it from anywhere:
# `bash .gaia/scripts/lint-hook-jq-availability.sh [<repo_root>]`.
# gaia:maintainer-only:start
#
# Enforced by the sibling bats suite
# .gaia/scripts/tests/lint-hook-jq-availability.bats, which the `Audit CI Tests`
# scripts shard runs, and folded into .gaia/tests/shell-lint.sh, whose `**/*.sh`
# and `.claude/settings.json` paths-filter entries between them arm it on both
# surfaces it reads.
# gaia:maintainer-only:end
#
# Why: a hook arms `set -euo pipefail` and reads its payload with jq. On a
# machine with no jq on PATH that read ends the script at status 127 before the
# payload has been looked at, and the PreToolUse contract
# (`wiki/concepts/Claude Hooks.md`) blocks only on exit 2 and treats every other
# non-zero status as a NON-BLOCKING error. The tool call proceeds, with no
# denial and no diagnostic the operator will see, so the whole fail-closed layer
# goes silently inert while the advisory hooks correctly no-op.
#
# The `|| exit 0` spelling is the same defect wearing a guard. A blocking hook
# that stands down on a missing interpreter has decided the call is allowed
# without reading it, which is the outcome the exit-127 path produces by
# accident. So this gate does not ask whether an availability guard EXISTS; it
# asks whether the guard a blocking hook carries can still refuse. A gate keyed
# on the presence of `command -v jq` reports clean over a blocking hook whose
# arm only ever stands it down.
#
# THE TWO POSTURES, and which hook takes which:
#   blocking  -- the hook can stop a tool call, so it must reach the shared arm
#                (`gaia_require_jq`, .claude/hooks/lib/jq-availability.sh), which
#                refuses with exit 2, narrowed by the caller's own binding
#                literals where its matcher can reach the jq install itself.
#   advisory  -- the hook only ever nudges, so standing down costs a reminder and
#                nothing else. `command -v jq >/dev/null 2>&1 || exit 0` is right
#                for it, and refusing would be wrong.
# Which posture a hook has is not this gate's judgement: it reads the same
# blocking oracle .gaia/scripts/lint-hook-monitor-arming.sh reads, out of
# .gaia/scripts/hook-registration-lib.sh, so a hook cannot be blocking for one
# gate and advisory for the other.
#
# SCOPE is the PreToolUse registrations in .claude/settings.json, derived rather
# than listed, so a newly registered hook carries the obligation the moment it is
# registered. It is the right surface rather than `.claude/hooks/*.sh` because
# the fail-open this gate exists for is a PreToolUse semantic: a script under
# that directory which no registration names is invoked directly by a caller who
# sees its exit status, and owes nothing here.
#
# Fail-closed by construction, at each stage guards-must-fail.md names:
#   discovery -- settings.json missing, unparseable, or registering no PreToolUse
#                hook exits 2; a surface where no hook calls jq at all, or where
#                none blocks, exits 2 rather than reporting clean over it
#   arming    -- the posture split comes from the shared oracle, not from a list
#                this gate keeps, so a hook cannot escape by being absent from one
#   match     -- the blocking arm test anchors on the shared function's COMMAND
#                POSITION, so neither a header paragraph naming it nor the loader
#                block that mentions it above the call satisfies the check
#
# Bash 3.2 compatible. Never `cd` (beyond resolving this script's own location).

set -uo pipefail

readonly PROG="lint-hook-jq-availability"

readonly SETTINGS=".claude/settings.json"

# Blocking PreToolUse hooks whose jq arm still stands the hook down instead of
# refusing.
#
# The current entries stand down by design, not pending a conversion: neither
# guard protects a secret, main, or the merge gate, so a jq-less machine
# losing them fails open on nothing that needs a refusal.
#
# It stays a named variable rather than going away with its last entry, because
# the shape is what a conversion that cannot land in one change needs: a hook
# registered before its arm can be written goes here, tracked by issue, and is
# read out again by the exact-assert below.
#
# The list is asserted EXACT below: an entry that no longer fails is reported so
# it must be deleted here, which is what keeps a baseline from quietly becoming
# a permanent exemption.
BASELINE="block-bare-test.sh
red-verify-commit-check.sh"

# uses_jq <hook_script_path>
#
# Succeed when the script invokes jq outside a full-line comment. The probe pads
# the line so the character before `jq` can be tested without an anchor
# alternation, and the negated class carries `_`, `.`, `-` and `/` so the
# library's own name (`lib/jq-availability.sh`), the loader variable
# (`_jq_lib_dir`) and the shared function (`gaia_require_jq`) are not read as
# invocations. The accepted miss that buys: an absolute invocation
# (`/usr/bin/jq`) reads as the library's name and is not seen. No hook spells it
# that way, and one that did would be defeating PATH resolution deliberately.
uses_jq() {
  awk '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^#/) next
      probe = " " line " "
      if (probe ~ /[^A-Za-z0-9_.\/-]jq[[:space:]]/) { found = 1; exit }
    }
    END { exit(found ? 0 : 1) }
  ' "$1"
}

# calls_in_command_position <needle> <hook_script_path>
#
# Succeed when the fixed string opens a non-comment line as its command word,
# i.e. the line begins with it and the next character is whitespace.
#
# COMMAND POSITION, not "anywhere on the line", and the difference is the whole
# assertion. Every armed hook carries a loader block that mentions the shared
# function several lines above the call, in `if ! type gaia_require_jq ...`, so
# a search that matched anywhere would be satisfied by the loader alone: a newly
# registered blocking hook that copies the loader and omits the call would grade
# clean while its payload read still ends the hook at 127, which is the exact
# fail-open this gate exists to catch. Anchoring on the command word admits every
# hook that actually calls it, indented or not, and no hook that only names it.
calls_in_command_position() {
  awk -v needle="$1" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^#/) next
      if (index(line, needle) == 1 && substr(line, length(needle) + 1, 1) ~ /[[:space:]]/) {
        found = 1
        exit
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$2"
}

# names_outside_comments <needle> <hook_script_path>
#
# Succeed when the fixed string appears on a line that is not a full-line
# comment. The advisory arm is a bare `command -v jq` test rather than a call, so
# it has no command position to anchor on; a hook whose header merely discusses
# it still does not satisfy this, because a full-line comment is skipped.
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

  local registered hook path
  registered="$(gaia_pretooluse_hooks "$root")"
  if [ -z "$registered" ]; then
    printf '%s: discovery found no hook registered on PreToolUse in %s.\n' "$PROG" "$SETTINGS" >&2
    printf 'This tree registers dozens; an empty set is a broken read of the registration\n' >&2
    printf 'shape, and every hook below it would then grade as correct having been compared\n' >&2
    printf 'against nothing.\n' >&2
    return 2
  fi

  local parsers=0 blocking=0 unguarded='' baselined=''
  while IFS= read -r hook; do
    [ -n "$hook" ] || continue
    path="$root/.claude/hooks/$hook"
    # A registration naming a script that is not present is a separate defect
    # with its own owner; skipping it keeps this check speaking only about the
    # availability arm.
    [ -f "$path" ] || continue
    uses_jq "$path" || continue
    parsers=$((parsers + 1))

    if gaia_hook_blocks "$path"; then
      blocking=$((blocking + 1))
      calls_in_command_position 'gaia_require_jq' "$path" && continue
      if grep -qxF -- "$hook" <<<"$BASELINE"; then
        baselined="$baselined$hook
"
        continue
      fi
      unguarded="$unguarded$hook	blocking, and no gaia_require_jq call reaches its payload read
"
      continue
    fi

    names_outside_comments 'command -v jq' "$path" && continue
    unguarded="$unguarded$hook	advisory, and no jq-availability arm stands it down
"
  done <<EOF
$registered
EOF

  if [ "$parsers" -eq 0 ]; then
    printf '%s: discovery found no PreToolUse hook that parses its payload with jq.\n' "$PROG" >&2
    printf 'Nearly every hook in this tree does, so this is the invocation probe failing to\n' >&2
    printf 'read a hook body rather than a layer that parses nothing. Every hook would grade\n' >&2
    printf 'as correct having been skipped.\n' >&2
    return 2
  fi
  if [ "$blocking" -eq 0 ]; then
    printf '%s: discovery classified every jq-parsing PreToolUse hook as advisory.\n' "$PROG" >&2
    printf 'This tree registers many that deny outright, so this is the blocking oracle in\n' >&2
    printf '.gaia/scripts/hook-registration-lib.sh failing to read a hook body. The blocking\n' >&2
    printf 'obligation would then bind nothing.\n' >&2
    return 2
  fi

  # A baseline entry that no longer fails is a finding of its own: left in place
  # it becomes a standing exemption for a hook that has since been repaired, and
  # the next hook to regress under that name would be waved through.
  #
  # An entry naming a script the tree does not carry is SKIPPED rather than
  # reported. The alternative reports every baseline entry as stale against a
  # fixture tree, since a fixture registers its own hooks and carries none of
  # the ones a real baseline names; and in the real tree a deleted hook leaves
  # an entry that names nothing and exempts nothing, which is inert rather than
  # dangerous.
  local stale='' entry
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    [ -f "$root/.claude/hooks/$entry" ] || continue
    grep -qxF -- "$entry" <<<"$baselined" && continue
    stale="$stale$entry
"
  done <<EOF
$BASELINE
EOF

  local findings=0
  if [ -n "$unguarded" ]; then
    printf '%s: PreToolUse hooks whose jq arm fails open:\n' "$PROG" >&2
    printf '%s' "$unguarded" | while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      printf '  .claude/hooks/%s\n' "$entry" >&2
    done
    findings=1
  fi
  if [ -n "$stale" ]; then
    printf '%s: baseline entries that no longer fail:\n' "$PROG" >&2
    printf '%s' "$stale" | while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      printf '  %s\n' "$entry" >&2
    done
    printf 'Each is repaired, unregistered, or no longer parses its payload with jq. Delete it\n' >&2
    printf 'from BASELINE in this script so the name stops carrying an exemption.\n' >&2
    findings=1
  fi

  if [ "$findings" -ne 0 ]; then
    printf '\n%s: a blocking PreToolUse hook that cannot read its payload must refuse, not\n' "$PROG" >&2
    printf 'stand down: exit 2 is the only status the contract reads as a block. Call\n' >&2
    printf 'gaia_require_jq (.claude/hooks/lib/jq-availability.sh) right after the payload is\n' >&2
    printf 'read, passing the literals whose absence proves the call sits outside the hook\n' >&2
    printf 'remit when its matcher can reach the jq install itself.\n' >&2
    return 1
  fi
  printf '%s: clean\n' "$PROG"
  return 0
}

# The PreToolUse registration read and the blocking oracle are shared with
# .gaia/scripts/lint-hook-monitor-arming.sh, which asks a different question
# of the same two answers. Rooted at this script's own on-disk location so it
# resolves however the gate is invoked.
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
