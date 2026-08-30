# shellcheck shell=bash
#
# GAIA shared tech-debt provenance helper (single-sourced).
#
# Prints ONE HTML-comment line recording the branch a tech-debt finding was
# surfaced from. It sits beside the existing `gaia-debt-key` line on a filed
# issue, or on a waived finding's pull-request-body entry:
#
#   <!-- gaia-debt-origin: branch=<b> mode=<m> unit=<u> changed=<c> head=<h> -->
#
# Five key=value pairs, single spaces, that order, one line, newline
# terminated. There is no version prefix, and no reader may depend on the
# field order: the order is canonical for human readability only.
#
# A filed issue records what the defect is and nothing about where it was
# surfaced. This line is what lets a triager reading the backlog months later
# tell which branch the finding was surfaced from and, where the route
# resolved one, whether the cited file was in the reviewed change's own
# changed-file set. `mode` and `unit` are derived from the branch name, so
# neither records who filed nor what that session was doing; the contract in
# .claude/skills/file-tech-debt/SKILL.md states the limitation that puts on
# a reader.
#
# FAIL-OPEN, deliberately inverting the fail-closed rule of the sibling
# .gaia/scripts/audit-key-lib.sh. Where gaia_audit_key refuses to print a
# half-built key, this helper prints the literal `unknown` in any slot it
# cannot resolve and exits 0 regardless. A caller never treats the output as a
# precondition. A line of unknowns says "the route ran and resolved nothing";
# an ABSENT line says "the route predates provenance". Those two facts stay
# distinguishable, so a route that gets no line omits it and continues, and
# nothing is ever blocked, retried, or deferred because provenance is partial.
#
# gaia_debt_origin_encode <text>
#   Prints <text> with `%` replaced by `%25` FIRST, then `>` replaced by
#   `%3E`. No other byte changes. Always returns 0. Exactly two characters are
#   reserved: `>` because a git branch name may legally contain one and an
#   unencoded one would terminate the HTML comment early and leak the
#   remainder as visible text, and `%` itself so the encoding is invertible
#   and a reader recovers the exact branch name. Encoding `%` before `>` is
#   what makes the inverse (`%3E` back to `>`, then `%25` back to `%`) exact.
#
# gaia_debt_origin_classify <normalized-branch>
#   Prints "<mode> <unit>", one space between them. Always returns 0. The
#   argument is a branch already put through this file's normalization; the
#   ladder in gaia_debt_origin_line owns the "no branch resolved" case, so
#   this function is never handed one.
#
# gaia_debt_origin_line [--changed <v>] [--branch <name>] [--dir <path>]
#   Prints exactly one newline-terminated line. Returns 0 unconditionally,
#   including outside a git repository and on an unrecognized argument.
#
# Deliberately NOT reusing gaia_key_slug from audit-key-lib.sh: that function
# encodes every byte outside [A-Za-z0-9_-], which would render
# `debt/1121-marker-sep` as `debt%2F1121-marker-sep`. This value is read by
# humans, so its reserved set is two characters and its encoder is its own.
#
# This file resolves no repository root and computes no diff base. `changed`
# is supplied by the caller, which is the only place that knows which
# fork-point set the answer belongs to. No side effects at source time; it
# defines functions only and succeeds under `set -u` in a directory that is
# not a git repository.
#
# Usage (sourced):
#   . .gaia/scripts/debt-origin-lib.sh
#   origin="$(gaia_debt_origin_line --changed 1)"
#
# Usage (executable):
#   bash .gaia/scripts/debt-origin-lib.sh [--changed <v>] [--branch <name>] [--dir <path>]

# gaia_debt_origin_encode <text>
# `LC_ALL=C` scopes the replacement to bytes (bash re-evaluates the locale on
# assignment, even to an unexported local), so a multi-byte branch name cannot
# make the substitution locale-dependent. The two replacements are written as
# two ordered parameter expansions rather than one character walk because the
# ORDER is the contract: `%` first, so the `%` this function itself introduces
# in `%3E` is never re-encoded, and `>` second.
#
# Both patterns are backslash-escaped, and the `%` one has to be: zsh reads
# `${var//%pat/repl}` as an END-ANCHORED replacement, so an unescaped `%` there
# is an anchor over an empty pattern and appends `%25` instead of encoding
# anything. `\%` is a literal `%` in bash and zsh alike. `\>` is escaped for
# the same defensive reason (zsh's `<x-y>` numeric glob gives `>` a meaning
# bash does not) and is identical in both shells. The escapes cost nothing and
# remove the only shell-specific construct in this function, matching
# audit-key-lib.sh's reason for spelling its own walk `${text:$i:1}`.
gaia_debt_origin_encode() {
  local LC_ALL=C
  local text="${1-}"
  text="${text//\%/%25}"
  text="${text//\>/%3E}"
  printf '%s' "$text"
  return 0
}

