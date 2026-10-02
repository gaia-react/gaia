#!/usr/bin/env bash
# shellcheck shell=bash
#
# GAIA shared main-checkout resolver (single-sourced).
#
# The one definition of "main checkout root": the working tree that owns
# git's common directory. Dual-mode: source it for the two functions below,
# or run it directly as a script.
#
# Git version floor: git >= 2.31. `--absolute-git-dir` (used below) shipped in
# git 2.13 and `--git-common-dir` in git 2.5; 2.31 is named as the floor
# because it is the version that also carries `--path-format=absolute` and
# reliable `git worktree` plumbing, matching the rest of this repo's worktree
# machinery. This library deliberately does NOT reach for
# `--path-format=absolute`: it does not canonicalize symlinks (see the
# physical-resolution note below), so relying on it would silently reintroduce
# the logical/physical mismatch this resolver exists to close. Empirically
# probed against git 2.55.0.
#
# This floor is this library's own, not a repo-wide guarantee that every
# consumer holds to it. One shipped surface sits above it: the orphaned-worktree
# reap in .claude/hooks/local-janitor.sh proves a squash merge with
# `git patch-id --verbatim`, which needs git >= 2.39. Below that its reads fail
# and the sweep declines every candidate, which destroys nothing but reclaims
# nothing either. Named here so the two floors are reconciled in one place
# rather than each looking authoritative on its own.
#
# Physical resolution: every path this library treats as an answer is passed
# through `cd <path> && pwd -P` (never `realpath`/`readlink -f`, which are not
# guaranteed present on macOS). `git`'s own absolute-path flags are NOT trusted
# to resolve symlinks in every segment, so this library re-resolves physically
# itself rather than relying on git having already done so.
#
# Environment-override defense: every git invocation in this library strips
# GIT_DIR, GIT_WORK_TREE, and GIT_COMMON_DIR from the environment first (see
# _gaia_git below). Those three, when exported by a caller (a git hook, a
# `git rebase -x` step), override repository discovery for every `git`
# subprocess regardless of `-C`, which would let an ambient override stand in
# for the checkout's own on-disk layout -- exactly what this resolver's
# validation step exists to reject. Stripping them makes every answer here
# purely layout-derived, matching the resolver's own validation contract.
#
# gaia_resolve_main_root [directory]
#   Resolves the main-checkout root for `directory` (default: the process working
#   directory). SUCCESS: prints the root as one line, absolute, physically
#   resolved, no trailing slash, no `..`, terminated by a single newline;
#   returns 0. FAILURE: prints nothing on stdout, writes ONE diagnostic line
#   to stderr naming the constant token GAIA_MAIN_ROOT_UNRESOLVABLE and the
#   absolute git directory this resolution detected (or `none` when git found
#   no git directory at all -- there is nothing truthful to name there);
#   returns 3, the one documented failure status. Never both fails and prints
#   a path.
#
# gaia_is_linked_worktree [directory]
#   The predicate. Returns 0 when `directory` sits inside a linked worktree, 1 for
#   "no" or "indeterminate" (git unavailable, not a repository). Prints
#   nothing on stdout ever, in every case.
#
# gaia_resolve_tree_root [directory]
#   The per-tree counterpart of gaia_resolve_main_root: answers "which tree is
#   this" rather than "where is main". Resolves the current working-tree root
#   of `directory` (default: the process working directory) -- for a linked
#   worktree, that worktree's own root, not main's. SUCCESS: prints the root
#   as one line, absolute, physically resolved (symlink-canonicalized via
#   `pwd -P`, the same physical form gaia_resolve_main_root prints, so the two
#   are comparable and a symlinked checkout path never reads differently
#   between them), terminated by a single newline; returns 0. FAILURE
#   (`directory` is not inside a work tree): prints nothing on stdout; returns
#   non-zero. Reuses this file's own env-scrub (_gaia_git) and physical
#   resolver (_gaia_physical_directory); it is not a second resolver.
#
# gaia_tree_key [directory]
#   The path-safe rendering of the tree identity gaia_resolve_tree_root
#   returns: the first 16 hex characters of the sha256 of that physically
#   resolved root. Per-tree state that has to live under one shared
#   .gaia/local addresses itself at a subpath named by this key, because a
#   path segment cannot itself be a path. SUCCESS: prints 16 lowercase hex
#   characters as one line; returns 0. FAILURE (`directory` is not inside a work
#   tree, or neither `shasum` nor `sha256sum` is on PATH): prints nothing on
#   stdout, writes ONE diagnostic line to stderr naming the constant token
#   GAIA_TREE_KEY_UNRESOLVABLE; returns 1. Never both fails and prints a key.
#
#   Applied UNIFORMLY, including to the main checkout: a caller keys its own
#   state the same way in every tree, so no code carries an "am I main" branch
#   for state it owns. sha256-of-the-root-path is the idiom .project-id
#   already establishes for this repo, so this is a new caller of a settled
#   mechanism, not a new mechanism. The key deliberately does NOT derive from
#   a worktree's directory name: nothing requires a worktree to live under
#   .claude/worktrees/, and name-shaped keys have already had to move once.
#
# gaia_resolve_common_directory [directory]
#   Repository identity: the physically resolved git common directory of
#   `directory` (default: the process working directory), the one directory a main
#   checkout and every linked worktree of it share, so two directories are in
#   the same repository exactly when their answers are equal. Cheaper than
#   comparing two gaia_resolve_main_root answers, which also locate and
#   validate a root. SUCCESS: prints the directory as one line; returns 0.
#   FAILURE (`directory` is not inside a repository): prints nothing on stdout;
#   returns non-zero.
#
# Neither function holds state between calls: two independent resolutions,
# for two different directories, are safe in one process.
#
# Usage (sourced):
#   . .gaia/scripts/main-root-lib.sh
#   root="$(gaia_resolve_main_root)" || { echo "no root: $?" >&2; }
#   if gaia_is_linked_worktree "$some_directory"; then ...; fi
#   tree_root="$(gaia_resolve_tree_root "$some_directory")" || { echo "no tree: $?" >&2; }
#   key="$(gaia_tree_key "$some_directory")" || { echo "no key: $?" >&2; }
#   common="$(gaia_resolve_common_directory "$some_directory")" || { echo "no repo" >&2; }
#
# Usage (executable):
#   bash .gaia/scripts/main-root-lib.sh [directory]                # resolve
#   bash .gaia/scripts/main-root-lib.sh --is-worktree [directory]  # predicate
#   bash .gaia/scripts/main-root-lib.sh --tree-root [directory]    # per-tree resolve
#   bash .gaia/scripts/main-root-lib.sh --tree-key [directory]     # per-tree key
#   bash .gaia/scripts/main-root-lib.sh --common-dir [directory]   # repository identity

