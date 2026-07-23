#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/main-root-lib.sh, the shared
# main-checkout resolver (SPEC-058 task 2.2). Builds a committed fixture
# harness for every checkout shape git can answer for -- ordinary clone,
# submodule, and separate-git-dir, each with and without a linked worktree --
# plus a symlinked checkout and a battery of adversarial inputs, and asserts
# the resolver's output form, failure diagnostic, and predicate hold in every
# one.
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/main-root-lib.bats`.
#
# Assertion style note: per .claude/rules/bats-assertions.md, non-final
# absence checks use a positive match for the bad case plus an explicit
# `return 1`, never `!`-negation; equality/numeric/empty checks use POSIX
# `[ ... ]`, which fails correctly on every bash version.
#
# Submodule fixtures need `protocol.file.allow=always` for `submodule add`
# against a local-path origin (recent git defaults this narrower); it is
# passed per-invocation via `-c` rather than mutated into any config file.

setup() {
  LIB="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/main-root-lib.sh"
  CLEANUP_DIRS=()
}

teardown() {
  if [ "${#CLEANUP_DIRS[@]}" -gt 0 ]; then
    local d
    for d in "${CLEANUP_DIRS[@]}"; do
      [ -n "$d" ] && rm -rf "$d"
    done
  fi
  return 0
}

# ---------- fixture helpers ----------
# Every fixture root is canonicalized via `mktemp -d` then `pwd -P`: macOS
# resolves /tmp -> /private/tmp inside `git rev-parse`, and the resolver's
# output is compared against these values byte-for-byte, so a non-canonical
# tmp path would desync from what the resolver reports for reasons that have
# nothing to do with the resolver itself (mirrors block-worktree-path-mismatch
# and link-worktree.bats).

git_identity() {
  git -C "$1" config user.email gaia-test@example.com
  git -C "$1" config user.name "GAIA Test"
  git -C "$1" config commit.gpgsign false
}

# make_repo: an ordinary clone. Sets REPO.
make_repo() {
  local raw
  raw=$(mktemp -d -t gaia-mrl-repo-XXXXXX)
  REPO="$(cd "$raw" && pwd -P)"
  CLEANUP_DIRS+=("$REPO")
  git -C "$REPO" init -q --initial-branch=main
  git_identity "$REPO"
  echo init >"$REPO/f"
  git -C "$REPO" add f
  git -C "$REPO" commit -q -m init
}

# make_worktree <repo> <rel> <branch>: a real linked worktree under
# <repo>/.claude/worktrees/<rel>, mirroring how GAIA creates plan/debt
# worktrees. Sets WT to the worktree's absolute path.
make_worktree() {
  local repo="$1" rel="$2" br="$3"
  git -C "$repo" branch "$br"
  mkdir -p "$repo/.claude/worktrees"
  git -C "$repo" worktree add -q "$repo/.claude/worktrees/$rel" "$br"
  WT="$repo/.claude/worktrees/$rel"
}

# make_submodule: a superproject with a real "gaia" submodule at
# <SUPER>/gaia. Sets SUPER, SUB, SUB_ORIGIN.
make_submodule() {
  local sub_raw super_raw
  sub_raw=$(mktemp -d -t gaia-mrl-subsrc-XXXXXX)
  SUB_ORIGIN="$(cd "$sub_raw" && pwd -P)"
  CLEANUP_DIRS+=("$SUB_ORIGIN")
  git -C "$SUB_ORIGIN" init -q --initial-branch=main
  git_identity "$SUB_ORIGIN"
  echo sub >"$SUB_ORIGIN/g"
  git -C "$SUB_ORIGIN" add g
  git -C "$SUB_ORIGIN" commit -q -m init

  super_raw=$(mktemp -d -t gaia-mrl-super-XXXXXX)
  SUPER="$(cd "$super_raw" && pwd -P)"
  CLEANUP_DIRS+=("$SUPER")
  git -C "$SUPER" init -q --initial-branch=main
  git_identity "$SUPER"
  echo root >"$SUPER/r"
  git -C "$SUPER" add r
  git -C "$SUPER" commit -q -m init

  git -C "$SUPER" -c protocol.file.allow=always submodule add -q "$SUB_ORIGIN" gaia
  git -C "$SUPER" commit -q -m "add submodule"
  SUB="$SUPER/gaia"
}

# make_separate_gitdir: a --separate-git-dir main checkout. Sets WORK (the
# working tree), ELSEWHERE (the relocated git dir's parent), GITDIR.
make_separate_gitdir() {
  local origin_raw origin elsewhere_raw work_raw
  origin_raw=$(mktemp -d -t gaia-mrl-sepsrc-XXXXXX)
  origin="$(cd "$origin_raw" && pwd -P)"
  CLEANUP_DIRS+=("$origin")
  git -C "$origin" init -q --initial-branch=main
  git_identity "$origin"
  echo o >"$origin/o"
  git -C "$origin" add o
  git -C "$origin" commit -q -m init

  elsewhere_raw=$(mktemp -d -t gaia-mrl-elsewhere-XXXXXX)
  ELSEWHERE="$(cd "$elsewhere_raw" && pwd -P)"
  CLEANUP_DIRS+=("$ELSEWHERE")
  GITDIR="$ELSEWHERE/gaia.git"

  work_raw=$(mktemp -d -t gaia-mrl-work-XXXXXX)
  WORK="$(cd "$work_raw" && pwd -P)"
  CLEANUP_DIRS+=("$WORK")
  git clone -q --separate-git-dir="$GITDIR" "$origin" "$WORK"
  git_identity "$WORK"
}

# ---------- invocation helpers ----------

# resolve <dir>: runs the executable entry with a dir operand. bats' `run`
# merges stdout and stderr into a single `$output`, and the resolver's
# failure diagnostic is stderr-only by contract, so every invocation here
# discards the target's own stderr *inside* the inner bash -c, before bats
# ever captures anything -- an outer `2>/dev/null` on `run` itself would not
# work, since `run` internally does its own `2>&1` merge for the command
# under test regardless of the ambient fd. This makes `$output` reflect
# stdout alone, matching what these tests assert against. The diagnostic
# tests below capture stderr on its own terms with the mirror-image `2>&1
# 1>/dev/null` form.
resolve() {
  local dir="$1"
  run bash -c 'bash "$1" "$2" 2>/dev/null' _ "$LIB" "$dir"
}

