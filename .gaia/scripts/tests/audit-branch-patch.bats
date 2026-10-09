#!/usr/bin/env bats
#
# Conformance suite for .claude/hooks/lib/audit-branch-patch.sh: the branch-own
# patch library that keys and scopes the Code Audit Team gate. Every fixture is
# a scratch repository built by .gaia/tests/helpers/catchup-fixture.sh with a
# bare origin and a base branch arriving through refs/remotes/origin/main.
#
# Guards that a comparison alone cannot prove able to fail are re-run against a
# scratch copy of the library with that guard disabled by a sed mutation, and
# the mutated run must reach the outcome the guard exists to prevent.
#
# Run under bash 5: `bash .gaia/scripts/bats5.sh
# .gaia/scripts/tests/audit-branch-patch.bats < /dev/null`.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LIBRARY="$REPO_ROOT/.claude/hooks/lib/audit-branch-patch.sh"
  # shellcheck source=.gaia/tests/helpers/catchup-fixture.sh
  . "$REPO_ROOT/.gaia/tests/helpers/catchup-fixture.sh"
  # shellcheck source=.claude/hooks/lib/audit-branch-patch.sh
  . "$LIBRARY"
  catchup_init "$BATS_TEST_TMPDIR/sandbox"
}

# tip: the base tip as the local remote-tracking ref reports it.
tip() {
  catchup_git rev-parse refs/remotes/origin/main
}

# identities_text [<library>]: the branch-own identities of HEAD, one
# `<identity>\t<path>` line per record, computed by <library> (default: the
# real one) in a subshell so a mutated copy never leaks into the suite.
identities_text() {
  local library="${1:-$LIBRARY}"
  (
    # shellcheck source=/dev/null
    . "$library"
    merge_base="$(audit_branch_patch_merge_base "$CATCHUP_ROOT" "$(tip)")" || exit 1
    audit_branch_patch_identities "$CATCHUP_ROOT" "$merge_base" HEAD | tr '\0' '\n'
  )
}

# identity_of <path> [<library>]: the identity of one path, empty when absent.
identity_of() {
  identities_text "${2:-}" | awk -F '\t' -v path="$1" '$2 == path { print $1 }'
}

# paths_of <identities text>: the path column.
paths_of() {
  printf '%s\n' "$1" | awk -F '\t' 'NF { print $2 }'
}

# mutate <name> <sed program>: a scratch copy of the library with one guard
# disabled; fails when the mutation changed nothing, so a stale pattern can
# never pass for a disabled guard.
mutate() {
  local copy="$BATS_TEST_TMPDIR/$1.sh"
  sed -e "$2" "$LIBRARY" >"$copy"
  if cmp -s "$copy" "$LIBRARY"; then
    printf 'mutation %s changed nothing\n' "$1" >&2
    return 1
  fi
  printf '%s\n' "$copy"
}

# lines_file <name> <count> [<line>=<text> | <line>+=<text>...]: a numbered
# text file in the test directory, for the commit helpers.
lines_file() {
  local file="$BATS_TEST_TMPDIR/$1"
  shift
  catchup_lines "$1" line "${@:2}" >"$file"
  printf '%s\n' "$file"
}

# seed_base <path> <count>: a numbered file on the base, merged into the
# branch before the branch's own work starts.
seed_base() {
  catchup_base_commit "$1" "$(lines_file "seed-$RANDOM" "$2")"
  catchup_merge_base
}

# ---------------------------------------------------------------------------
# Clean catch-up and the context window
# ---------------------------------------------------------------------------

@test "a clean catch-up keeps every identity byte-identical and adds no base-only path" {
  seed_base P.txt 40
  catchup_base_commit .claude/hooks/lib/machinery.sh "machinery one"
  catchup_merge_base
  catchup_branch_commit P.txt "$(lines_file p-branch 40 30='branch thirty')"
  before="$(identities_text)"
  [ -n "$before" ]

  catchup_base_commit P.txt "$(lines_file p-base 40 2='base two' 5+='base inserted')"
  catchup_base_commit U.txt "untouched by the branch"
  catchup_base_commit .claude/hooks/lib/machinery.sh "machinery two"
  catchup_merge_base
  # The base's line numbers moved under the branch hunk.
  catchup_git show HEAD:P.txt | grep -qx 'base inserted'

  after="$(identities_text)"
  [ "$after" = "$before" ]
  [ "$(paths_of "$after")" = "P.txt" ]
}

