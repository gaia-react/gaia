#!/usr/bin/env bash
# Catch-up merge fixtures for bats suites: a scratch repository with a bare
# `origin`, a base branch whose commits land on origin and arrive through
# `refs/remotes/origin/<base>`, and a feature branch that merges the base,
# other refs, or an octopus of them. Sourced from a suite's setup():
#
#   . "$REPO_ROOT/.gaia/tests/helpers/catchup-fixture.sh"
#
# Base commits are made in a detached worktree beside the sandbox (never in
# the sandbox's own checkout), so a base commit can land while the branch is
# mid-merge, and a sandbox whose checkout is the base branch itself still
# works. No function here runs git against this checkout, and none uses `cd`.
#
# Variables set: CATCHUP_ROOT (the sandbox checkout), CATCHUP_ORIGIN (bare
# origin), CATCHUP_BASE_BRANCH, CATCHUP_BASE_WORKTREE, CATCHUP_BRANCH (the
# feature branch, when there is one), CATCHUP_HEAD (after any commit or merge).
#
# The suites read these variables, which the linter cannot see from here.
# shellcheck disable=SC2034

# catchup_git <args...>: git in the sandbox checkout.
catchup_git() {
  git -C "$CATCHUP_ROOT" "$@"
}

# catchup_base_git <args...>: git in the base worktree.
catchup_base_git() {
  git -C "$CATCHUP_BASE_WORKTREE" "$@"
}

# _catchup_configure <repository>: commit identity, no signing, no hooks, so a
# developer's global configuration cannot change what a fixture builds.
_catchup_configure() {
  git -C "$1" config user.email gaia-test@example.com &&
    git -C "$1" config user.name "GAIA Test" &&
    git -C "$1" config commit.gpgsign false &&
    git -C "$1" config core.hooksPath /dev/null &&
    git -C "$1" config advice.detachedHead false &&
    git -C "$1" config merge.ff true
}

_catchup_set_head() {
  CATCHUP_HEAD="$(catchup_git rev-parse HEAD)"
}

# _catchup_write <directory> <path> <content-file-or-text>: write the file,
# copying <content-file-or-text> when it names an existing file, else writing
# it as the file's text plus a trailing newline.
_catchup_write() {
  mkdir -p "$(dirname "$1/$2")" || return 1
  if [ -f "$3" ]; then
    cp "$3" "$1/$2"
  else
    printf '%s\n' "$3" >"$1/$2"
  fi
}

# _catchup_base_attach: create the base worktree beside the sandbox, detached at
# the origin's base tip.
_catchup_base_attach() {
  CATCHUP_BASE_WORKTREE="${CATCHUP_ROOT%/}.catchup-base"
  rm -rf "$CATCHUP_BASE_WORKTREE"
  catchup_git worktree add -q --detach "$CATCHUP_BASE_WORKTREE" "refs/remotes/origin/$CATCHUP_BASE_BRANCH" >/dev/null 2>&1
}

# _catchup_base_begin: move the base worktree to the origin's current base tip.
_catchup_base_begin() {
  catchup_git fetch -q origin || return 1
  catchup_base_git checkout -q --detach "refs/remotes/origin/$CATCHUP_BASE_BRANCH"
}

# _catchup_base_publish <message>: commit what is staged in the base worktree,
# push it to the origin's base branch, and fetch it into the sandbox.
_catchup_base_publish() {
  catchup_base_git commit -q -m "$1" || return 1
  catchup_base_git push -q origin "HEAD:refs/heads/$CATCHUP_BASE_BRANCH" 2>/dev/null || return 1
  catchup_git fetch -q origin
}

# catchup_init <directory>: a fresh sandbox under <directory> with a bare
# origin, `main` pushed, `refs/remotes/origin/HEAD` at `origin/main`, and the
# feature branch `feat/catchup` checked out, its audit base cached as `main`.
catchup_init() {
  local directory="$1"
  [ -n "$directory" ] || return 1
  mkdir -p "$directory" || return 1
  CATCHUP_ORIGIN="$directory/origin.git"
  CATCHUP_ROOT="$directory/repository"
  CATCHUP_BASE_BRANCH=main
  CATCHUP_BRANCH=feat/catchup
  git init -q --bare -b main "$CATCHUP_ORIGIN" || return 1
  git init -q -b main "$CATCHUP_ROOT" || return 1
  _catchup_configure "$CATCHUP_ROOT" || return 1
  printf 'seed\n' >"$CATCHUP_ROOT/README.md"
  catchup_git add -A && catchup_git commit -q -m seed || return 1
  catchup_git remote add origin "$CATCHUP_ORIGIN" || return 1
  catchup_git push -q origin main 2>/dev/null || return 1
  catchup_git fetch -q origin || return 1
  catchup_git remote set-head origin main >/dev/null || return 1
  catchup_git checkout -q -b "$CATCHUP_BRANCH" || return 1
  catchup_git config "branch.$CATCHUP_BRANCH.gaia-audit-base" main || return 1
  _catchup_base_attach || return 1
  _catchup_set_head
}