# _gaia_debt_origin_is_digits <text>
# Returns 0 when <text> is one or more ASCII digits and nothing else.
_gaia_debt_origin_is_digits() {
  local text="${1-}"
  [ -n "$text" ] || return 1
  case "$text" in
    *[!0-9]*) return 1 ;;
  esac
  return 0
}

# _gaia_debt_origin_is_members <text>
# Returns 0 when <text> matches ^[0-9]+(-[0-9]+)*$: one or more digit groups
# joined by single hyphens. Expressed as four glob rejections in one `case`
# (leading hyphen, trailing hyphen, doubled hyphen, any byte outside digits
# and hyphen) rather than a regex, so the whole file stays plain bash 3.2.
_gaia_debt_origin_is_members() {
  local text="${1-}"
  [ -n "$text" ] || return 1
  case "$text" in
    -* | *- | *--* | *[!0-9-]*) return 1 ;;
  esac
  return 0
}

# _gaia_debt_origin_leading_digits <text>
# Prints the leading run of ASCII digits in <text>; prints nothing when <text>
# does not start with a digit.
_gaia_debt_origin_leading_digits() {
  local LC_ALL=C
  local text="${1-}" out="" i len c
  len="${#text}"
  for ((i = 0; i < len; i++)); do
    # `${text:$i:1}`, not bash's bare `${text:i:1}`: zsh reads a bare
    # identifier after the colon as a history modifier and aborts the function
    # mid-walk. Both forms are identical in bash, so the `$` costs nothing.
    # Same reasoning as audit-key-lib.sh's walk.
    c="${text:$i:1}"
    case "$c" in
      [0-9]) out="${out}${c}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$out"
}

# _gaia_debt_origin_normalize <raw-branch>
# Prints the branch normalized FOR MATCHING ONLY: a single leading `worktree-`
# stripped, then every `+` replaced by `/`. Both steps run unconditionally, in
# that order. The emitted `branch` field keeps the raw name; the normalization
# reaches the record only through `unit`, which gaia_debt_origin_classify
# derives from the normalized string, so `chore-a+b` records `branch=chore-a+b`
# with `unit=a/b`. That is diagnostic-only and the raw name is never lost.
# It exists because a worktree branch
# is the requested name wrapped as `worktree-<name>` with `/` written as `+`,
# and a wrapped branch has to classify as the work it actually is.
_gaia_debt_origin_normalize() {
  local text="${1-}"
  text="${text#worktree-}"
  # `\+` for the same reason gaia_debt_origin_encode escapes its patterns:
  # a bare replacement pattern is the one construct in this file whose meaning
  # can differ between bash and zsh, and an escaped literal is identical in
  # both.
  text="${text//\+//}"
  printf '%s' "$text"
}