@test "a base edit within three lines of a branch hunk rotates that path and only that path" {
  seed_base P.txt 40
  catchup_branch_commit P.txt "$(lines_file p-branch 40 25='branch twenty-five')"
  catchup_branch_commit Q.txt "branch only"
  before_p="$(identity_of P.txt)"
  before_q="$(identity_of Q.txt)"

  catchup_base_commit P.txt "$(lines_file p-base 40 22='base twenty-two')"
  catchup_merge_base

  [ -n "$before_p" ]
  [ "$(identity_of P.txt)" != "$before_p" ]
  [ "$(identity_of Q.txt)" = "$before_q" ]
}

@test "an evil merge rotates the edited path and no other; a path-name-only identity misses it" {
  seed_base P.txt 40
  seed_base Q.txt 40
  catchup_branch_commit P.txt "$(lines_file p-branch 40 25='branch p')"
  catchup_branch_commit Q.txt "$(lines_file q-branch 40 10='branch q')"
  path_only="$(mutate path-only '/# frame: modes$/d; /# frame: hunks$/d; /# frame: blobs$/d')"
  before="$(identities_text)"
  before_mutated="$(identities_text "$path_only")"

  catchup_base_commit U.txt "base only"
  catchup_merge_base --no-commit
  lines_file q-evil 40 10='branch q' 30='evil edit' >/dev/null
  cp "$BATS_TEST_TMPDIR/q-evil" "$CATCHUP_ROOT/Q.txt"
  catchup_commit_merge
  after="$(identities_text)"

  [ "$(paths_of "$after")" = "$(printf 'P.txt\nQ.txt')" ]
  [ "$(printf '%s\n' "$after" | grep 'P.txt')" = "$(printf '%s\n' "$before" | grep 'P.txt')" ]
  [ "$(printf '%s\n' "$after" | grep 'Q.txt')" != "$(printf '%s\n' "$before" | grep 'Q.txt')" ]
  # Disabled guard: hashing only the path cannot see the evil edit.
  [ "$(identities_text "$path_only")" = "$before_mutated" ]
}

@test "relocating an unchanged branch line rotates by its context, in a merge and in a branch commit" {
  seed_base P.txt 20
  catchup_base_commit P.txt "$(lines_file p-call 20 10='call()')"
  catchup_merge_base
  catchup_branch_commit P.txt "$(lines_file p-guarded 20 10='call()' 9+='guard()')"
  no_context="$(mutate no-context 's/-U3/-U0/')"

  # Paired negative: a base edit more than three lines away, merged cleanly.
  before="$(identity_of P.txt)"
  before_no_context="$(identity_of P.txt "$no_context")"
  catchup_base_commit P.txt "$(lines_file p-far 20 10='call()' 1='base far away')"
  catchup_merge_base
  [ "$(identity_of P.txt)" = "$before" ]

  # Inside a merge resolution.
  before="$(identity_of P.txt)"
  before_no_context="$(identity_of P.txt "$no_context")"
  catchup_base_commit U.txt "base only"
  catchup_merge_base --no-commit
  lines_file p-moved 20 10='call()' 1='base far away' 10+='guard()' >/dev/null
  cp "$BATS_TEST_TMPDIR/p-moved" "$CATCHUP_ROOT/P.txt"
  catchup_commit_merge
  [ "$(identity_of P.txt)" != "$before" ]
  [ "$(identity_of P.txt "$no_context")" = "$before_no_context" ]

  # In an ordinary branch commit, moving it back.
  before="$(identity_of P.txt)"
  before_no_context="$(identity_of P.txt "$no_context")"
  catchup_branch_commit P.txt "$(lines_file p-back 20 10='call()' 1='base far away' 9+='guard()')"
  [ "$(identity_of P.txt)" != "$before" ]
  [ "$(identity_of P.txt "$no_context")" = "$before_no_context" ]
}

# ---------------------------------------------------------------------------
# Whitespace, mode, symlink and binary edits inside a merge
# ---------------------------------------------------------------------------