# resolve_from <cwd> <dir>: process cwd=$1 (unrelated to $2), operand=$2.
# Quote-safe delivery: positional args to an inner bash -c rather than
# re-wrapping in an outer single-quoted string (mirrors
# block-worktree-path-mismatch.bats's run_hook_edit_cwd).
resolve_from() {
  local cwd="$1" dir="$2"
  run bash -c 'cd "$1" && bash "$2" "$3" 2>/dev/null' _ "$cwd" "$LIB" "$dir"
}

is_worktree() {
  local dir="$1"
  run bash -c 'bash "$1" --is-worktree "$2" 2>/dev/null' _ "$LIB" "$dir"
}

# resolve_tree <dir>: runs the executable entry's --tree-root operand.
# Mirrors resolve()'s stderr-discard-inside-bash-c note.
resolve_tree() {
  local dir="$1"
  run bash -c 'bash "$1" --tree-root "$2" 2>/dev/null' _ "$LIB" "$dir"
}

# resolve_tree_from <cwd> <dir>: process cwd=$1 (unrelated to $2), operand=$2.
# Mirrors resolve_from().
resolve_tree_from() {
  local cwd="$1" dir="$2"
  run bash -c 'cd "$1" && bash "$2" --tree-root "$3" 2>/dev/null' _ "$cwd" "$LIB" "$dir"
}