# catchup_add_origin <existing-repository> [<base-branch>=main] [--feature
# <name>]: retrofit a bare origin and `refs/remotes/origin/<base>` onto an
# existing sandbox, and cache <base-branch> as the checked-out branch's audit
# base. With --feature, also create and check out <name> after pushing the base.
catchup_add_origin() {
  local repository="$1" base_branch=main feature="" current
  [ -n "$repository" ] || return 1
  shift
  if [ "$#" -gt 0 ] && [ "$1" != "--feature" ]; then
    base_branch="$1"
    shift
  fi
  if [ "${1:-}" = "--feature" ]; then
    feature="${2:-}"
    [ -n "$feature" ] || return 1
  fi
  CATCHUP_ROOT="${repository%/}"
  CATCHUP_ORIGIN="$CATCHUP_ROOT.catchup-origin.git"
  CATCHUP_BASE_BRANCH="$base_branch"
  _catchup_configure "$CATCHUP_ROOT" || return 1
  rm -rf "$CATCHUP_ORIGIN"
  git init -q --bare -b "$base_branch" "$CATCHUP_ORIGIN" || return 1
  catchup_git remote remove origin >/dev/null 2>&1 || true
  catchup_git remote add origin "$CATCHUP_ORIGIN" || return 1
  catchup_git push -q origin "refs/heads/$base_branch:refs/heads/$base_branch" 2>/dev/null || return 1
  catchup_git fetch -q origin || return 1
  catchup_git remote set-head origin "$base_branch" >/dev/null || return 1
  if [ -n "$feature" ]; then
    catchup_git checkout -q -b "$feature" || return 1
  fi
  current="$(catchup_git symbolic-ref -q --short HEAD)" || current=""
  CATCHUP_BRANCH="$current"
  if [ -n "$current" ]; then
    catchup_git config "branch.$current.gaia-audit-base" "$base_branch" || return 1
  fi
  _catchup_base_attach || return 1
  _catchup_set_head
}

# catchup_base_commit <path> <content-file-or-text>: commit the file on the
# base, push it to origin and fetch it.
catchup_base_commit() {
  _catchup_base_begin || return 1
  _catchup_write "$CATCHUP_BASE_WORKTREE" "$1" "$2" || return 1
  catchup_base_git add -- "$1" || return 1
  _catchup_base_publish "base: change $1"
}

# catchup_branch_commit <path> <content-file-or-text>: commit the file on the
# checked-out branch.
catchup_branch_commit() {
  _catchup_write "$CATCHUP_ROOT" "$1" "$2" || return 1
  catchup_git add -- "$1" && catchup_git commit -q -m "branch: change $1" || return 1
  _catchup_set_head
}

# catchup_merge_base [--no-commit]: merge `refs/remotes/origin/<base>` into the
# branch. --no-commit leaves the merge open (conflicted or not) for the caller
# to resolve and commit, and returns 0 either way.
catchup_merge_base() {
  catchup_git fetch -q origin || return 1
  if [ "${1:-}" = "--no-commit" ]; then
    # A conflict is the expected outcome here, so its status must not trip a
    # caller running under errexit.
    catchup_git merge -q --no-ff --no-commit "refs/remotes/origin/$CATCHUP_BASE_BRANCH" >/dev/null 2>&1 || true
    return 0
  fi
  catchup_git merge -q --no-edit "refs/remotes/origin/$CATCHUP_BASE_BRANCH" >/dev/null || return 1
  _catchup_set_head
}

# catchup_commit_merge: commit an open merge with everything in the work tree
# staged, after the caller resolved it.
catchup_commit_merge() {
  catchup_git add -A && catchup_git commit -q --no-edit || return 1
  _catchup_set_head
}

# catchup_merge_ref <ref>: merge a ref that is not the base.
catchup_merge_ref() {
  catchup_git merge -q --no-edit "$1" >/dev/null || return 1
  _catchup_set_head
}

# catchup_octopus <ref>...: one octopus merge of every ref.
catchup_octopus() {
  catchup_git merge -q --no-edit "$@" >/dev/null || return 1
  _catchup_set_head
}

# catchup_side_ref <name> <path> <content-file-or-text>: a ref named <name>
# forked from the base tip with one commit; the branch can merge it.
catchup_side_ref() {
  _catchup_base_begin || return 1
  _catchup_write "$CATCHUP_BASE_WORKTREE" "$2" "$3" || return 1
  catchup_base_git add -- "$2" && catchup_base_git commit -q -m "side: change $2" || return 1
  catchup_git update-ref "refs/heads/$1" "$(catchup_base_git rev-parse HEAD)"
}