@test "a whitespace-only edit inside a merge rotates; a clean catch-up over one does not; -w misses it" {
  seed_base P.txt 40
  seed_base W.txt 20
  catchup_branch_commit P.txt "$(lines_file p-branch 40 30='branch thirty')"
  catchup_branch_commit W.txt "$(lines_file w-branch 20 5='line 5 ')"
  ignore_whitespace="$(mutate ignore-whitespace 's/-U3/-U3 -w/')"

  before_w="$(identity_of W.txt)"
  catchup_base_commit U.txt "base one"
  catchup_merge_base
  [ "$(identity_of W.txt)" = "$before_w" ]

  before="$(identity_of P.txt)"
  before_mutated="$(identity_of P.txt "$ignore_whitespace")"
  catchup_base_commit U.txt "base two"
  catchup_merge_base --no-commit
  lines_file p-space 40 30='branch thirty' 12='line 12	' >/dev/null
  cp "$BATS_TEST_TMPDIR/p-space" "$CATCHUP_ROOT/P.txt"
  catchup_commit_merge
  [ "$(identity_of P.txt)" != "$before" ]
  [ "$(identity_of P.txt "$ignore_whitespace")" = "$before_mutated" ]
}

@test "a mode edit inside a merge rotates; a clean catch-up over one does not; dropping the mode frame misses it" {
  seed_base P.txt 40
  seed_base X.sh 10
  catchup_branch_commit P.txt "$(lines_file p-branch 40 30='branch thirty')"
  catchup_mode branch X.sh +x
  no_mode="$(mutate no-mode '/# frame: modes$/d')"

  before_x="$(identity_of X.sh)"
  [ -n "$before_x" ]
  catchup_base_commit U.txt "base one"
  catchup_merge_base
  [ "$(identity_of X.sh)" = "$before_x" ]

  before="$(identity_of P.txt)"
  before_mutated="$(identity_of P.txt "$no_mode")"
  catchup_base_commit U.txt "base two"
  catchup_merge_base --no-commit
  catchup_mode worktree P.txt +x
  catchup_commit_merge
  [ "$(identity_of P.txt)" != "$before" ]
  [ "$(identity_of P.txt "$no_mode")" = "$before_mutated" ]
}

@test "a symlink retarget inside a merge rotates; a clean catch-up over one does not; dropping blob ids misses it" {
  catchup_symlink branch link target-one
  catchup_symlink branch steady target-steady
  no_blobs="$(mutate no-blobs '/# frame: blobs$/d')"

  before_steady="$(identity_of steady)"
  [ -n "$before_steady" ]
  catchup_base_commit U.txt "base one"
  catchup_merge_base
  [ "$(identity_of steady)" = "$before_steady" ]

  before="$(identity_of link)"
  before_mutated="$(identity_of link "$no_blobs")"
  catchup_base_commit U.txt "base two"
  catchup_merge_base --no-commit
  catchup_symlink worktree link target-two
  catchup_commit_merge
  [ "$(identity_of link)" != "$before" ]
  [ "$(identity_of link "$no_blobs")" = "$before_mutated" ]
}

@test "a binary edit inside a merge rotates; a clean catch-up over one does not; dropping blob ids misses it" {
  catchup_binary branch image.bin one
  catchup_binary branch steady.bin steady
  no_blobs="$(mutate no-blobs '/# frame: blobs$/d')"
  catchup_git diff-tree -p "$(tip)" HEAD -- image.bin | grep -q '^Binary files'

  before_steady="$(identity_of steady.bin)"
  catchup_base_commit U.txt "base one"
  catchup_merge_base
  [ "$(identity_of steady.bin)" = "$before_steady" ]

  before="$(identity_of image.bin)"
  before_mutated="$(identity_of image.bin "$no_blobs")"
  catchup_base_commit U.txt "base two"
  catchup_merge_base --no-commit
  catchup_binary worktree image.bin two
  catchup_commit_merge
  [ "$(identity_of image.bin)" != "$before" ]
  [ "$(identity_of image.bin "$no_blobs")" = "$before_mutated" ]
}

# ---------------------------------------------------------------------------
# Content from other refs, renames and deletions
# ---------------------------------------------------------------------------

