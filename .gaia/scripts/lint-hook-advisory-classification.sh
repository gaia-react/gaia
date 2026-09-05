#!/usr/bin/env bash
# shellcheck shell=bash
#
# lint-hook-advisory-classification.sh: flag a hook that BLOCKS but is filed
# under an Advisory heading on a wiki page. Exit 0 when no advisory section
# names a blocking hook, 1 with a per-entry report on any hit, 2 on the check's
# own failure, and 130 or 143 when a SIGINT or SIGTERM interrupts it. Run it
# from anywhere:
# `bash .gaia/scripts/lint-hook-advisory-classification.sh [<repo_root>]`.
# gaia:maintainer-only:start
#
# Enforced by the sibling bats suite
# .gaia/scripts/tests/lint-hook-advisory-classification.bats, which the
# `Audit CI Tests` scripts shard runs, and folded into .gaia/tests/shell-lint.sh,
# whose `**/*.md`, `**/*.sh` and `.claude/settings.json` paths-filter entries
# between them arm it on all three surfaces it reads.
# gaia:maintainer-only:end
#
# Why: .gaia/scripts/lint-hook-wiki-inventory.sh asks whether every registered
# hook is MENTIONED on the inventory page, and says in its own header that it
# deliberately asks only that. Presence is not the only thing a hook page
# claims. It also CLASSIFIES: a reader deciding whether an action will be
# stopped reads the heading a hook sits under and stops there. A blocking hook
# filed as advisory is a silent wrong answer of the worse kind, because the page
# reads as authoritative and the reader has no cue to check. It stood on two
# pages at once (`pr-merge-audit-check.sh`, which denies `gh pr merge` until
# every dispatched audit member has cleared, filed as "reminds to run the
# audit"), and neither the inventory guard nor any review round saw it: the hook
# was mentioned, so presence was satisfied, and the classification is prose
# nothing compared against the script.
#
# ONE DIRECTION, deliberately, and the opposite one from the inventory guard's.
# This asks only whether a hook filed as ADVISORY blocks. It does not ask
# whether every hook filed as blocking still blocks. The reverse needs a parse
# of what a blocking section CLAIMS about each entry rather than a membership
# test, and those sections legitimately name hooks they are not classifying --
# a sibling PostToolUse recorder named inside a blocking entry's prose is the
# live example -- so a naive reverse sweep would report each of those as a
# misfiled entry. That direction is real drift and is worth its own check
# written against a parse that can tell an entry from a mention.
#
# ENTRY SHAPE, not mention, which is the inversion of the inventory guard's
# choice and is right for the opposite reason. The inventory guard wants
# mention, because a hook named anywhere on the page is reachable by a reader
# searching it, and mention therefore has no false-positive class for a
# PRESENCE question. Classification is not conferred by a mention: a sentence
# reading "unlike block-rm-rf.sh, this one only nudges" names a blocking hook
# inside an advisory section and is entirely correct prose. What confers the
# classification is the list ENTRY, so only the name inside the item's LEADING
# CODE SPAN is graded, which is the shape every entry on these pages uses:
# an optional bold wrapper around a backtick-delimited filename, at the head of
# the item.
#
# The leading span, not "the text before the first colon", and the difference is
# a whole false-positive class rather than a refinement. Keying on the colon
# leaves a bullet that carries none, or one whose colon falls after the name,
# scanning the entire line, so ordinary cross-referencing prose in an advisory
# section reds the check and is handed a repair instruction telling the author
# to move an entry that is not an entry. The span test has no such fallback: a
# bullet with no leading code span is graded not at all.
#
# THE ORACLE, and its one deliberate asymmetry. A hook BLOCKS when it is
# registered on PreToolUse and its body, comments excluded, either emits a
# `permissionDecision` or exits 2 -- the two mechanisms by which a PreToolUse
# hook stops a tool call. PostToolUse, Stop, SessionStart and the rest cannot
# stop anything, so a hook registered only on those is never blocking here
# whatever its exit codes. The `exit 2` half reads text rather than control
# flow, so a literal 2 inside a heredoc or a string over-classifies. That
# direction is the safe one: over-classifying can only red a hook that is ALSO
# filed as advisory, where a human then reads both and settles it, while
# under-classifying returns a page silently wrong about whether an action stops.
#
# Fail-closed by construction, at each stage guards-must-fail.md names:
#   discovery -- settings.json missing, unparseable, registering no PreToolUse
#                hook, or yielding no blocking hook at all, exits 2
#   arming    -- no tracked wiki markdown at all exits 2, never 0
#   match     -- the entry test is a fixed-string search for the basename inside
#                a list item, so it admits no regex metacharacter in a filename
#
# Bash 3.2 compatible. Never `cd`.

set -uo pipefail

readonly PROG="lint-hook-advisory-classification"

readonly SETTINGS=".claude/settings.json"

# The blocking-hook listing is staged through this file. Script-scoped rather
# than a local in main because the EXIT arm that unlinks it runs after main has
# returned on the ordinary path, with the frame already popped.
BLOCKING_FILE=''