# Run git with the three repository-discovery overrides stripped from the
# environment, so every call here answers from on-disk layout alone.
_gaia_git() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git "$@"
}

# Absolutize $1 against base dir $2 when $1 is not already absolute. Pure
# string work; touches nothing on disk.
_gaia_absolute_path() {
  local possibly_relative_path="$1" base="$2"
  case "$possibly_relative_path" in
    /*) printf '%s' "$possibly_relative_path" ;;
    *) printf '%s/%s' "$base" "$possibly_relative_path" ;;
  esac
}

# Physically resolve $1: symlinks and `..` segments collapsed. Prints nothing
# and exits non-zero when $1 does not name a real, reachable directory.
_gaia_physical_directory() {
  ( cd "$1" 2>/dev/null && pwd -P )
}

# Validate a resolved-main-root candidate against the common dir the
# resolution started from. Accepts only when all three hold: the candidate is
# an existing directory; the candidate's own physically-resolved toplevel
# equals the candidate; the candidate's own physically-resolved common dir
# equals the common dir the caller started from. The third condition is what
# rejects an ambient core.worktree/work-tree override and the "parent of a
# separate git dir sits inside an unrelated repo" case: both would otherwise
# report SOME toplevel, but never one whose own common dir loops back to
# where this resolution began.
_gaia_validate_main_root_candidate() {
  local candidate="$1" expected_common_directory="$2"
  [[ -d "$candidate" ]] || return 1

  local toplevel
  toplevel="$(_gaia_git -C "$candidate" rev-parse --show-toplevel 2>/dev/null)" || toplevel=""
  [[ -n "$toplevel" ]] || return 1
  toplevel="$(_gaia_physical_directory "$toplevel")" || toplevel=""
  [[ -n "$toplevel" && "$toplevel" == "$candidate" ]] || return 1

  local candidate_common_directory_raw candidate_common_directory_absolute common
  candidate_common_directory_raw="$(_gaia_git -C "$candidate" rev-parse --git-common-dir 2>/dev/null)" || candidate_common_directory_raw=""
  [[ -n "$candidate_common_directory_raw" ]] || return 1
  candidate_common_directory_absolute="$(_gaia_absolute_path "$candidate_common_directory_raw" "$candidate")"
  common="$(_gaia_physical_directory "$candidate_common_directory_absolute")" || common=""
  [[ -n "$common" && "$common" == "$expected_common_directory" ]] || return 1

  return 0
}

# Emit the resolver's one stderr diagnostic and return the one documented
# failure status (3): the named constant token, a human reason, and the
# absolute git directory this resolution detected.
_gaia_main_root_fail() {
  local reason="$1" git_directory="${2:-none}"
  printf 'GAIA_MAIN_ROOT_UNRESOLVABLE: %s (git_dir=%s)\n' "$reason" "$git_directory" >&2
  return 3
}

gaia_resolve_main_root() {
  local directory="${1:-}"
  local -a git_command
  if [[ -n "$directory" ]]; then
    git_command=(_gaia_git -C "$directory")
  else
    git_command=(_gaia_git)
  fi
  local base="${directory:-$PWD}"

  # Step 1: read the common dir, absolute then physically resolved. Git
  # having no answer here means there is no git directory at all to name.
  local common_directory_raw
  common_directory_raw="$("${git_command[@]}" rev-parse --git-common-dir 2>/dev/null)" || common_directory_raw=""
  if [[ -z "$common_directory_raw" ]]; then
    _gaia_main_root_fail "no git common directory for '$base' (not a git repository)"
    return $?
  fi

  local common_directory_absolute common_directory
  common_directory_absolute="$(_gaia_absolute_path "$common_directory_raw" "$base")"
  common_directory="$(_gaia_physical_directory "$common_directory_absolute")" || common_directory=""
  if [[ -z "$common_directory" ]]; then
    _gaia_main_root_fail "git common directory '$common_directory_absolute' does not exist"
    return $?
  fi

  local git_directory_raw git_directory
  git_directory_raw="$("${git_command[@]}" rev-parse --absolute-git-dir 2>/dev/null)" || git_directory_raw=""
  if [[ -z "$git_directory_raw" ]]; then
    _gaia_main_root_fail "no git directory for '$base'" "$common_directory"
    return $?
  fi
  git_directory="$(_gaia_physical_directory "$git_directory_raw")" || git_directory=""
  if [[ -z "$git_directory" ]]; then
    _gaia_main_root_fail "git directory '$git_directory_raw' does not exist" "$common_directory"
    return $?
  fi

  # Step 2: linked-worktree test. git dir and common dir differ only inside a
  # linked worktree; this holds in every checkout shape probed, including
  # submodules, and replaces the broken dirname(common) != toplevel test.
  local candidate="" linked=0
  if [[ "$git_directory" == "$common_directory" ]]; then
    # Not a linked worktree: the answer is the working tree that owns directory.
    candidate="$("${git_command[@]}" rev-parse --show-toplevel 2>/dev/null)" || candidate=""
    if [[ -z "$candidate" ]]; then
      _gaia_main_root_fail "no working tree for this git directory (bare repository, or cwd inside a .git directory)" "$git_directory"
      return $?
    fi
    candidate="$(_gaia_physical_directory "$candidate")" || candidate=""
    if [[ -z "$candidate" ]]; then
      _gaia_main_root_fail "the working tree git reported does not exist" "$git_directory"
      return $?
    fi
  else
    linked=1
    # Linked worktree: core.worktree read from the COMMON directory's config,
    # resolved relative to the common directory -- never against this
    # worktree's own git dir, which would yield a path inside .git. When
    # unset, fall back to the common directory's parent.
    local core_worktree
    core_worktree="$(_gaia_git config --file "$common_directory/config" --get core.worktree 2>/dev/null)" || core_worktree=""
    if [[ -n "$core_worktree" ]]; then
      local core_worktree_absolute
      core_worktree_absolute="$(_gaia_absolute_path "$core_worktree" "$common_directory")"
      candidate="$(_gaia_physical_directory "$core_worktree_absolute")" || candidate=""
      if [[ -z "$candidate" ]]; then
        _gaia_main_root_fail "linked worktree's core.worktree ('$core_worktree') does not resolve to a reachable directory" "$git_directory"
        return $?
      fi
    else
      candidate="$(_gaia_physical_directory "$common_directory/..")" || candidate=""
      if [[ -z "$candidate" ]]; then
        _gaia_main_root_fail "linked worktree recorded no core.worktree and the common directory's parent is unreachable" "$git_directory"
        return $?
      fi
    fi
  fi

  # Step 3: validate on the same terms regardless of branch, so an ambient
  # override or an unrelated-repository parent cannot stand in for the
  # repository's own layout.
  if ! _gaia_validate_main_root_candidate "$candidate" "$common_directory"; then
    if [[ "$linked" -eq 1 ]]; then
      _gaia_main_root_fail "linked worktree recorded no valid main root (core.worktree unset or invalid, and the common directory's parent does not validate)" "$git_directory"
    else
      _gaia_main_root_fail "working tree '$candidate' does not validate against its own repository layout" "$git_directory"
    fi
    return $?
  fi

  printf '%s\n' "$candidate"
  return 0
}

gaia_is_linked_worktree() {
  local directory="${1:-}"
  local -a git_command
  if [[ -n "$directory" ]]; then
    git_command=(_gaia_git -C "$directory")
  else
    git_command=(_gaia_git)
  fi
  local base="${directory:-$PWD}"

  local common_directory_raw
  common_directory_raw="$("${git_command[@]}" rev-parse --git-common-dir 2>/dev/null)" || common_directory_raw=""
  [[ -n "$common_directory_raw" ]] || return 1

  local common_directory_absolute common_directory
  common_directory_absolute="$(_gaia_absolute_path "$common_directory_raw" "$base")"
  common_directory="$(_gaia_physical_directory "$common_directory_absolute")" || common_directory=""
  [[ -n "$common_directory" ]] || return 1

  local git_directory_raw git_directory
  git_directory_raw="$("${git_command[@]}" rev-parse --absolute-git-dir 2>/dev/null)" || git_directory_raw=""
  [[ -n "$git_directory_raw" ]] || return 1
  git_directory="$(_gaia_physical_directory "$git_directory_raw")" || git_directory=""
  [[ -n "$git_directory" ]] || return 1

  [[ "$git_directory" != "$common_directory" ]]
}

gaia_resolve_tree_root() {
  local directory="${1:-}"
  local -a git_command
  if [[ -n "$directory" ]]; then
    git_command=(_gaia_git -C "$directory")
  else
    git_command=(_gaia_git)
  fi

  local toplevel
  toplevel="$("${git_command[@]}" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [[ -n "$toplevel" ]] || return 1
  toplevel="$(_gaia_physical_directory "$toplevel")" || return 1
  [[ -n "$toplevel" ]] || return 1
  printf '%s\n' "$toplevel"
  return 0
}

# gaia_resolve_common_directory: see the header contract above.
gaia_resolve_common_directory() {
  local directory="${1:-}"
  local -a git_command
  if [[ -n "$directory" ]]; then
    git_command=(_gaia_git -C "$directory")
  else
    git_command=(_gaia_git)
  fi

  local raw
  raw="$("${git_command[@]}" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [[ -n "$raw" ]] || return 1
  _gaia_physical_directory "$(_gaia_absolute_path "$raw" "${directory:-$PWD}")"
}

# gaia_tree_key: see the header contract above.
gaia_tree_key() {
  local directory="${1:-}"

  local root
  root="$(gaia_resolve_tree_root "$directory")" || {
    printf 'GAIA_TREE_KEY_UNRESOLVABLE: not inside a work tree\n' >&2
    return 1
  }

  # `shasum -a 256` is present on macOS and most Linux; `sha256sum` is the
  # coreutils fallback. Same order and same guard as the repo's other
  # sha256 shims. `printf` (never `echo`) so no trailing newline enters the
  # digest and no backslash sequence is interpreted in a checkout path.
  local digest
  if digest="$(printf '%s' "$root" | shasum -a 256 2>/dev/null)"; then :
  elif digest="$(printf '%s' "$root" | sha256sum 2>/dev/null)"; then :
  else
    printf 'GAIA_TREE_KEY_UNRESOLVABLE: no sha256 tool on PATH (shasum / sha256sum)\n' >&2
    return 1
  fi
  digest="${digest%% *}"
  if [[ -z "$digest" ]]; then
    printf 'GAIA_TREE_KEY_UNRESOLVABLE: sha256 tool produced no digest\n' >&2
    return 1
  fi

  printf '%s\n' "${digest:0:16}"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ "${1:-}" == "--is-worktree" ]]; then
    shift
    gaia_is_linked_worktree "${1:-}"
    exit $?
  fi
  if [[ "${1:-}" == "--tree-root" ]]; then
    shift
    gaia_resolve_tree_root "${1:-}"
    exit $?
  fi
  if [[ "${1:-}" == "--tree-key" ]]; then
    shift
    gaia_tree_key "${1:-}"
    exit $?
  fi
  if [[ "${1:-}" == "--common-dir" ]]; then
    shift
    gaia_resolve_common_directory "${1:-}"
    exit $?
  fi
  gaia_resolve_main_root "${1:-}"
  exit $?
fi
