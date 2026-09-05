#!/usr/bin/env bash
# shellcheck shell=bash
#
# lint-hook-wiki-inventory.sh: flag every hook registered in
# .claude/settings.json that wiki/concepts/Claude Hooks.md does not mention.
# Exit 0 when every registered hook appears on the page, 1 with a per-hook
# report on any gap, 2 on the check's own failure, and 130 or 143 when a SIGINT
# or SIGTERM interrupts it (see the trap arms in main). Run it from anywhere:
# `bash .gaia/scripts/lint-hook-wiki-inventory.sh [<repo_root>]`.
#
# The page's `## Bundled hooks` section presents itself as the inventory of the
# hooks GAIA registers, and every reader treats it as complete: an agent or a
# maintainer enumerating the hook layer reads that section and stops. It is
# hand-kept, and a hand-kept list is itself the arming stage
# .claude/rules/guards-must-fail.md warns about. It goes stale the moment a hook
# is registered without a matching entry, silently, and the staleness surfaces
# only when someone audits the page against settings.json by hand.
#
# Issue #1786 is that failure observed at four hooks at once:
# block-selfheal-paths.sh, block-serena-cross-tree-activation.sh,
# debt-session-reconcile.sh and provision-worktree.sh had each been registered
# and left off the page, 43 registered against 39 inventoried, and the page kept
# reading as authoritative the whole time. The bad outcome is a silent wrong
# answer rather than a broken build: a change that should have considered one of
# the four never looks at it. This check is what makes the next omission red on
# the pull request that registers the hook instead of on an audit round some
# months later.
#
# ONE DIRECTION, deliberately. This asks only whether every REGISTERED hook is
# mentioned; it does not ask whether every hook the page names is still
# registered. The reverse question needs a parse of the page rather than a
# membership test against it, because the page legitimately names shell that is
# not a registered hook -- the sourced libraries under .claude/hooks/lib/, and
# the .gaia/scripts/ guards its "Adding hooks" section points at -- so a naive
# reverse sweep would report each of those as a stale entry. A de-registered
# hook left on the page is real drift and is not covered here; it is worth its
# own check when it happens, written against a parse that can tell an inventory
# entry from a mention.
#
# MENTION, not entry shape. A registered hook counts as inventoried when its
# basename appears anywhere in the page, which is weaker than "has an entry in
# the shape the other entries use" and is chosen for having no false-positive
# class at all: a hook named in the section prose, or under a path prefix, is
# genuinely reachable by a reader searching the page. The omission this exists
# to catch is total absence, which is what #1786 was and what a whole-page grep
# is exactly the right instrument for. A check that also judged entry shape
# would red on prose it has no business grading.
#
# Fail-closed by construction, at each stage guards-must-fail.md names:
#   discovery -- settings.json missing, unparseable, or yielding no registered
#                hook at all exits 2, never 0
#   arming    -- a missing or empty inventory page exits 2
#   match     -- the membership test is a fixed-string search for the basename,
#                so it neither depends on the entry's surrounding markup nor
#                admits a regex metacharacter in a filename
#
# Bash 3.2 compatible. Never `cd` (outside the argument-free root resolution).

set -uo pipefail

readonly PROG="lint-hook-wiki-inventory"

# The registered-hook listing is staged through this file (see the discovery
# block in main). It is script-scoped rather than a local in main because the
# EXIT arm that unlinks it runs after main has returned on the ordinary path,
# with the frame already popped and a local out of reach by then, so a local
# would leave the file behind on every clean run.
LIST_FILE=''

# The two subjects, each named once.
readonly SETTINGS=".claude/settings.json"
readonly INVENTORY="wiki/concepts/Claude Hooks.md"

# The one spelling of a hook name inside a registration command, named once and
# read by both consumers: `registered_hooks` extracts with it, and main's
# unreadable-spelling arm selects the commands it does NOT match. Those two are
# the same question asked in opposite directions, so they must move together.
# Spelled separately they would not: the arm's own refusal tells the fixer to
# teach `registered_hooks` a new spelling, and doing exactly that would leave
# the arm still selecting the command and refusing again, now with a message
# that has become false, while the suite stayed green.
readonly HOOK_NAME_RE='\.claude/hooks/[A-Za-z0-9_./-]+\.sh'

