#!/usr/bin/env bash
# shellcheck shell=bash
#
# GAIA main-only-flow refusal helper (single-sourced).
#
# The one place that renders the "this flow is main-checkout-only" refusal.
# What motivated it: a flow that writes `.gaia/VERSION` / a lockfile / cache
# state and opens or drives a PR belongs on the main checkout, never on a
# per-SPEC worktree branch. That is the motivating case, not a membership
# test. The set carrying the refusal has grown past it, and members of that
# set match one half of the description without the other, so whether a new
# flow belongs is not answered by reading this paragraph. Before this file
# existed, /update-gaia and /update-deps each carried their own ~40-line
# copy of the same detection + message, hand-deriving the current tree with
# their own `git rev-parse --show-toplevel` instead of the shared resolver.
# This is the one definition; consumers source it instead of re-deriving
# anything. Which files those are is deliberately not listed here: an
# enumeration in a docblock drifts silently while nothing rechecks it.
# gaia:maintainer-only:start
# `CALL_SITE_FILES` in .gaia/scripts/tests/main-only-lib.bats is the roster,
# kept honest by a census test that reds when a flow drifts out of it. That
# roster covers the flow call sites only, so a shell script sourcing this
# library is pinned by its own suite instead.
# gaia:maintainer-only:end
#
# Deliberately NOT a resolver. This file sources main-root-lib.sh (the one
# canonical resolver) and calls its functions; it performs no root
# derivation of its own, so it cannot count as a second resolver
# definition.
#
# gaia_refuse_if_worktree <flow-name> [state_line_fn]
#   <flow-name>: the slash command's own name as the caller wants it printed
#   (e.g. "/update-gaia"), used verbatim in the message.
#
#   [state_line_fn]: optional. The NAME of a shell function the caller
#   defines. Called with one argument, the absolute path of
#   "<main_root>/.gaia/local/cache/shared/update-check.json", and expected to
#   print one line on stdout summarizing cached state relevant to the flow
#   (or nothing, when the cache is unusable). Its stderr and exit status are
#   ignored; only what it prints on stdout is used.
#
#   Returns 0 (the caller falls through and continues) when the session is
#   NOT in a linked worktree, or when the main root cannot be resolved. The
#   unresolvable-main case fails OPEN on purpose, matching both of the
#   flows this replaces: an indeterminate main root is not grounds to block
#   the caller's own flow.
#
#   Returns 1, after printing the refusal to stdout, when the session IS in
#   a linked worktree and the main root resolves. The message:
#
#     <flow-name> must run from the main checkout, not a worktree.
#
#     Worktree:       <current tree root>
#     Main checkout:  <main root>
#
#     <state line -- only when state_line_fn was supplied>
#
#     Run `cd <main root>` then re-invoke <flow-name>.
#
#   When state_line_fn is supplied but prints nothing (cache file missing,
#   jq absent, fields empty), the state line falls back to:
#   "Cached state unavailable on main; symlinks may be broken, run
#   `.gaia/cli/gaia setup link-worktree` to repair." When state_line_fn is
#   not supplied at all, the state paragraph and its surrounding blank line
#   are omitted entirely.
#
# Usage:
#   . .gaia/scripts/main-only-lib.sh
#   gaia_refuse_if_worktree "/some-flow" || exit 1
#
#   # With a flow-specific state line:
#   my_state_line() { local cache_file="$1"; ...; printf '%s\n' "$line"; }
#   gaia_refuse_if_worktree "/some-flow" my_state_line || exit 1

# Sibling-location idiom matched from main-root-lib.sh's own callers
# (.gaia/scripts/link-worktree.sh): resolve this file's own directory via
# BASH_SOURCE, never cwd. Guarded so a consumer that already sourced
# main-root-lib.sh itself needs no second, redundant source.
#
# Both statements below are written for the shell that actually sources this
# file. Unlike a hook, which settings.json invokes as `bash <script>`, the
# flow call sites are markdown blocks an agent runs through its shell tool,
# so the sourcing shell is that machine's login shell -- zsh on a stock Mac.
# Under zsh BASH_SOURCE is unset, and `declare -F` declares a float and
# succeeds rather than answering whether a function exists, so the resolver
# was never sourced and every refusal returned 0: the flow continued, from a
# worktree, with no refusal printed. `command -v` asks the same question in
# either shell.
#
# The location candidates are tried in order of authority. $0 is second
# because zsh names the sourced file there, but only sometimes: under
# `zsh -c` a relative `.` drops the directory, so the bare-name and empty
# cases are skipped rather than resolving to the cwd. The last candidate is
# the repo-relative path every call site sources, from a checkout root, where
# the sibling is a tracked file present in every tree. Each candidate must
# actually hold main-root-lib.sh to win, so a wrong guess cannot be adopted.
_GAIA_MAIN_ONLY_LIB_DIR=""
for _gaia_main_only_cand in "${BASH_SOURCE[0]:-}" "${0:-}" ".gaia/scripts/main-only-lib.sh"; do
  case "$_gaia_main_only_cand" in */*) ;; *) continue ;; esac
  _gaia_main_only_dir="$(cd "$(dirname "$_gaia_main_only_cand")" 2>/dev/null && pwd)" || continue
  if [ -f "$_gaia_main_only_dir/main-root-lib.sh" ]; then
    _GAIA_MAIN_ONLY_LIB_DIR="$_gaia_main_only_dir"
    break
  fi
done
unset _gaia_main_only_cand _gaia_main_only_dir

if ! command -v gaia_resolve_main_root >/dev/null 2>&1 && [ -n "$_GAIA_MAIN_ONLY_LIB_DIR" ]; then
  # shellcheck disable=SC1091
  source "$_GAIA_MAIN_ONLY_LIB_DIR/main-root-lib.sh"
fi

# The shared fallback state line, used when a supplied state_line_fn prints
# nothing. Byte-identical to the text both pre-existing copies used.
_GAIA_MAIN_ONLY_FALLBACK_STATE_LINE="Cached state unavailable on main; symlinks may be broken, run \`.gaia/cli/gaia setup link-worktree\` to repair."

gaia_refuse_if_worktree() {
  local flow_name="$1" state_line_fn="${2:-}"

  gaia_is_linked_worktree || return 0

  local main_root
  main_root="$(gaia_resolve_main_root)" || return 0

  local current_root
  current_root="$(gaia_resolve_tree_root)"

  local msg
  msg="$flow_name must run from the main checkout, not a worktree.

Worktree:       $current_root
Main checkout:  $main_root"

  if [ -n "$state_line_fn" ]; then
    local cache_file="$main_root/.gaia/local/cache/shared/update-check.json"
    local state_line
    state_line="$("$state_line_fn" "$cache_file" 2>/dev/null)"
    [ -n "$state_line" ] || state_line="$_GAIA_MAIN_ONLY_FALLBACK_STATE_LINE"
    msg="$msg

$state_line"
  fi

  msg="$msg

Run \`cd $main_root\` then re-invoke $flow_name."

  printf '%s\n' "$msg"
  return 1
}