# gaia_debt_origin_classify <normalized-branch>
# The branch-naming convention table, FIRST MATCHING ROW WINS. `mode` is drawn
# from a closed vocabulary: drain, plan, maintenance, adhoc, unknown. `unknown`
# is not reachable from here; it is what gaia_debt_origin_line records when no
# branch resolved at all, which is a different fact from a branch that matched
# no row.
#
#   1  debt/<members>-batch      drain        <members>
#   2  debt/<rest>               drain        the leading digits of <rest>
#   3  spec-<nnn>[-<rest>]       plan         SPEC-<nnn>
#   4  plan-<nnn>[-<rest>]       plan         plan-<nnn>
#   5  chore/<rest>, chore-<rest>    maintenance  <rest>
#   6  harden/<rest>, harden-<rest> maintenance  <rest>
#   7  wiki-sync/<rest>          maintenance  <rest>
#   8  audit-<rest>              maintenance  <rest>
#   9  anything else             adhoc        unknown
#
# Row 9 covers `main` and the hand-named human branches (`fix/`, `docs/`,
# `feat/`). They encode no unit in the name, so `adhoc` is the honest answer
# rather than a gap. Any derived unit that comes out empty becomes `unknown`.
gaia_debt_origin_classify() {
  local nb="${1-}" mode="adhoc" unit="" rest="" lead=""

  case "$nb" in
    debt/*)
      mode="drain"
      rest="${nb#debt/}"
      # Row 1 is tested before row 2: a batch branch's unit is every member,
      # and falling through to row 2 would record only the first.
      case "$rest" in
        *-batch)
          if _gaia_debt_origin_is_members "${rest%-batch}"; then
            unit="${rest%-batch}"
          fi
          ;;
      esac
      # Row 2: any other debt branch keys off its leading issue number.
      if [ -z "$unit" ]; then
        unit="$(_gaia_debt_origin_leading_digits "$rest")"
      fi
      ;;
    spec-*)
      # Row 3. A `spec-` branch whose next segment is not numeric is not a
      # spec branch at all and falls through to row 9.
      rest="${nb#spec-}"
      lead="${rest%%-*}"
      if _gaia_debt_origin_is_digits "$lead"; then
        mode="plan"
        unit="SPEC-${lead}"
      fi
      ;;
    plan-*)
      # Row 4, the same shape as row 3.
      rest="${nb#plan-}"
      lead="${rest%%-*}"
      if _gaia_debt_origin_is_digits "$lead"; then
        mode="plan"
        unit="plan-${lead}"
      fi
      ;;
    chore/*)
      mode="maintenance"
      unit="${nb#chore/}"
      ;;
    chore-*)
      mode="maintenance"
      unit="${nb#chore-}"
      ;;
    harden/*)
      mode="maintenance"
      unit="${nb#harden/}"
      ;;
    harden-*)
      mode="maintenance"
      unit="${nb#harden-}"
      ;;
    wiki-sync/*)
      mode="maintenance"
      unit="${nb#wiki-sync/}"
      ;;
    audit-*)
      mode="maintenance"
      unit="${nb#audit-}"
      ;;
  esac

  [ -n "$unit" ] || unit="unknown"
  printf '%s %s\n' "$mode" "$unit"
  return 0
}

# gaia_debt_origin_line [--changed <v>] [--branch <name>] [--dir <path>]
# See the contract at the top of this file. Every resolution below degrades to
# the literal `unknown` rather than failing, and the function returns 0 on
# every path.
gaia_debt_origin_line() {
  local changed_arg="" branch_arg="" dir="."

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --changed)
        shift
        if [ "$#" -gt 0 ]; then
          changed_arg="$1"
          shift
        fi
        ;;
      --branch)
        shift
        if [ "$#" -gt 0 ]; then
          branch_arg="$1"
          shift
        fi
        ;;
      --dir)
        shift
        if [ "$#" -gt 0 ]; then
          dir="$1"
          shift
        fi
        ;;
      *)
        # An unrecognized argument is skipped rather than refused: this helper
        # never fails a caller, and consuming exactly one word keeps the loop
        # making progress no matter what it is handed.
        shift
        ;;
    esac
  done
  [ -n "$dir" ] || dir="."

  # `branch`, first non-empty wins: the explicit argument, then the head-branch
  # name GitHub Actions exports on a pull_request event (empty everywhere
  # else), then the checkout's own branch.
  local branch=""
  if [ -n "$branch_arg" ]; then
    branch="$branch_arg"
  elif [ -n "${GITHUB_HEAD_REF:-}" ]; then
    branch="$GITHUB_HEAD_REF"
  else
    branch="$(git -C "$dir" branch --show-current 2>/dev/null)" || branch=""
  fi

  local mode="unknown" unit="unknown" classified=""
  if [ -n "$branch" ]; then
    classified="$(gaia_debt_origin_classify "$(_gaia_debt_origin_normalize "$branch")")" || classified=""
    mode="${classified%% *}"
    unit="${classified#* }"
    [ -n "$mode" ] || mode="unknown"
    [ -n "$unit" ] || unit="unknown"
  else
    # No branch resolved, so `mode` and `unit` are `unknown` and never `adhoc`:
    # `adhoc` means a branch resolved and matched no convention, which is a
    # different fact from no branch at all.
    branch="unknown"
  fi

  # `changed` is reported, never computed. Membership belongs to the caller,
  # which is the only place that knows which fork-point set the answer is
  # about; anything outside the closed vocabulary is `unknown`.
  local changed="unknown"
  case "$changed_arg" in
    0 | 1 | unknown) changed="$changed_arg" ;;
  esac

  # `head` is the tree's own commit. A detached HEAD still resolves; anything
  # that is not a 40-character lowercase hex sha is `unknown`.
  local head=""
  head="$(git -C "$dir" rev-parse HEAD 2>/dev/null)" || head=""
  if [ "${#head}" -ne 40 ]; then
    head="unknown"
  else
    case "$head" in
      *[!0-9a-f]*) head="unknown" ;;
    esac
  fi

  # Every value is encoded, not only the two that can carry a reserved
  # character. For `mode`, `changed`, and `head` the encoding is a no-op by
  # construction, which is the point: "no emitted value carries a raw `>` or
  # `%`" then holds by construction rather than by argument.
  printf '<!-- gaia-debt-origin: branch=%s mode=%s unit=%s changed=%s head=%s -->\n' \
    "$(gaia_debt_origin_encode "$branch")" \
    "$(gaia_debt_origin_encode "$mode")" \
    "$(gaia_debt_origin_encode "$unit")" \
    "$(gaia_debt_origin_encode "$changed")" \
    "$(gaia_debt_origin_encode "$head")"
  return 0
}

if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  gaia_debt_origin_line "$@"
  exit 0
fi