@test "a merge from a ref that is not the base, and an octopus, enter the patch; the base's newer lines do not" {
  seed_base X.txt 20
  seed_base Y.txt 20
  catchup_branch_commit B.txt "branch own"
  catchup_side_ref side-one X.txt "$(lines_file x-side 20 3='side change')"
  catchup_side_ref side-two Y.txt "$(lines_file y-side 20 3='second side change')"
  catchup_side_ref side-three Z.txt "third side"
  catchup_base_commit X.txt "$(lines_file x-base 20 18='base newer')"

  catchup_merge_ref side-one
  [ "$(paths_of "$(identities_text)")" = "$(printf 'B.txt\nX.txt')" ]
  run audit_branch_patch_review_input "$CATCHUP_ROOT" "$(tip)" "" HEAD X.txt
  [ "$status" -eq 0 ]
  grep -q '^+side change$' <<<"$output"
  grep -q 'base newer' <<<"$output" && return 1

  catchup_octopus side-two side-three
  [ "$(paths_of "$(identities_text)")" = "$(printf 'B.txt\nX.txt\nY.txt\nZ.txt')" ]
}

@test "the same side-ref content arriving through the base adds nothing to the patch" {
  seed_base X.txt 20
  catchup_branch_commit B.txt "branch own"
  before="$(identities_text)"
  catchup_side_ref side-one X.txt "$(lines_file x-side 20 3='side change')"
  catchup_side_ref side-two Y.txt "second side"
  catchup_merge_into_base side-one
  catchup_merge_into_base side-two
  catchup_merge_base
  [ "$(identities_text)" = "$before" ]
}

@test "a base rename carries the branch edit to the new path and drops the old one" {
  seed_base F.txt 20
  catchup_branch_commit F.txt "$(lines_file f-branch 20 15='branch fifteen')"
  before="$(identities_text)"
  [ "$(paths_of "$before")" = "F.txt" ]

  catchup_rename_on_base F.txt G.txt
  catchup_merge_base
  after="$(identities_text)"
  [ "$(paths_of "$after")" = "G.txt" ]
  [ "$after" != "$before" ]
  run audit_branch_patch_review_input "$CATCHUP_ROOT" "$(tip)" "" HEAD G.txt
  [ "$status" -eq 0 ]
  grep -q '^+branch fifteen$' <<<"$output"
}

@test "a base deletion the branch keeps is an addition-shaped identity; accepting it leaves the patch" {
  seed_base F.txt 20
  catchup_branch_commit F.txt "$(lines_file f-branch 20 15='branch fifteen')"
  catchup_branch_commit K.txt "branch keeps this file in the patch"
  before="$(identity_of F.txt)"
  [ -n "$before" ]
  catchup_delete_on_base F.txt
  anchor="$(catchup_git rev-parse HEAD)"

  catchup_merge_base --no-commit
  catchup_git add F.txt
  catchup_commit_merge
  kept="$(identity_of F.txt)"
  [ -n "$kept" ]
  [ "$kept" != "$before" ]
  run audit_branch_patch_review_input "$CATCHUP_ROOT" "$(tip)" "" HEAD F.txt
  grep -q '^new file mode 100644$' <<<"$output"

  catchup_git reset -q --hard "$anchor"
  catchup_merge_base --no-commit
  catchup_git rm -q F.txt
  catchup_commit_merge
  [ -z "$(identity_of F.txt)" ]
  [ "$(paths_of "$(identities_text)")" = "K.txt" ]
}

# ---------------------------------------------------------------------------
# Return codes
# ---------------------------------------------------------------------------

@test "a base tip absent locally returns 4 and prints nothing" {
  catchup_branch_commit B.txt "branch own"
  absent=1234567890abcdef1234567890abcdef12345678
  run audit_branch_patch_merge_base "$CATCHUP_ROOT" "$absent"
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  run audit_branch_patch_changed_paths "$CATCHUP_ROOT" "$absent" HEAD
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  run audit_branch_patch_review_input "$CATCHUP_ROOT" "$absent" "" HEAD
  [ "$status" -eq 4 ]
  [ -z "$output" ]
  run audit_branch_patch_fork_point "$CATCHUP_ROOT" "$absent"
  [ "$status" -eq 4 ]
  [ -z "$output" ]
}

@test "a criss-cross returns 3 and prints nothing; taking the first merge base would pass it" {
  catchup_criss_cross
  [ "$(catchup_git merge-base --all HEAD "$(tip)" | grep -c .)" -eq 2 ]
  run audit_branch_patch_merge_base "$CATCHUP_ROOT" "$(tip)"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  run audit_branch_patch_changed_paths "$CATCHUP_ROOT" "$(tip)" HEAD
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  run audit_branch_patch_review_input "$CATCHUP_ROOT" "$(tip)" "" HEAD
  [ "$status" -eq 3 ]
  [ -z "$output" ]

  first_line="$(mutate first-merge-base '/return 3 ;;/d')"
  run bash -c '. "$1"; audit_branch_patch_merge_base "$2" "$3"' _ "$first_line" "$CATCHUP_ROOT" "$(tip)"
  [ "$status" -eq 0 ]
  [ "${#output}" -eq 40 ]
}

