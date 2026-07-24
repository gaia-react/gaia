# shellcheck shell=bash
#
# GAIA shared key lib (task 4.1, analysis/task-4.1-audit-key-design.md
# §2a-2c; generalized by task 4.2, analysis/task-4.2-gh-artifact-key-design.md
# §2a). Houses one audit-specific key, gaia_audit_key, and one general rule,
# gaia_key_slug, that every worktree-partitioning key in GAIA builds on --
# a rule promoted to public and shared rather than copied per caller.
#
# Why a key is needed at all: two worktrees cut from the same main tip
# compute an IDENTICAL BASE_SHA (git merge-base "$BASE_REF" HEAD), and
# .gaia/local/audit/ is shared (symlinked to main from every worktree), so a
# base-sha-only key collides and one tree's findings sidecar / re-run ledger
# silently overwrites the other's. gaia_audit_key's key adds the acting
# tree's own branch: git forbids checking out the same branch in two
# worktrees at once, so the branch is a total discriminator between live
# trees. The same collision shape recurs anywhere else a worktree-partitioned
# artifact is keyed by branch (e.g. the gh-artifact PR-capture breadcrumb,
# .gaia/scripts/gh-artifact-lib.sh's gaia_gh_artifact_path), so those callers
# call gaia_key_slug directly rather than reimplementing the encoding.
#
# gaia_audit_key <base_sha> [<dir>]
#   Prints "<base-sha>.<branch-slug>" and returns 0 when both halves resolve.
#   <dir> defaults to "."; the branch is THAT tree's own
#   (`git -C "$dir" branch --show-current`), deliberately per-tree and never
#   main-anchored -- the whole point is to discriminate trees, not resolve a
#   root. Prints nothing and returns 1 when <base_sha> is empty or the branch
#   is undeterminable (detached HEAD, not a git repository): the same
#   fail-open rule every caller already applies to an empty base extends
#   verbatim to the whole key, so a caller skips its write rather than
#   inventing a fallback key.
#
# gaia_key_slug <text>: every character outside [A-Za-z0-9_-] is
# percent-encoded (uppercase hex, e.g. "/" -> "%2F", "." -> "%2E", "%" ->
# "%25"). A cheaper `tr / -` rule is rejected because it is not injective --
# "feat/x" and "feat-x" would collapse to one slug and silently re-create the
# collision a key exists to remove. Encoding "." matters for the same
# reason: gaia_audit_key's sidecar glob is "<base>.<slug>.*.findings.json"
# and gh-artifact-lib.sh's cache filename is "gh-artifact-pr.<slug>.json", so
# an unencoded dot in the slug would make either glob ambiguous about where
# the key starts and ends. The slug is ASCII-oriented: a non-ASCII name
# encodes per whatever byte value `printf` yields (deterministic; every
# writer and reader calls this same function, so they always agree). No
# truncation on an over-length result -- truncation would re-introduce the
# collision the encoding exists to prevent; a filename that overflows the OS
# limit just fails the write, the same fail-open outcome as everywhere else
# this key is used.
#
# No side effects at source time; defines functions only. Never resolves a
# main or tree root (no `--show-toplevel`, no new root derivation of any
# kind) -- this lib answers "what key does this tree write under", not
# "where is anything".
#
# Usage:
#   . .gaia/scripts/audit-key-lib.sh
#   AUDIT_KEY="$(gaia_audit_key "$BASE_SHA")" || AUDIT_KEY=""
#   SLUG="$(gaia_key_slug "$BRANCH")"

# gaia_key_slug <text>
# Percent-encodes every byte of <text> outside [A-Za-z0-9_-]. `LC_ALL=C`
# scopes this function's byte-wise character handling (bash re-evaluates the
# locale on assignment, even to an unexported local), so a multi-byte branch
# name is walked one byte at a time rather than one (possibly multi-byte)
# character at a time -- the encoding is then trivially injective over bytes,
# which is the only property this function needs. Public: every
# worktree-partitioning key in GAIA (gaia_audit_key below, and
# gh-artifact-lib.sh's gaia_gh_artifact_path) calls this one rule rather than
# each keeping its own copy.
gaia_key_slug() {
  local LC_ALL=C
  local text="$1" out="" i len c
  len="${#text}"
  for ((i = 0; i < len; i++)); do
    c="${text:i:1}"
    case "$c" in
      [A-Za-z0-9_-]) out+="$c" ;;
      *) out+="$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}

gaia_audit_key() {
  local base_sha="${1:-}" dir="${2:-.}"
  [[ -n "$base_sha" ]] || return 1
  local branch
  branch="$(git -C "$dir" branch --show-current 2>/dev/null)" || branch=""
  [[ -n "$branch" ]] || return 1
  printf '%s.%s\n' "$base_sha" "$(gaia_key_slug "$branch")"
  return 0
}