# The one spelling of a hook name inside a registration command, named once.
readonly HOOK_NAME_RE='\.claude/hooks/[A-Za-z0-9_./-]+\.sh'

# pretooluse_hooks <repo_root>
#
# Print every hook script registered under `.hooks.PreToolUse` as its path
# relative to `.claude/hooks/`, one per line, sorted and deduplicated.
pretooluse_hooks() {
  local root="$1"
  jq -r '
    .hooks.PreToolUse // []
    | .[]
    | .hooks[]?
    | .command // empty
  ' "$root/$SETTINGS" 2>/dev/null |
    grep -F '.claude/hooks/' |
    grep -oE "$HOOK_NAME_RE" |
    sed -e 's#^\.claude/hooks/##' |
    sort -u
}

# blocks <hook_script_path>
#
# Succeed when the script can stop a tool call: it emits a permissionDecision,
# or it exits 2. Full-line comments are excluded, which is load-bearing rather
# than tidy -- at least one advisory hook here carries the string `exit 2` in a
# paragraph of its header explaining a failure mode it does NOT cause, and
# grading that as a block would misfile a correctly-filed advisory hook.
#
# ONE awk PASS, not a `grep -v | grep -q` pipeline, and the reason is a fail-open
# this check was caught by on its first run against the live tree. `grep -q`
# exits at its first match and closes the pipe under it; the upstream grep then
# takes SIGPIPE and returns 141, and `set -o pipefail` promotes that to the
# pipeline's status. The function returned non-zero ON A MATCH, so every hook
# whose upstream lost that race classified as advisory and the check reported
# clean over the very defect it was written for. A single process cannot lose
# that race.
#
# The `exit 2` test pads the line on both sides so the surrounding-character
# class needs no anchor alternation: with a leading and trailing space, a bare
# `exit 2` matches and `exit 22` cannot.
blocks() {
  awk '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^#/) next
      if (index(line, "permissionDecision")) { found = 1; exit }
      probe = " " line " "
      if (probe ~ /[^A-Za-z0-9_]exit 2[^0-9]/) { found = 1; exit }
    }
    END { exit(found ? 0 : 1) }
  ' "$1"
}

# advisory_entries <page_path>
#
# Print `<line-number>:<hook-basename>` for every markdown list item that sits
# under a heading whose text carries "advisory" and names a `.sh` file in its
# leading position. A section runs from its heading to the next heading of the
# same or shallower level, which is what stops a nested subsection from
# escaping the classification and what stops a following sibling section from
# inheriting it.
advisory_entries() {
  awk '
    /^#+[[:space:]]/ {
      # Heading depth is the run of leading "#".
      depth = 0
      while (substr($0, depth + 1, 1) == "#") depth++
      if (inadvisory && depth <= advisory_depth) inadvisory = 0
      if (!inadvisory) {
        text = tolower($0)
        if (index(text, "advisory")) { inadvisory = 1; advisory_depth = depth }
      }
      next
    }
    inadvisory && /^[[:space:]]*[-*][[:space:]]/ {
      # The entry position is the LEADING CODE SPAN of the list item, which is
      # where every entry on these pages puts the name it is classifying. Prose
      # elsewhere in the item may name any hook it likes without being graded,
      # and an item that opens with prose rather than a span is not an entry and
      # is graded not at all.
      head = $0
      sub(/^[[:space:]]*[-*][[:space:]]+/, "", head)   # the list marker
      sub(/^\*\*/, "", head)                           # an optional bold wrapper
      if (substr(head, 1, 1) != "`") next
      head = substr(head, 2)
      c = index(head, "`")
      if (c == 0) next
      head = substr(head, 1, c - 1)
      if (match(head, /[A-Za-z0-9_.-]+\.sh/))
        printf "%d:%s\n", NR, substr(head, RSTART, RLENGTH)
    }
  ' "$1"
}