# hook_commands <repo_root>
#
# Print every `.hooks.<Event>[].hooks[].command` string in settings.json that
# names `.claude/hooks/`, one per line. This is the set main's
# unreadable-spelling arm tests one command at a time.
hook_commands() {
  local root="$1"
  jq -r '
    .hooks // {}
    | to_entries[]
    | .value[]?
    | .hooks[]?
    | .command // empty
  ' "$root/$SETTINGS" 2>/dev/null |
    grep -F '.claude/hooks/'
}

# registered_hooks <repo_root>
#
# Print every hook script registered under `.hooks` in settings.json as its
# path relative to `.claude/hooks/`, one per line, sorted and deduplicated.
#
# Scoped to commands naming `.claude/hooks/`, which is what makes this the
# registered-HOOK set rather than every `.sh` a hook command happens to mention.
# The registration shape is `.hooks.<Event>[].hooks[].command`, and the command
# is a quoted absolute path built from a root expansion, so the name is
# recovered from the path text rather than from the JSON structure.
#
# The character class carries `/` deliberately. Without it the match cannot
# cross a directory separator, so a hook registered one level down
# (`.claude/hooks/nested/beta.sh`) yields no match at all and never enters the
# set compared against the page: the check then reports clean over a registered
# hook the inventory never mentions. That is a partial drop rather than a total
# one, so the empty-set arm in main cannot see it, which is exactly the
# discovery-stage fail-open `.claude/rules/guards-must-fail.md` names. Every
# registration in this tree is flat under `.claude/hooks/` today, so the class
# is armed against the shape rather than against a live instance; the
# unreadable-spelling arm in main is the fail-closed backstop for a command
# this pattern cannot read at all, and it reaches no further than that (see
# the limit stated at that arm).
registered_hooks() {
  local root="$1"
  hook_commands "$root" |
    grep -oE "$HOOK_NAME_RE" |
    sed -e 's#^\.claude/hooks/##' |
    sort -u
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

  # Arming. Both conditions exit 2 rather than 1, and they are separated
  # because the repairs differ: an absent page is a moved or deleted file, an
  # empty one is a truncated write. Either would otherwise report every
  # registered hook as uninventoried, which reads as 43 findings and is really
  # one broken subject.
  if [ ! -f "$root/$INVENTORY" ]; then
    printf '%s: inventory page not found: %s\n' "$PROG" "$INVENTORY" >&2
    return 2
  fi
  if [ ! -s "$root/$INVENTORY" ]; then
    printf '%s: inventory page is empty: %s\n' "$PROG" "$INVENTORY" >&2
    return 2
  fi
  if [ ! -f "$root/$SETTINGS" ]; then
    printf '%s: settings file not found: %s\n' "$PROG" "$SETTINGS" >&2
    return 2
  fi

  # Discovery, staged through a file rather than a variable so jq's own failure
  # stays distinguishable from a settings file that registers nothing: a parse
  # that failed and a tree with no hooks are different conditions owed different
  # messages, and a pipeline or a process substitution would merge them into one
  # unreadable answer.
  LIST_FILE="$(mktemp "${TMPDIR:-/tmp}/$PROG.XXXXXX")" || {
    printf '%s: could not create a temporary file for the registered-hook listing\n' "$PROG" >&2
    return 2
  }
  # Three arms, not one shared arm. Bash resumes at the point of interruption
  # once a trapped signal handler returns, so a single `EXIT INT TERM` arm that
  # only unlinks the file leaves Ctrl-C removing the temp file and the check
  # running on to print its verdict as if uninterrupted. The signal arms exit,
  # and the EXIT arm they fall into owns the removal.
  trap 'rm -f "$LIST_FILE"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if ! jq -e . "$root/$SETTINGS" >/dev/null 2>&1; then
    printf '%s: %s is missing, unreadable, or not valid JSON\n' "$PROG" "$SETTINGS" >&2
    return 2
  fi
  # The UNREADABLE-SPELLING arm, a different assertion from the non-empty one
  # below rather than a stronger spelling of it. A registration whose command
  # the name pattern cannot read is dropped silently and individually: the set
  # is short rather than empty, so the non-empty arm stays satisfied and the
  # check reports clean over a hook the page may never mention.
  #
  # Ask the question directly, per command, rather than comparing set sizes.
  # A count comparison answers a different question than it appears to: one hook
  # registered on several events with any difference in command text (an added
  # argument, a redirect, a wrapper) is several distinct commands and one name,
  # so the counts differ with nothing wrong and the refusal tells the reader to
  # teach this function a spelling it read correctly. Selecting the commands
  # that yielded no name is exact in this direction and needs no reasoning about
  # duplicate registrations at all.
  #
  # What it reaches, stated so the comment is not read as more: a command from
  # which NO name could be read. A single command naming two hooks, only one of
  # them readable, still yields a name and passes here, so its unreadable half
  # stays invisible. No count-based or per-command presence test reaches that
  # shape; only parsing every name out of every command would, and every
  # registration in this tree names exactly one hook.
  #
  # It runs BEFORE the non-empty arm because the two overlap on one input and
  # only this one describes it correctly. A settings file whose every command
  # names the directory and whose every command is unreadable produces an empty
  # name set, so the non-empty arm below would fire and tell the operator the
  # spelling no longer names `.claude/hooks/`, which is false of every command
  # it just read. Ordered this way the precise cause wins, and it prints the
  # offending command text; the register-nothing case is unaffected, because an
  # empty command set leaves this `grep -v` with nothing to select and falls
  # through to the arm that does describe it.
  local unreadable
  unreadable="$(hook_commands "$root" | grep -vE "$HOOK_NAME_RE")"
  if [ -n "$unreadable" ]; then
    printf '%s: %s registers a hook command naming .claude/hooks/ from which no hook name could be read:\n' \
      "$PROG" "$SETTINGS" >&2
    printf '%s\n' "$unreadable" | sed -e 's/^/  /' >&2
    printf 'A spelling this check cannot parse is dropped silently, so it refuses rather than\n' >&2
    printf 'compare a short set against the page. Teach the HOOK_NAME_RE pattern above the new\n' >&2
    printf 'spelling rather than leaving it to match nothing.\n' >&2
    return 2
  fi

  registered_hooks "$root" >"$LIST_FILE"

  # An empty set is never a clean tree here: this repository registers dozens of
  # hooks, and a discovery that finds none of them would report the inventory
  # complete having compared nothing. By the time this runs the arm above has
  # ruled out an unreadable spelling, so the remaining cause is a settings file
  # whose `hooks` key registers nothing naming `.claude/hooks/` at all.
  if [ ! -s "$LIST_FILE" ]; then
    printf '%s: discovery found no hook registered under .claude/hooks/ in %s.\n' "$PROG" "$SETTINGS" >&2
    printf 'No command under the hooks key names that directory; %s parses as JSON, and every\n' "$SETTINGS" >&2
    printf 'command that does name it was readable, so this is a registration set, not a\n' >&2
    printf 'spelling this check failed to parse.\n' >&2
    return 2
  fi

  local hook findings=0
  while IFS= read -r hook; do
    [ -n "$hook" ] || continue
    grep -qF -- "$hook" "$root/$INVENTORY" && continue
    if [ "$findings" -eq 0 ]; then
      printf '%s: hooks registered in %s that %s never mentions:\n' \
        "$PROG" "$SETTINGS" "$INVENTORY" >&2
    fi
    printf '  %s\n' "$hook" >&2
    findings=$((findings + 1))
  done <"$LIST_FILE"

  if [ "$findings" -gt 0 ]; then
    printf '\n%s: %d registered hook(s) above are absent from the bundled-hooks inventory.\n' \
      "$PROG" "$findings" >&2
    printf 'Add one entry per hook to %s, in the shape the existing entries use,\n' "$INVENTORY" >&2
    printf 'describing what it guards and on which event it fires.\n' >&2
    return 1
  fi
  printf '%s: clean\n' "$PROG"
  return 0
}

main "$@"
