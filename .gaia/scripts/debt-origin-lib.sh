# shellcheck shell=bash
#
# GAIA shared tech-debt provenance helper (single-sourced).
#
# Prints ONE HTML-comment line recording the branch a tech-debt finding was
# surfaced from and the session that filed it. It sits beside the existing
# `gaia-debt-key` line on a filed issue, or on a waived finding's
# pull-request-body entry:
#
#   <!-- gaia-debt-origin: branch=<b> mode=<m> unit=<u> changed=<c> head=<h> session=<s> -->
#
# Six key=value pairs, single spaces, that order, one line, newline
# terminated. There is no version prefix, and no reader may depend on the
# field order: the order is canonical for human readability only.
#
# A filed issue records what the defect is and nothing about where it was
# surfaced. This line is what lets a triager reading the backlog months later
# tell which branch the finding was surfaced from and, where the route
# resolved one, whether the cited file was in the reviewed change's own
# changed-file set. `mode` and `unit` are derived from the branch name, so
# neither records who filed; the contract in
# .claude/skills/file-tech-debt/SKILL.md states the limitation that puts on
# a reader.
#
# `session` is the one field here that answers WHO, and it is the only one
# read off the process rather than the checkout. Branch-derived provenance is
# right for the common case, one session on its own branch, and wrong whenever
# two share a checkout: the filer inherits the other's `mode` and `unit`, and
# an inherited `unit` naming another live drain is worse than an absent one,
# because nothing downstream can tell the two apart. A session id is immune to
# that by construction, since no branch move reaches it.
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
# gaia_debt_origin_line [--changed <v>] [--branch <name>] [--dir <path>]
#   Prints exactly one newline-terminated line. Returns 0 unconditionally,
#   including outside a git repository and on an unrecognized argument.
#   Reads CLAUDE_CODE_SESSION_ID from the environment for `session`, which is
#   deliberately not a flag: the field's whole value is that it names the
#   process actually filing, and an override would let a caller restamp
#   authorship the way `--branch` legitimately restamps the branch.
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

# The branch-naming convention, its worktree normalization, and the table that
# turns a branch into `mode` and `unit` are all owned by branch-name-lib.sh.
# Located by parameter expansion rather than `dirname` because this file is
# sourced with PATH empty and under zsh, where BASH_SOURCE is unset and `$0`
# names the sourced file. A missing sibling leaves gaia_branch_classify
# undefined, which the line below records as `unknown`, keeping this file
# fail-open.
_gaia_debt_origin_src="${BASH_SOURCE[0]:-$0}"
case "$_gaia_debt_origin_src" in
  */*) _gaia_debt_origin_dir="${_gaia_debt_origin_src%/*}" ;;
  *) _gaia_debt_origin_dir="." ;;
esac
# shellcheck source=/dev/null
. "${_gaia_debt_origin_dir}/branch-name-lib.sh" 2>/dev/null || true
unset _gaia_debt_origin_src _gaia_debt_origin_dir

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
    classified="$(gaia_branch_classify "$branch")" || classified=""
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

  # `session` identifies the FILER, read off the process rather than the
  # checkout, so it is the one field a branch move cannot corrupt. The harness
  # exports CLAUDE_CODE_SESSION_ID into the session shell and every Bash child
  # inherits it; two other consumers in this repository already key on it for
  # session-scoped identity (.gaia/scripts/token-tally.sh, and
  # .specify/extensions/gaia/lib/spec-session-lock.sh, which picks it for the
  # same stable-per-session property this field needs).
  #
  # Absent is `unknown`, this line's convention for every field it cannot
  # resolve. The continuous-integration route reaches that arm; why it does,
  # and what the guarantee actually rests on, is the CI row in
  # .claude/skills/file-tech-debt/SKILL.md, which owns the contract. Nothing
  # here depends on which way that goes.
  #
  # A value carrying whitespace is `unknown` too. The line is space-delimited
  # `key=value` pairs and readers match a field that way, so a space inside a
  # value would present as two fields and corrupt every pair after it. The
  # encoder cannot help: its reserved set is `>` and `%`, deliberately small
  # because these values are read by humans. Declining the value is the only
  # answer that keeps the line parseable, and it costs nothing real, since no
  # session id this reads is shaped that way.
  local session="${CLAUDE_CODE_SESSION_ID:-unknown}"
  case "$session" in
    *[[:space:]]*) session="unknown" ;;
  esac

  # Every value is encoded, not only the two that can carry a reserved
  # character. For `mode`, `changed`, and `head` the encoding is a no-op by
  # construction, which is the point: "no emitted value carries a raw `>` or
  # `%`" then holds by construction rather than by argument. `session` is a
  # no-op for the harness value it normally carries and is encoded on the same
  # terms as the rest regardless, because it is the one value here that comes
  # from the environment and nothing constrains what a process may export.
  printf '<!-- gaia-debt-origin: branch=%s mode=%s unit=%s changed=%s head=%s session=%s -->\n' \
    "$(gaia_debt_origin_encode "$branch")" \
    "$(gaia_debt_origin_encode "$mode")" \
    "$(gaia_debt_origin_encode "$unit")" \
    "$(gaia_debt_origin_encode "$changed")" \
    "$(gaia_debt_origin_encode "$head")" \
    "$(gaia_debt_origin_encode "$session")"
  return 0
}

if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  gaia_debt_origin_line "$@"
  exit 0
fi