# catchup_merge_into_base <ref>: merge <ref> into the base and publish it, as a
# side branch landing on the base through its own pull request.
catchup_merge_into_base() {
  _catchup_base_begin || return 1
  catchup_base_git merge -q --no-ff --no-edit "$1" >/dev/null || return 1
  catchup_base_git push -q origin "HEAD:refs/heads/$CATCHUP_BASE_BRANCH" 2>/dev/null || return 1
  catchup_git fetch -q origin
}

# catchup_criss_cross: leave HEAD with two merge bases against the base tip.
# The base gains a commit B1, the branch a commit C1; the base then merges C1
# while the branch merges B1, so B1 and C1 are both best common ancestors.
catchup_criss_cross() {
  local base_commit branch_commit
  catchup_base_commit criss-cross-base.txt "base side" || return 1
  base_commit="$(catchup_git rev-parse "refs/remotes/origin/$CATCHUP_BASE_BRANCH")" || return 1
  catchup_branch_commit criss-cross-branch.txt "branch side" || return 1
  branch_commit="$CATCHUP_HEAD"
  catchup_merge_into_base "$branch_commit" || return 1
  catchup_merge_ref "$base_commit"
}

# catchup_rename_on_base <from> <to>: rename a file on the base.
catchup_rename_on_base() {
  _catchup_base_begin || return 1
  mkdir -p "$(dirname "$CATCHUP_BASE_WORKTREE/$2")" || return 1
  catchup_base_git mv -- "$1" "$2" || return 1
  _catchup_base_publish "base: rename $1 to $2"
}

# catchup_delete_on_base <path>: delete a file on the base.
catchup_delete_on_base() {
  _catchup_base_begin || return 1
  catchup_base_git rm -q -- "$1" || return 1
  _catchup_base_publish "base: delete $1"
}

# _catchup_side_directory <base|branch|worktree>: where the next edit lands;
# `worktree` is the sandbox checkout without committing (for an open merge).
_catchup_side_directory() {
  case "$1" in
    base) printf '%s\n' "$CATCHUP_BASE_WORKTREE" ;;
    branch | worktree) printf '%s\n' "$CATCHUP_ROOT" ;;
    *) return 1 ;;
  esac
}

# _catchup_side_finish <side> <path> <message>: commit the edit on its side.
_catchup_side_finish() {
  case "$1" in
    base)
      catchup_base_git add -A -- "$2" || return 1
      _catchup_base_publish "$3"
      ;;
    branch)
      catchup_git add -A -- "$2" && catchup_git commit -q -m "$3" || return 1
      _catchup_set_head
      ;;
    worktree) catchup_git add -A -- "$2" ;;
  esac
}

# catchup_symlink <base|branch|worktree> <path> <target>: point a symlink.
catchup_symlink() {
  local directory
  directory="$(_catchup_side_directory "$1")" || return 1
  [ "$1" != base ] || _catchup_base_begin || return 1
  mkdir -p "$(dirname "$directory/$2")" || return 1
  rm -f "$directory/$2"
  ln -s "$3" "$directory/$2" || return 1
  _catchup_side_finish "$1" "$2" "$1: symlink $2"
}

# catchup_mode <base|branch|worktree> <path> <+x|-x>: change a file's mode.
catchup_mode() {
  local directory
  directory="$(_catchup_side_directory "$1")" || return 1
  [ "$1" != base ] || _catchup_base_begin || return 1
  chmod "$3" "$directory/$2" || return 1
  _catchup_side_finish "$1" "$2" "$1: mode $2"
}

# catchup_binary <base|branch|worktree> <path> <seed>: write a small binary
# file (it carries NUL bytes) whose bytes depend on <seed>.
catchup_binary() {
  local directory
  directory="$(_catchup_side_directory "$1")" || return 1
  [ "$1" != base ] || _catchup_base_begin || return 1
  mkdir -p "$(dirname "$directory/$2")" || return 1
  printf '\000\001\002%s\000\377' "$3" >"$directory/$2" || return 1
  _catchup_side_finish "$1" "$2" "$1: binary $2"
}

# catchup_lines <count> <tag> [<line>=<replacement>...]: print <count> lines
# `<tag> <i>`, replacing line i with <replacement> for each pair, and an
# empty <replacement> after `+` inserting instead (`3+=text` adds a line after
# line 3).
catchup_lines() {
  local count="$1" tag="$2" index=1 pair replaced
  shift 2
  while [ "$index" -le "$count" ]; do
    replaced=0
    for pair in "$@"; do
      case "$pair" in
        "$index="*)
          printf '%s\n' "${pair#*=}"
          replaced=1
          ;;
      esac
    done
    [ "$replaced" = 1 ] || printf '%s %s\n' "$tag" "$index"
    for pair in "$@"; do
      case "$pair" in
        "$index+="*) printf '%s\n' "${pair#*=}" ;;
      esac
    done
    index=$((index + 1))
  done
}