# ---------------------------------------------------------------------------
# Fork point, changed paths, review input, rebased anchor tree
# ---------------------------------------------------------------------------

@test "the fork point equals the plain merge base before any catch-up and survives clean and conflicted ones" {
  seed_base P.txt 20
  catchup_branch_commit P.txt "$(lines_file p-branch 20 10='branch ten')"
  fork="$(audit_branch_patch_fork_point "$CATCHUP_ROOT" "$(tip)")"
  [ "$fork" = "$(catchup_git merge-base refs/remotes/origin/main HEAD)" ]

  catchup_base_commit U.txt "base one"
  catchup_merge_base
  [ "$(audit_branch_patch_fork_point "$CATCHUP_ROOT" "$(tip)")" = "$fork" ]

  catchup_base_commit P.txt "$(lines_file p-base 20 10='base ten')"
  catchup_merge_base --no-commit
  lines_file p-resolved 20 10='resolved ten' >/dev/null
  cp "$BATS_TEST_TMPDIR/p-resolved" "$CATCHUP_ROOT/P.txt"
  catchup_commit_merge
  [ "$(audit_branch_patch_fork_point "$CATCHUP_ROOT" "$(tip)")" = "$fork" ]
  [ "$(catchup_git merge-base refs/remotes/origin/main HEAD)" != "$fork" ]
}

@test "changed paths since an anchor name only the branch's new work after a catch-up" {
  seed_base P.txt 40
  catchup_branch_commit P.txt "$(lines_file p-branch 40 30='branch thirty')"
  anchor="$(catchup_git rev-parse HEAD)"
  catchup_base_commit P.txt "$(lines_file p-base 40 2='base two')"
  catchup_base_commit U.txt "base only"
  catchup_merge_base
  catchup_branch_commit Q.txt "new branch work"

  audit_branch_patch_changed_paths "$CATCHUP_ROOT" "$(tip)" "$anchor" >"$BATS_TEST_TMPDIR/changed"
  printf 'Q.txt\0' >"$BATS_TEST_TMPDIR/expected"
  cmp "$BATS_TEST_TMPDIR/changed" "$BATS_TEST_TMPDIR/expected"
}

@test "review input carries the branch hunks and the resolution, never base-only hunks or a whole modified file" {
  seed_base P.txt 40
  catchup_branch_commit P.txt "$(lines_file p-branch 40 20='branch twenty')"
  catchup_branch_commit N.txt "$(printf 'new one\nnew two\nnew three')"
  anchor="$(catchup_git rev-parse HEAD)"
  catchup_base_commit P.txt "$(lines_file p-base 40 2='base two' 20='base twenty')"
  catchup_base_commit U.txt "base only"
  catchup_merge_base --no-commit
  lines_file p-resolved 40 2='base two' 20='resolved twenty' >/dev/null
  cp "$BATS_TEST_TMPDIR/p-resolved" "$CATCHUP_ROOT/P.txt"
  catchup_commit_merge
  audit_branch_patch_supports_remerge_diff "$CATCHUP_ROOT" || skip "git lacks --remerge-diff"

  run audit_branch_patch_review_input "$CATCHUP_ROOT" "$(tip)" "$anchor" HEAD
  [ "$status" -eq 0 ]
  grep -q '^+resolved twenty$' <<<"$output"
  grep -q 'branch twenty' <<<"$output"
  grep -q '^remerge CONFLICT' <<<"$output"
  grep -q 'base two' <<<"$output" && return 1
  grep -q '^diff --git a/U.txt' <<<"$output" && return 1
  grep -q 'line 35' <<<"$output" && return 1
  grep -q 'line 5$' <<<"$output" && return 1

  # A path the branch adds appears whole.
  run audit_branch_patch_review_input "$CATCHUP_ROOT" "$(tip)" "" HEAD N.txt
  [ "$status" -eq 0 ]
  grep -q '^new file mode 100644$' <<<"$output"
  grep -q '^+new one$' <<<"$output"
  grep -q '^+new three$' <<<"$output"

  # Without remerge-diff support: the path's full branch-own patch.
  merge_base="$(audit_branch_patch_merge_base "$CATCHUP_ROOT" "$(tip)")"
  expected="$(catchup_git diff-tree -r -p -U3 --full-index --no-renames "$merge_base" HEAD -- P.txt)"
  no_remerge="$(mutate no-remerge 's/^\(audit_branch_patch_supports_remerge_diff() {\)$/\1 return 1;/')"
  run bash -c '. "$1"; audit_branch_patch_review_input "$2" "$3" "$4" HEAD P.txt' _ "$no_remerge" "$CATCHUP_ROOT" "$(tip)" "$anchor"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
  grep -q '^remerge' <<<"$output" && return 1
  real="$(audit_branch_patch_review_input "$CATCHUP_ROOT" "$(tip)" "$anchor" HEAD P.txt)"
  [ "$real" != "$expected" ]
}