# empty_discovery_cause <repo_root>
#
# Print the cause of an empty tracked-page listing. THREE conditions reach that
# arm and the repair differs for each, so each is named rather than one of them
# being named confidently (.claude/rules/partial-cause-reporting.md):
#
#   not a repository          -- git has already printed its own diagnostic above
#   a root below the toplevel -- git exits 0 and prints NOTHING, which is the
#                                silent one: the listing is scoped to the
#                                directory it is given, so the operator would
#                                otherwise be sent to inspect a wiki tree that is
#                                fine while the repair is the root they passed
#   a genuinely empty wiki    -- the remaining case
#
# The middle case is why the git-diagnostic heuristic alone is not enough: its
# absence does not mean the wiki is empty.
empty_discovery_cause() {
  local root="$1" prefix
  printf '%s: discovery listed no tracked markdown under wiki/ in %s.\n' "$PROG" "$root"
  # `--show-prefix`, not a comparison against `--show-toplevel`. The toplevel
  # comes back as a PHYSICAL path, so on a host where the caller passed a path
  # through a symlink -- /tmp on macOS is /private/tmp -- the two strings differ
  # for a root that IS the toplevel, and the comparison reports the wrong cause
  # confidently. The prefix answers the question directly: it is the empty
  # string exactly when the root is the toplevel, whatever spelling reached it.
  if ! prefix="$(git -C "$root" rev-parse --show-prefix 2>/dev/null)"; then
    printf 'Cause: %s is not a usable git repository; the git diagnostic above this line\n' "$root"
    printf 'states which. Pass a root that is a working checkout.\n'

    return 0
  fi
  if [ -n "$prefix" ]; then
    printf 'Cause: %s sits below its repository toplevel, at %s within it. The listing is\n' "$root" "$prefix"
    printf 'scoped to the directory it is given, so it reports nothing here and prints no\n'
    printf 'diagnostic at all. Pass the toplevel.\n'

    return 0
  fi
  printf 'Cause: the wiki tree of %s holds no tracked page. This tree carries dozens, so\n' "$root"
  printf 'that is a deleted or unstaged tree rather than a surface with nothing on it.\n'
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
  if [ ! -d "$root/wiki" ]; then
    printf '%s: wiki directory not found under %s\n' "$PROG" "$root" >&2
    return 2
  fi

  BLOCKING_FILE="$(mktemp "${TMPDIR:-/tmp}/$PROG.XXXXXX")" || {
    printf '%s: could not create a temporary file for the blocking-hook listing\n' "$PROG" >&2
    return 2
  }
  # Three arms, not one shared arm: bash resumes at the point of interruption
  # once a trapped handler returns, so a single arm that only unlinks would
  # leave Ctrl-C printing a verdict as if uninterrupted.
  trap 'rm -f "$BLOCKING_FILE"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  local registered hook
  registered="$(pretooluse_hooks "$root")"
  if [ -z "$registered" ]; then
    printf '%s: discovery found no hook registered on PreToolUse in %s.\n' "$PROG" "$SETTINGS" >&2
    printf 'This tree registers dozens; an empty set is a broken read of the registration\n' >&2
    printf 'shape, and every advisory entry below it would then grade as correct having been\n' >&2
    printf 'compared against nothing.\n' >&2
    return 2
  fi

  while IFS= read -r hook; do
    [ -n "$hook" ] || continue
    # A registration naming a script that is not present is a separate defect
    # with its own owner; skipping it here keeps this check speaking only about
    # classification.
    [ -f "$root/.claude/hooks/$hook" ] || continue
    if blocks "$root/.claude/hooks/$hook"; then
      printf '%s\n' "$hook" >>"$BLOCKING_FILE"
    fi
  done <<EOF
$registered
EOF

  # Every PreToolUse hook reading as advisory is the second broken-oracle
  # shape, and it is invisible from the report: the sweep below would then find
  # nothing to say and print clean over a page it could not have graded.
  if [ ! -s "$BLOCKING_FILE" ]; then
    printf '%s: discovery classified every PreToolUse hook in %s as advisory.\n' "$PROG" "$SETTINGS" >&2
    printf 'This tree registers many that deny outright, so this is the blocking oracle failing\n' >&2
    printf 'to read a hook body rather than a tree of nudges. Every advisory entry would grade\n' >&2
    printf 'as correct against an empty set.\n' >&2
    return 2
  fi

  # The page sweep. NUL-delimited discovery: a page whose name carries a
  # non-ASCII byte is C-quoted by a newline-delimited listing, and the quoted
  # form is not the path the sweep then opens.
  local page entry line name findings=0 seen=0
  while IFS= read -r -d '' page; do
    seen=$((seen + 1))
    [ -f "$root/$page" ] || continue
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      line="${entry%%:*}"
      name="${entry#*:}"
      grep -qxF -- "$name" "$BLOCKING_FILE" || continue
      if [ "$findings" -eq 0 ]; then
        printf '%s: hooks that block a tool call, filed under an Advisory heading:\n' "$PROG" >&2
      fi
      printf '  %s:%s: %s\n' "$page" "$line" "$name" >&2
      findings=$((findings + 1))
    done <<ENTRIES
$(advisory_entries "$root/$page")
ENTRIES
  done < <(git -C "$root" ls-files -z -- 'wiki/*.md' 'wiki/**/*.md')

  # Checked after the sweep rather than before it, because the NUL-delimited
  # listing is consumed by the loop itself; `seen` is what the pre-sweep
  # emptiness test would have asked, and nothing is reported when it is zero.
  if [ "$seen" -eq 0 ]; then
    empty_discovery_cause "$root" >&2
    printf 'Either way this is a broken discovery rather than a surface with no advisory\n' >&2
    printf 'sections on it.\n' >&2
    return 2
  fi

  if [ "$findings" -gt 0 ]; then
    printf '\n%s: %d entry(ies) above classify a blocking hook as advisory.\n' "$PROG" "$findings" >&2
    printf 'Each names a hook registered on PreToolUse whose body emits a permissionDecision or\n' >&2
    printf 'exits 2, so the action it fires on stops. A reader deciding whether an action will be\n' >&2
    printf 'stopped reads the heading and stops there. Move the entry under the blocking section\n' >&2
    printf 'and describe what it denies and on what condition.\n' >&2
    return 1
  fi
  printf '%s: clean\n' "$PROG"
  return 0
}

main "$@"
