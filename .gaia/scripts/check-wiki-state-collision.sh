#!/usr/bin/env bash
# shellcheck shell=bash
#
# `wiki/.state.json` records how far along one line of commit history the
# wiki has been evaluated. Every field is a position in history, so every
# branch advances it to its own head, and two branches that both sync reach
# the merge holding different values for the same lines.
#
# That collision stops loudly, and no code in this repository is why: git's
# own three-way merge sees both sides change the same lines against a
# common ancestor and refuses. What the refusal prevents is the second
# branch's value silently replacing the first's -- a state file that claims
# a range of history is evaluated when nobody evaluated it.
#
# A property held by a tool's default, and by none of our own code, is one
# nothing notices losing. This check is the notice. Two edits remove the
# refusal, and both are silent:
#
#   1. The file stops being tracked -- deleted, gitignored, or moved into
#      .gaia/local/. An untracked file never reaches a merge at all, so each
#      tree keeps a private value and the divergence gets no moment where it
#      surfaces.
#   2. A `merge` attribute routes the file to a driver that resolves on its
#      own. `merge=union` concatenates both sides, which here commits
#      invalid JSON with no conflict; a custom driver name can do anything,
#      including picking a side.
#
# Neither is hypothetical. Keying the value per branch, installing a merge
# driver, and untracking the store are the three shapes anyone reasoning
# about a single-valued file shared by N branches reaches for first, and the
# first and third are both spellings of edit 1.
#
# The `merge` attribute values that keep the collision loud, all accepted:
#
#   unspecified   no attribute applies; git's default three-way merge runs
#   set           a bare `merge` attribute; the built-in three-way driver
#   text          the same built-in driver, named
#   unset         `-merge`; git declares the merge conflicted outright
#   binary        `merge=binary`; likewise conflicts rather than resolving
#
# Any other value names a driver that decides the outcome itself, which is
# the failure this check exists to catch.
#
# NOT covered, and known not to be:
#
#   A per-clone `.git/info/attributes`. It is untracked and machine-local,
#   so it reaches no other clone and no CI run; this check reads what the
#   repository ships. A local one silences the collision on one machine
#   only, and only for whoever wrote it.
#
#   Whether the recorded value is CORRECT. This check guards the property
#   that a cross-branch collision stops rather than resolves. It says
#   nothing about how a reader recovers a baseline once the recorded sha is
#   orphaned by a squash merge, which is a separate question about the
#   readers, not about this file's storage.
#
#   A merge driver defined in `.git/config` but never bound to this path by
#   an attribute. That is inert: git selects a driver by the `merge`
#   attribute, so config alone changes nothing, and the attribute scan is
#   the seam that matters.
#
# Dual-mode, like the repo's other check scripts: source it for
# gaia_check_wiki_state_collision, or run it directly as a script.
#
# gaia_check_wiki_state_collision <repo_root>
#   Runs both scans. Prints one verdict line per scan. Returns 0 when both
#   are clean, 1 otherwise. <repo_root> is a required parameter -- this
#   check never derives it itself: a CI caller passes the plain checkout
#   root, a bats fixture passes a temp repo.

# The one path this check guards. A rename is a deliberate change to the
# thing being guarded, so the check fails until it is updated with it.
GAIA_WIKI_STATE_PATH='wiki/.state.json'

# `merge` attribute values under which git still stops on a collision.
GAIA_WIKI_STATE_LOUD_MERGE_ATTRS='unspecified set text unset binary'

# _gaia_wiki_state_tracked <repo_root>: returns 0 when the state file is
# tracked in <repo_root>, 1 otherwise (untracked, ignored, or absent).
_gaia_wiki_state_tracked() {
  local repo_root="$1"
  git -C "$repo_root" ls-files --error-unmatch -- "$GAIA_WIKI_STATE_PATH" \
    >/dev/null 2>&1
}

# _gaia_wiki_state_merge_attr <repo_root>: prints the `merge` attribute git
# resolves for the state file. `git check-attr` prints
# `<path>: merge: <value>`, and no attribute value contains a space, so the
# last field is the value. Prints `unspecified` if git cannot answer.
_gaia_wiki_state_merge_attr() {
  local repo_root="$1"
  local line
  line="$(git -C "$repo_root" check-attr merge -- "$GAIA_WIKI_STATE_PATH" 2>/dev/null)" \
    || { printf 'unspecified\n'; return 0; }
  [ -n "$line" ] || { printf 'unspecified\n'; return 0; }
  printf '%s\n' "${line##* }"
}

gaia_check_wiki_state_collision() {
  local repo_root="${1:?gaia_check_wiki_state_collision requires a repo_root argument}"
  local tracked_failed=0 attr_failed=0

  if _gaia_wiki_state_tracked "$repo_root"; then
    printf 'wiki state file tracked: yes\n'
  else
    printf '%s is not tracked, so two branches never merge it and each keeps a private value\n' \
      "$GAIA_WIKI_STATE_PATH"
    printf 'wiki state file tracked: no\n'
    tracked_failed=1
  fi

  local attr
  attr="$(_gaia_wiki_state_merge_attr "$repo_root")"

  case " $GAIA_WIKI_STATE_LOUD_MERGE_ATTRS " in
    *" $attr "*)
      printf 'wiki state merge attribute: %s (loud)\n' "$attr"
      ;;
    *)
      printf '%s resolves through merge driver %s, so a cross-branch collision lands with no conflict\n' \
        "$GAIA_WIKI_STATE_PATH" "$attr"
      printf 'wiki state merge attribute: %s (silent)\n' "$attr"
      attr_failed=1
      ;;
  esac

  [ "$tracked_failed" -eq 0 ] && [ "$attr_failed" -eq 0 ]
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  repo_root="${1:-}"
  if [ -z "$repo_root" ]; then
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
      printf 'check-wiki-state-collision: not a git repository and no repo_root argument given\n' >&2
      exit 2
    }
  fi
  gaia_check_wiki_state_collision "$repo_root"
fi