# The current (pre-resolver) physical derivation, matching
# .gaia/statusline/gaia-statusline.sh's own formula:
# dirname(absolute(git rev-parse --git-common-dir)), physically resolved via
# `pwd -P`. This is the differential test's oracle for SPEC-058 success
# criterion 2 / MIG-011: the statusline is one of the five existing sites that
# already normalizes physically, so it is the self-consistent predecessor to
# compare against, not the thirteen sites that normalize logically.
old_derivation() {
  local d="$1" common abs
  common="$(git -C "$d" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$common" in
    /*) abs="$common" ;;
    *) abs="$d/$common" ;;
  esac
  (cd "$(dirname "$abs")" 2>/dev/null && pwd -P)
}

# ---------- UAT-001 / UAT-003: submodule ----------

@test "UAT-001: submodule main checkout resolves to the submodule root" {
  make_submodule
  resolve "$SUB"
  [ "$status" -eq 0 ]
  [ "$output" = "$SUB" ]
}

@test "UAT-003: submodule linked worktree resolves to the submodule root, not .git/modules" {
  make_submodule
  make_worktree "$SUB" "w" "subwtbranch"
  resolve "$WT"
  [ "$status" -eq 0 ]
  [ "$output" = "$SUB" ]
}

# ---------- UAT-002 / UAT-009: ordinary clone ----------

@test "UAT-009: ordinary clone main checkout resolves to the clone root" {
  make_repo
  resolve "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO" ]
}

@test "UAT-002: ordinary clone, cwd in a linked worktree resolves to the main root" {
  make_repo
  make_worktree "$REPO" "w" "wtbranch"
  resolve "$WT"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO" ]
}

# ---------- UAT-010: separate-git-dir main ----------

@test "UAT-010: separate-git-dir main checkout resolves to the working tree, not the relocated git dir" {
  make_separate_gitdir
  resolve "$WORK"
  [ "$status" -eq 0 ]
  [ "$output" = "$WORK" ]
  [ "$output" != "$ELSEWHERE" ]
  [ "$output" != "$GITDIR" ]
}

# ---------- UAT-004: separate-git-dir entered from a linked worktree ----------

@test "UAT-004: separate-git-dir linked worktree fails with one named diagnostic, empty stdout, unmodified git dir" {
  make_separate_gitdir
  make_worktree "$WORK" "w" "sepwtbranch"
  local expected_gitdir gitdir_before gitdir_after
  expected_gitdir="$(cd "$(git -C "$WT" rev-parse --absolute-git-dir)" && pwd -P)"
  gitdir_before="$(find "$GITDIR" | sort)"

  resolve "$WT"
  [ "$status" -eq 3 ]
  [ -z "$output" ]

  gitdir_after="$(find "$GITDIR" | sort)"
  [ "$gitdir_before" = "$gitdir_after" ]

  run bash -c 'bash "$1" "$2" 2>&1 1>/dev/null' _ "$LIB" "$WT"
  grep -qF -- "GAIA_MAIN_ROOT_UNRESOLVABLE" <<<"$output" || return 1
  grep -qF -- "$expected_gitdir" <<<"$output" || return 1
  [ "$(wc -l <<<"$output" | tr -d ' ')" -eq 1 ]
}

# ---------- predicate: directive 4 + UAT-006 ----------

@test "predicate: ordinary clone linked worktree answers yes (exit 0), prints nothing" {
  make_repo
  make_worktree "$REPO" "w" "wtbranch2"
  is_worktree "$WT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "predicate: submodule linked worktree answers yes (exit 0), prints nothing" {
  make_submodule
  make_worktree "$SUB" "w" "subwtbranch2"
  is_worktree "$WT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "UAT-006: predicate answers no in a submodule main checkout (the shape the old predicate got wrong)" {
  make_submodule
  is_worktree "$SUB"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "predicate: ordinary clone main checkout answers no" {
  make_repo
  is_worktree "$REPO"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "predicate: a directory outside any git repository answers no (indeterminate), prints nothing" {
  local nongit
  nongit=$(mktemp -d -t gaia-mrl-nongit-XXXXXX)
  CLEANUP_DIRS+=("$nongit")
  is_worktree "$nongit"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "predicate: two independent calls for two different directories in one process do not leak state" {
  make_repo
  make_worktree "$REPO" "w" "wtbranch3"
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    if gaia_is_linked_worktree "$2"; then a=0; else a=1; fi
    if gaia_is_linked_worktree "$3"; then b=0; else b=1; fi
    printf "%s\n%s\n" "$a" "$b"
  ' _ "$LIB" "$WT" "$REPO"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "0" ]
  [ "${lines[1]}" = "1" ]
}

# ---------- dir operand: UAT-008 ----------

@test "UAT-008: a supplied dir operand resolves correctly when the process cwd is unrelated to it" {
  make_repo
  local neutral
  neutral=$(mktemp -d -t gaia-mrl-neutral-XXXXXX)
  CLEANUP_DIRS+=("$neutral")
  resolve_from "$neutral" "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO" ]
}

@test "UAT-008: two independent resolutions for two different directories succeed in one process" {
  make_repo
  make_submodule
  local neutral
  neutral=$(mktemp -d -t gaia-mrl-neutral2-XXXXXX)
  CLEANUP_DIRS+=("$neutral")
  run bash -c '
    cd "$1" || exit 1
    # shellcheck disable=SC1090
    source "$2"
    a="$(gaia_resolve_main_root "$3")" || exit 10
    b="$(gaia_resolve_main_root "$4")" || exit 11
    printf "%s\n%s\n" "$a" "$b"
  ' _ "$neutral" "$LIB" "$REPO" "$SUB"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$REPO" ]
  [ "${lines[1]}" = "$SUB" ]
  [ "${lines[0]}" != "${lines[1]}" ]
}

# ---------- output form: directive 7 ----------

@test "output form: stdout is exactly one line terminated by a single newline on success" {
  make_repo
  local outfile
  outfile=$(mktemp -t gaia-mrl-outfile-XXXXXX)
  CLEANUP_DIRS+=("$outfile")
  bash "$LIB" "$REPO" >"$outfile" 2>/dev/null
  [ "$(wc -l <"$outfile" | tr -d ' ')" -eq 1 ]
  [ "$(tail -c1 "$outfile" | od -An -tx1 | tr -d ' ')" = "0a" ]
  [ "$(cat "$outfile")" = "$REPO" ]
}

# TST-014: replaces the entailed "does not print a .git-prefixed path"
# negative (which cannot fail unless the exact-value positive already has)
# with the non-entailed property the audit asked for: every failure path
# leaves stdout completely empty, which is a strictly stronger and
# independently-checkable guarantee that no path -- git-dir-prefixed or
# otherwise -- ever reaches stdout on a failed resolution.
@test "output form: every failure path leaves stdout completely empty" {
  make_separate_gitdir
  make_worktree "$WORK" "w" "sepwtbranch2"
  resolve "$WT"
  [ "$status" -ne 0 ]
  [ -z "$output" ]

  local bare
  bare=$(mktemp -d -t gaia-mrl-bare-XXXXXX)
  CLEANUP_DIRS+=("$bare")
  git init -q --bare "$bare"
  resolve "$bare"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# ---------- bare repository / no working tree: directive 6 ----------

@test "a bare repository fails with a named diagnostic rather than silently falling back" {
  local bare
  bare=$(mktemp -d -t gaia-mrl-bare2-XXXXXX)
  CLEANUP_DIRS+=("$bare")
  git init -q --bare "$bare"

  run bash -c 'bash "$1" "$2" 2>&1 1>/dev/null' _ "$LIB" "$bare"
  grep -qF -- "GAIA_MAIN_ROOT_UNRESOLVABLE" <<<"$output" || return 1

  resolve "$bare"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# ---------- differential: directive 20 / MIG-011 ----------

@test "differential: ordinary clone main matches the current physical derivation" {
  make_repo
  local old
  old="$(old_derivation "$REPO")"
  resolve "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "$old" ]
}

@test "differential: ordinary clone linked worktree matches the current physical derivation" {
  make_repo
  make_worktree "$REPO" "w" "wtbranch4"
  local old
  old="$(old_derivation "$WT")"
  resolve "$WT"
  [ "$status" -eq 0 ]
  [ "$output" = "$old" ]
}

@test "differential: a symlinked ordinary-clone checkout matches the current physical derivation" {
  make_repo
  local symlink old
  symlink="${REPO}-symlink"
  ln -s "$REPO" "$symlink"
  CLEANUP_DIRS+=("$symlink")
  old="$(old_derivation "$symlink")"
  resolve "$symlink"
  [ "$status" -eq 0 ]
  [ "$output" = "$old" ]
  [ "$output" = "$REPO" ]
}

# ---------- symlinked-checkout predicate: directive 12 ----------

@test "symlinked checkout: predicate answers no in the main checkout reached via a symlink" {
  make_repo
  local symlink
  symlink="${REPO}-symlink2"
  ln -s "$REPO" "$symlink"
  CLEANUP_DIRS+=("$symlink")
  is_worktree "$symlink"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ---------- adversarial: directive 16 ----------

@test "adversarial: core.worktree pointing outside the repo at a nonexistent path fails rather than returning it" {
  make_repo
  make_worktree "$REPO" "w" "wtbranch5"
  local common_config
  common_config="$(cd "$REPO/.git" && pwd -P)/config"
  git config --file "$common_config" core.worktree "/nonexistent/evil/path"
  resolve "$WT"
  git config --file "$common_config" --unset core.worktree || true
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "adversarial: core.worktree pointing at an unrelated real repository fails rather than returning it" {
  make_repo
  make_worktree "$REPO" "w" "wtbranch6"
  local other common_config
  other=$(mktemp -d -t gaia-mrl-other-XXXXXX)
  CLEANUP_DIRS+=("$other")
  git -C "$other" init -q --initial-branch=main
  common_config="$(cd "$REPO/.git" && pwd -P)/config"
  git config --file "$common_config" core.worktree "$other"
  resolve "$WT"
  git config --file "$common_config" --unset core.worktree || true
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "adversarial: GIT_DIR and GIT_WORK_TREE exported in the environment do not override the layout-derived root" {
  make_repo
  local other neutral
  other=$(mktemp -d -t gaia-mrl-other2-XXXXXX)
  CLEANUP_DIRS+=("$other")
  git -C "$other" init -q --initial-branch=main
  neutral=$(mktemp -d -t gaia-mrl-neutral3-XXXXXX)
  CLEANUP_DIRS+=("$neutral")

  run bash -c 'cd "$1" && GIT_DIR="$2/.git" GIT_WORK_TREE="$2" bash "$3" "$4"' _ "$neutral" "$other" "$LIB" "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO" ]
  [ "$output" != "$other" ]
}

# ---------- gaia_resolve_tree_root (task 3.6) ----------
# The per-tree counterpart of gaia_resolve_main_root: "which tree is this",
# not "where is main". Its one behavioral divergence from gaia_resolve_main_root
# is the whole point -- a linked worktree resolves to ITS OWN root, not main's.

@test "gaia_resolve_tree_root: ordinary clone resolves to the clone root" {
  make_repo
  resolve_tree "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO" ]
}

@test "gaia_resolve_tree_root: a linked worktree resolves to the WORKTREE's own root, diverging from gaia_resolve_main_root" {
  make_repo
  make_worktree "$REPO" "w" "treewtbranch"
  resolve_tree "$WT"
  [ "$status" -eq 0 ]
  [ "$output" = "$WT" ]
  [ "$output" != "$REPO" ]

  # Parity check: gaia_resolve_main_root answers the OTHER root for the same dir.
  resolve "$WT"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO" ]
}

@test "gaia_resolve_tree_root: physical-form parity with gaia_resolve_main_root for the main checkout itself" {
  make_repo
  resolve_tree "$REPO"
  [ "$status" -eq 0 ]
  local tree_output="$output"
  resolve "$REPO"
  [ "$status" -eq 0 ]
  [ "$tree_output" = "$output" ]
}

@test "gaia_resolve_tree_root: a symlinked checkout path resolves to the physical (non-symlink) root" {
  make_repo
  local symlink
  symlink="${REPO}-treesymlink"
  ln -s "$REPO" "$symlink"
  CLEANUP_DIRS+=("$symlink")
  resolve_tree "$symlink"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO" ]
}

@test "gaia_resolve_tree_root: outside any work tree fails, empty stdout" {
  local nongit
  nongit=$(mktemp -d -t gaia-mrl-treenongit-XXXXXX)
  CLEANUP_DIRS+=("$nongit")
  resolve_tree "$nongit"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "gaia_resolve_tree_root: a supplied dir operand resolves correctly when the process cwd is unrelated to it" {
  make_repo
  local neutral
  neutral=$(mktemp -d -t gaia-mrl-treeneutral-XXXXXX)
  CLEANUP_DIRS+=("$neutral")
  resolve_tree_from "$neutral" "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO" ]
}

@test "gaia_resolve_tree_root: two independent resolutions for two different trees succeed in one process" {
  make_repo
  make_worktree "$REPO" "w" "treewtbranch2"
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    a="$(gaia_resolve_tree_root "$2")" || exit 10
    b="$(gaia_resolve_tree_root "$3")" || exit 11
    printf "%s\n%s\n" "$a" "$b"
  ' _ "$LIB" "$REPO" "$WT"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$REPO" ]
  [ "${lines[1]}" = "$WT" ]
  [ "${lines[0]}" != "${lines[1]}" ]
}

@test "gaia_resolve_tree_root: GIT_DIR and GIT_WORK_TREE exported in the environment do not override the layout-derived root" {
  make_repo
  local other neutral
  other=$(mktemp -d -t gaia-mrl-treeother-XXXXXX)
  CLEANUP_DIRS+=("$other")
  git -C "$other" init -q --initial-branch=main
  neutral=$(mktemp -d -t gaia-mrl-treeneutral2-XXXXXX)
  CLEANUP_DIRS+=("$neutral")

  run bash -c 'cd "$1" && GIT_DIR="$2/.git" GIT_WORK_TREE="$2" bash "$3" --tree-root "$4"' _ "$neutral" "$other" "$LIB" "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO" ]
  [ "$output" != "$other" ]
}

# ---------- structural ----------

@test "structural: main-root-lib.sh is executable" {
  [ -x "$LIB" ]
}

@test "structural: sourcing the library defines all three functions with no side effects" {
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    type gaia_resolve_main_root >/dev/null
    type gaia_is_linked_worktree >/dev/null
    type gaia_resolve_tree_root >/dev/null
    echo OK
  ' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}