@test "the rebased anchor tree differs from HEAD only by the new commit; a conflicting replay fails" {
  seed_base P.txt 40
  catchup_branch_commit P.txt "$(lines_file p-branch 40 30='branch thirty')"
  anchor="$(catchup_git rev-parse HEAD)"
  catchup_base_commit P.txt "$(lines_file p-base 40 2='base two')"
  catchup_base_commit U.txt "base only"
  catchup_merge_base
  catchup_branch_commit Q.txt "new branch work"

  tree="$(audit_branch_patch_rebased_anchor_tree "$CATCHUP_ROOT" "$(tip)" "$anchor")"
  [ "${#tree}" -eq 40 ]
  [ "$(catchup_git diff --name-only "$tree" HEAD)" = "Q.txt" ]

  catchup_branch_commit P.txt "$(lines_file p-again 40 2='base two' 20='branch twenty')"
  anchor="$(catchup_git rev-parse HEAD)"
  catchup_base_commit P.txt "$(lines_file p-conflict 40 2='base two' 20='base twenty')"
  catchup_merge_base --no-commit
  lines_file p-resolved 40 2='base two' 20='resolved twenty' >/dev/null
  cp "$BATS_TEST_TMPDIR/p-resolved" "$CATCHUP_ROOT/P.txt"
  catchup_commit_merge
  run audit_branch_patch_rebased_anchor_tree "$CATCHUP_ROOT" "$(tip)" "$anchor"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "identities accept a bare tree id as the target" {
  catchup_branch_commit B.txt "branch own"
  merge_base="$(audit_branch_patch_merge_base "$CATCHUP_ROOT" "$(tip)")"
  [ "$merge_base" = "$(catchup_git merge-base HEAD "$(tip)")" ]
  tree="$(catchup_git rev-parse 'HEAD^{tree}')"
  [ "$(audit_branch_patch_identities "$CATCHUP_ROOT" "$merge_base" "$tree" | tr '\0' '\n')" = "$(identities_text)" ]
}

@test "an empty branch-own patch is empty output with status 0" {
  merge_base="$(audit_branch_patch_merge_base "$CATCHUP_ROOT" "$(tip)")"
  run audit_branch_patch_identities "$CATCHUP_ROOT" "$merge_base" HEAD
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Hardening: parsing and pinned, config-independent diffs
# ---------------------------------------------------------------------------

@test "typechange, space, non-ASCII and quoted paths each parse to exactly one identity" {
  catchup_base_commit T.txt "regular file"
  catchup_merge_base
  catchup_symlink branch T.txt elsewhere
  catchup_branch_commit "dir/sp ace.txt" "space"
  catchup_branch_commit "café.txt" "non-ASCII"
  catchup_branch_commit 'quo"te.txt' "quote"
  catchup_branch_commit "ta	b.txt" "tab"
  catchup_branch_commit 'back\slash.txt' "backslash"
  catchup_git diff-tree -p HEAD~6 HEAD -- T.txt | grep -c '^diff --git' | grep -qx 2

  merge_base="$(audit_branch_patch_merge_base "$CATCHUP_ROOT" "$(tip)")"
  audit_branch_patch_identities "$CATCHUP_ROOT" "$merge_base" HEAD >"$BATS_TEST_TMPDIR/records"
  count=0
  : >"$BATS_TEST_TMPDIR/paths"
  while IFS= read -r -d '' record; do
    count=$((count + 1))
    [ "${#record}" -gt 65 ]
    printf '%s\0' "${record:65}" >>"$BATS_TEST_TMPDIR/paths"
  done <"$BATS_TEST_TMPDIR/records"
  [ "$count" -eq 6 ]
  printf '%s\0' T.txt 'back\slash.txt' "café.txt" "dir/sp ace.txt" 'quo"te.txt' "ta	b.txt" |
    LC_ALL=C sort -z >"$BATS_TEST_TMPDIR/expected"
  cmp "$BATS_TEST_TMPDIR/paths" "$BATS_TEST_TMPDIR/expected"
}

# upper_driver: a textconv command (git appends the file name) that
# upper-cases its input.
upper_driver() {
  printf 'tr a-z A-Z <"$1"\n' >"$BATS_TEST_TMPDIR/upper.sh"
  printf 'sh %s\n' "$BATS_TEST_TMPDIR/upper.sh"
}

# build_merge_scenario: a branch edit beside a blank context line, an evil
# merge on the branch's own path and a text-converted path, so the pinned
# behaviors have something to change.
build_merge_scenario() {
  catchup_base_commit P.txt "$(lines_file p-seed 40 28=)"
  catchup_merge_base
  seed_base X.sh 20
  catchup_branch_commit P.txt "$(lines_file p-branch 40 28= 30='branch thirty')"
  catchup_branch_commit X.sh "$(lines_file x-branch 20 10='echo branch')"
  catchup_base_commit U.txt "base only"
  catchup_merge_base --no-commit
  lines_file x-evil 20 10='echo branch' 15='echo evil' >/dev/null
  cp "$BATS_TEST_TMPDIR/x-evil" "$CATCHUP_ROOT/X.sh"
  catchup_commit_merge
}

@test "hostile diff configuration and a textconv driver leave the identity set unchanged" {
  catchup_base_commit .gitattributes '*.txt diff=upper'
  catchup_merge_base
  build_merge_scenario
  clean="$(identities_text)"
  [ -n "$clean" ]

  catchup_git config diff.upper.textconv "$(upper_driver)"
  # The fixture is hostile: plain git now shows the converted text.
  catchup_git diff --no-color "$(tip)" HEAD -- P.txt | grep -q 'BRANCH THIRTY'
  catchup_git config diff.external 'sh -c "echo external"'
  catchup_git config diff.noprefix true
  catchup_git config diff.algorithm patience
  catchup_git config color.diff always
  catchup_git config color.ui always
  catchup_git config diff.context 9
  catchup_git config diff.interHunkContext 20
  catchup_git config diff.suppressBlankEmpty true
  catchup_git config diff.indentHeuristic false
  catchup_git config diff.submodule log
  catchup_git config diff.orderFile "$BATS_TEST_TMPDIR/order"
  printf 'X.sh\n' >"$BATS_TEST_TMPDIR/order"
  catchup_git config core.bigFileThreshold 1

  [ "$(identities_text)" = "$clean" ]
}

@test "GIT_CONFIG_COUNT, GIT_CONFIG_PARAMETERS and GIT_EXTERNAL_DIFF leave the identity set unchanged" {
  catchup_base_commit .gitattributes '*.txt diff=upper'
  catchup_merge_base
  build_merge_scenario
  clean="$(identities_text)"

  export GIT_CONFIG_COUNT=3
  GIT_CONFIG_VALUE_0="$(upper_driver)"
  export GIT_CONFIG_KEY_0=diff.upper.textconv GIT_CONFIG_VALUE_0
  export GIT_CONFIG_KEY_1=diff.algorithm GIT_CONFIG_VALUE_1=patience
  export GIT_CONFIG_KEY_2=diff.noprefix GIT_CONFIG_VALUE_2=true
  export GIT_CONFIG_PARAMETERS="'diff.context'='0'"
  # The fixture is hostile: plain git now shows the converted text.
  catchup_git diff --no-color "$(tip)" HEAD -- P.txt | grep -q 'BRANCH THIRTY'
  export GIT_EXTERNAL_DIFF=false GIT_DIFF_OPTS=--unified=0

  [ "$(identities_text)" = "$clean" ]
}

@test "a tracked -diff attribute leaves the identity set equal to a sandbox without it" {
  build_merge_scenario
  clean="$(identities_text)"

  catchup_init "$BATS_TEST_TMPDIR/attributed"
  catchup_base_commit .gitattributes '*.sh -diff'
  catchup_merge_base
  build_merge_scenario
  # The fixture is hostile: plain git hides the evil edit as binary.
  catchup_git diff "$(tip)" HEAD -- X.sh | grep -q '^Binary files'

  [ "$(identities_text)" = "$clean" ]
}

@test "a replace graft changes neither the merge base nor the identity set" {
  seed_base P.txt 40
  catchup_branch_commit P.txt "$(lines_file p-branch 40 30='branch thirty')"
  catchup_branch_commit Q.txt "second branch commit"
  catchup_base_commit U.txt "base only"
  clean_base="$(audit_branch_patch_merge_base "$CATCHUP_ROOT" "$(tip)")"
  clean="$(identities_text)"

  catchup_git replace --graft HEAD~1 "$(tip)"
  # The fixture is hostile: plain git now sees a different merge base.
  [ "$(catchup_git merge-base HEAD "$(tip)")" != "$clean_base" ]

  [ "$(audit_branch_patch_merge_base "$CATCHUP_ROOT" "$(tip)")" = "$clean_base" ]
  [ "$(identities_text)" = "$clean" ]
}

@test "the library computes the same identities under the system bash" {
  build_merge_scenario
  expected="$(identities_text)"
  run /bin/bash -c '. "$1"; merge_base="$(audit_branch_patch_merge_base "$2" "$3")" && audit_branch_patch_identities "$2" "$merge_base" HEAD | tr "\0" "\n"' \
    _ "$LIBRARY" "$CATCHUP_ROOT" "$(tip)"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

# ---------------------------------------------------------------------------
# Scale
# ---------------------------------------------------------------------------

# commit_many <count>: one branch commit adding <count> files.
commit_many() {
  local index=1
  mkdir -p "$CATCHUP_ROOT/many"
  while [ "$index" -le "$1" ]; do
    printf 'file %s\n' "$index" >"$CATCHUP_ROOT/many/file-$index.txt"
    index=$((index + 1))
  done
  catchup_git add -A && catchup_git commit -q -m many
}

@test "a thousand-path patch costs two git processes and one sha256 process" {
  commit_many 1000
  shims="$BATS_TEST_TMPDIR/shims"
  mkdir -p "$shims"
  for tool in git sha256sum shasum; do
    real="$(command -v "$tool")" || continue
    printf '#!/bin/sh\nprintf "%%s\\n" %s >>"%s"\nexec "%s" "$@"\n' "$tool" "$BATS_TEST_TMPDIR/calls" "$real" >"$shims/$tool"
    chmod +x "$shims/$tool"
  done
  merge_base="$(audit_branch_patch_merge_base "$CATCHUP_ROOT" "$(tip)")"
  : >"$BATS_TEST_TMPDIR/calls"
  started="$(date +%s)"
  PATH="$shims:$PATH" audit_branch_patch_identities "$CATCHUP_ROOT" "$merge_base" HEAD >"$BATS_TEST_TMPDIR/records"
  elapsed=$(($(date +%s) - started))

  [ "$(tr -cd '\0' <"$BATS_TEST_TMPDIR/records" | wc -c | tr -d ' ')" -eq 1000 ]
  [ "$(grep -c '^git$' "$BATS_TEST_TMPDIR/calls")" -eq 2 ]
  [ "$(grep -c -E '^(sha256sum|shasum)$' "$BATS_TEST_TMPDIR/calls")" -eq 1 ]
  # Measured at under half a second locally; the margin absorbs a slow runner.
  [ "$elapsed" -le 10 ]
}

@test "a patch wider than the descriptor limit succeeds under ulimit -n 256" {
  commit_many 300
  merge_base="$(audit_branch_patch_merge_base "$CATCHUP_ROOT" "$(tip)")"
  run bash -c 'ulimit -n 256 || exit 2; . "$1"; audit_branch_patch_identities "$2" "$3" HEAD | tr -cd "\0" | wc -c' \
    _ "$LIBRARY" "$CATCHUP_ROOT" "$merge_base"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | tr -d ' ')" = "300" ]
}

# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

@test "a change to this library resets every member's anchor as a global rule" {
  # shellcheck source=.claude/hooks/lib/audit-rules-changed.sh
  . "$REPO_ROOT/.claude/hooks/lib/audit-rules-changed.sh"
  run audit_rules_reset_for code-audit-frontend <<<".claude/hooks/lib/audit-branch-patch.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'global\t.claude/hooks/lib/audit-branch-patch.sh')" ]
}
