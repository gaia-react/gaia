#!/usr/bin/env bats
#
# What a Code Audit Team member is asked to review once the base branch has
# been merged into the branch: the scope helper's CHANGED list and the review
# diff it writes, and the branch-own digests that rotate with them. Every
# fixture is a scratch repository built by .gaia/tests/helpers/catchup-fixture.sh
# with a bare origin, a base branch arriving through refs/remotes/origin/main,
# and a copy of the scope helper and its libraries on the base, so the helper's
# root-confinement check passes and the machinery itself never lands in the
# branch's own patch.
#
# The roster is the shipped one. Paths below are owned by exactly one member:
#   frontend/app/**   code-audit-frontend (the default member)
#   .githooks/**      code-audit-maintainer-shell
# so a change to one is "covered" by that member alone, and the members that
# cover neither path are the ones every digest assertion proves unmoved.
#
# Guards that a comparison alone cannot prove able to fail are re-run against a
# scratch copy of the library with the guard disabled by a sed mutation, and the
# mutated run must reach the outcome the guard exists to prevent.
#
# Run under bash 5: `bash .gaia/scripts/bats5.sh
# .gaia/scripts/tests/audit-blend-scope.bats < /dev/null`.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LIBRARY="$REPO_ROOT/.claude/hooks/lib/audit-branch-patch.sh"
  # shellcheck source=.gaia/tests/helpers/catchup-fixture.sh
  . "$REPO_ROOT/.gaia/tests/helpers/catchup-fixture.sh"
  if ! command -v jq >/dev/null 2>&1; then
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
      echo "jq not present on a CI runner; the scope probes here would report green" >&2
      return 1
    fi
    skip "jq required"
  fi
  FRONTEND=code-audit-frontend
  SHELL_MEMBER=code-audit-maintainer-shell
  catchup_init "$BATS_TEST_TMPDIR/sandbox"
  install_machinery
}

# install_machinery: the scope helper, the resolver and every library they load,
# committed on the base and merged into the branch before any test content, with
# the audit store ignored so a helper run never lands in a commit.
install_machinery() {
  catchup_git checkout -q main
  mkdir -p "$CATCHUP_ROOT/.gaia/scripts" "$CATCHUP_ROOT/.github/audit" \
    "$CATCHUP_ROOT/.claude/hooks/lib"
  cp "$REPO_ROOT/.gaia/scripts/audit-resolve-scope.sh" \
    "$REPO_ROOT/.gaia/scripts/audit-scope-digest.sh" \
    "$REPO_ROOT/.gaia/scripts/audit-key-lib.sh" \
    "$REPO_ROOT/.gaia/scripts/audit-member-digest.sh" \
    "$REPO_ROOT/.gaia/scripts/main-root-lib.sh" \
    "$CATCHUP_ROOT/.gaia/scripts/"
  chmod +x "$CATCHUP_ROOT/.gaia/scripts/audit-resolve-scope.sh" \
    "$CATCHUP_ROOT/.gaia/scripts/audit-scope-digest.sh"
  cp "$REPO_ROOT/.github/audit/resolve-audit-base.sh" "$CATCHUP_ROOT/.github/audit/"
  chmod +x "$CATCHUP_ROOT/.github/audit/resolve-audit-base.sh"
  cp "$REPO_ROOT/.gaia/audit-ci.yml" "$CATCHUP_ROOT/.gaia/"
  cp "$REPO_ROOT/.claude/hooks/lib/audit-scope.sh" \
    "$REPO_ROOT/.claude/hooks/lib/audit-base-provenance.sh" \
    "$REPO_ROOT/.claude/hooks/lib/audit-branch-patch.sh" \
    "$REPO_ROOT/.claude/hooks/lib/audit-rules-changed.sh" \
    "$REPO_ROOT/.claude/hooks/lib/audit-clearance.sh" \
    "$REPO_ROOT/.claude/hooks/lib/audit-digest.sh" \
    "$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh" \
    "$REPO_ROOT/.claude/hooks/lib/gaia-version.sh" \
    "$CATCHUP_ROOT/.claude/hooks/lib/"
  printf '2.0.0\n' >"$CATCHUP_ROOT/.gaia/VERSION"
  printf '.gaia/local/\n' >"$CATCHUP_ROOT/.gitignore"
  catchup_git add -A
  catchup_git commit -q -m "machinery"
  catchup_git push -q origin main 2>/dev/null
  catchup_git fetch -q origin
  catchup_git checkout -q -B "$CATCHUP_BRANCH" main
  _catchup_set_head
}

# lines_file <name> <count> [<line>=<text> | <line>+=<text>...]: a numbered
# text file in the test directory, for the commit helpers.
lines_file() {
  local file="$BATS_TEST_TMPDIR/$1"
  shift
  catchup_lines "$1" line "${@:2}" >"$file"
  printf '%s\n' "$file"
}

# seed_base <path> <count>: a numbered file on the base, merged into the branch
# before the branch's own work starts.
seed_base() {
  catchup_base_commit "$1" "$(lines_file "seed-$RANDOM" "$2")"
  catchup_merge_base
}

# digests [<library>]: every member's branch-own digest at HEAD, one
# `<member>\t<digest>` line each. With a library argument, that library's
# functions replace the shipped ones, which is how a disabled guard is driven.
digests() {
  bash -c '
    . "$1/.claude/hooks/lib/audit-digest.sh"
    if [ -n "$3" ]; then . "$3"; fi
    audit_branch_digests_local "$2"
  ' _ "$REPO_ROOT" "$CATCHUP_ROOT" "${1:-}"
}

# members_that_changed <before> <after>: the members whose digest line is not in
# <before>, sorted, one per line.
members_that_changed() {
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if ! grep -qxF -- "$line" <<<"$1"; then
      printf '%s\n' "${line%%$'\t'*}"
    fi
  done <<<"$2" | sort
}

# value_of <output> <KEY>: the value of the first KEY= line.
value_of() {
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1
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

# mutate_scope_script <sed program>: disable one guard in the sandbox's copy of
# the scope helper; fails when the mutation changed nothing.
mutate_scope_script() {
  local script="$CATCHUP_ROOT/.gaia/scripts/audit-resolve-scope.sh" mutated="$BATS_TEST_TMPDIR/scope-script-mutated.sh"
  sed -e "$1" "$script" >"$mutated"
  if cmp -s "$mutated" "$script"; then
    printf 'scope script mutation changed nothing: %s\n' "$1" >&2
    return 1
  fi
  cp "$mutated" "$script"
  chmod +x "$script"
}

# scope_for <member> <anchor or empty> [<pathspec>...]: run the sandbox's scope
# helper as the member would. SCOPE_OUTPUT holds its stdout, REVIEW_DIFF_FILE
# the review diff it names, and CHANGED_PATHS the CHANGED lines (path per line).
scope_for() {
  local member="$1" anchor="$2" arguments=() pathspec
  shift 2
  arguments=(--member "$member" --root "$CATCHUP_ROOT" --skip-full-base)
  [ -z "$anchor" ] || arguments+=(--base-override "$anchor")
  for pathspec in "$@"; do
    arguments+=(--review-path "$pathspec")
  done
  run --separate-stderr "$CATCHUP_ROOT/.gaia/scripts/audit-resolve-scope.sh" "${arguments[@]}"
  if [ "$status" -ne 0 ]; then
    printf 'scope helper exited %s: %s\n' "$status" "$stderr" >&2
    return 1
  fi
  SCOPE_OUTPUT="$output"
  REVIEW_DIFF_FILE="$(value_of "$output" REVIEW_DIFF)"
  CHANGED_PATHS="$(printf '%s\n' "$output" | sed -n 's/^CHANGED=//p')"
  [ -n "$REVIEW_DIFF_FILE" ] && [ -f "$REVIEW_DIFF_FILE" ] || {
    printf 'no review diff named: %s\n' "$output" >&2
    return 1
  }
}

# diff_has <text>: the review diff carries <text> on some line.
diff_has() {
  grep -qF -- "$1" "$REVIEW_DIFF_FILE"
}

# diff_carries_line <text>: the review diff has a whole line (context, added or
# removed) equal to <text>; diff_has matches a substring.
diff_carries_line() {
  grep -qxF -e " $1" -e "+$1" -e "-$1" "$REVIEW_DIFF_FILE"
}

# supports_remerge: skip the calling test on a git without --remerge-diff.
supports_remerge() {
  bash -c '. "$1"; audit_branch_patch_supports_remerge_diff "$2"' _ "$LIBRARY" "$CATCHUP_ROOT" || skip "this git has no --remerge-diff"
}

# ---------------------------------------------------------------------------
# A conflict resolved by changing the branch's own lines
# ---------------------------------------------------------------------------

@test "a conflict resolved by changing the branch's lines rotates only the covering member and reviews as a diff" {
  supports_remerge
  seed_base frontend/app/p.ts 40
  seed_base .githooks/hook.sh 10
  catchup_branch_commit frontend/app/p.ts "$(lines_file p-branch 40 20='branch twenty')"
  anchor="$CATCHUP_HEAD"
  before="$(digests)"

  catchup_base_commit frontend/app/p.ts "$(lines_file p-base 40 20='base twenty' 35='base thirty-five')"
  catchup_base_commit frontend/app/incoming.ts "incoming from the base"
  catchup_merge_base --no-commit
  [ -n "$(catchup_git diff --name-only --diff-filter=U)" ]
  lines_file p-resolved 40 20='resolved twenty' 35='base thirty-five' >/dev/null
  cp "$BATS_TEST_TMPDIR/p-resolved" "$CATCHUP_ROOT/frontend/app/p.ts"
  catchup_commit_merge

  [ "$(members_that_changed "$before" "$(digests)")" = "$FRONTEND" ]

  scope_for "$FRONTEND" "$anchor" 'frontend/app/*'
  [ "$CHANGED_PATHS" = "frontend/app/p.ts" ]
  diff_has 'resolved twenty'
  diff_has 'branch twenty'
  # The base's non-conflicting hunk, its incoming file, and the far lines of P
  # never reach the reviewer.
  diff_has 'base thirty-five' && return 1
  diff_has 'incoming from the base' && return 1
  diff_carries_line 'line 1' && return 1
  diff_carries_line 'line 40' && return 1
  true
}

@test "a clean catch-up of the base rotates no digest, lists no incoming path and writes an empty review diff" {
  seed_base frontend/app/p.ts 40
  seed_base .githooks/hook.sh 10
  catchup_branch_commit frontend/app/p.ts "$(lines_file p-branch 40 20='branch twenty')"
  anchor="$CATCHUP_HEAD"
  before="$(digests)"

  catchup_base_commit frontend/app/incoming.ts "incoming from the base"
  catchup_base_commit .githooks/hook.sh "$(lines_file hook-base 10 4='base four')"
  catchup_merge_base

  [ -z "$(members_that_changed "$before" "$(digests)")" ]
  scope_for "$FRONTEND" "$anchor" 'frontend/app/*'
  [ -z "$CHANGED_PATHS" ]
  [ ! -s "$REVIEW_DIFF_FILE" ]
}

# ---------------------------------------------------------------------------
# An edit made inside a merge commit
# ---------------------------------------------------------------------------

@test "an evil merge rotates only the member covering the extra edit, and the edit reaches that member's review diff" {
  seed_base frontend/app/p.ts 40
  seed_base .githooks/hook.sh 10
  catchup_branch_commit frontend/app/p.ts "$(lines_file p-branch 40 20='branch twenty')"
  catchup_branch_commit .githooks/hook.sh "$(lines_file hook-branch 10 2='branch two')"
  anchor="$CATCHUP_HEAD"
  before="$(digests)"
  path_only="$(mutate path-only '/# frame: modes$/d; /# frame: hunks$/d; /# frame: blobs$/d')"
  before_path_only="$(digests "$path_only")"

  catchup_base_commit frontend/app/incoming.ts "incoming from the base"
  catchup_merge_base --no-commit
  [ -z "$(catchup_git diff --name-only --diff-filter=U)" ]
  # A path the branch already changed, edited again inside the merge: the base
  # touched nothing there, so no conflict announces it.
  printf 'evil edit\n' >>"$CATCHUP_ROOT/.githooks/hook.sh"
  catchup_commit_merge

  [ "$(members_that_changed "$before" "$(digests)")" = "$SHELL_MEMBER" ]
  scope_for "$SHELL_MEMBER" "$anchor" '.githooks/*'
  [ "$CHANGED_PATHS" = ".githooks/hook.sh" ]
  diff_has '+evil edit'
  # The member covering the branch's own file sees nothing of it.
  scope_for "$FRONTEND" "$anchor" 'frontend/app/*'
  [ -z "$CHANGED_PATHS" ]
  [ ! -s "$REVIEW_DIFF_FILE" ]

  # Disabled: identities framed by path names alone cannot see the edit.
  [ -z "$(members_that_changed "$before_path_only" "$(digests "$path_only")")" ]
}

@test "a resolution that rewrites lines the branch added rotates only the covering member and shows the rewrite" {
  seed_base frontend/app/p.ts 40
  seed_base .githooks/hook.sh 10
  catchup_branch_commit frontend/app/p.ts "$(lines_file p-branch 40 20+='guard alpha' 20+='guard beta')"
  anchor="$CATCHUP_HEAD"
  before="$(digests)"
  path_only="$(mutate path-only '/# frame: modes$/d; /# frame: hunks$/d; /# frame: blobs$/d')"
  before_path_only="$(digests "$path_only")"

  catchup_base_commit frontend/app/p.ts "$(lines_file p-base 40 21='base twenty-one')"
  catchup_merge_base --no-commit
  [ -n "$(catchup_git diff --name-only --diff-filter=U)" ]
  lines_file p-resolved 40 20+='guard alpha rewritten' 21='base twenty-one' >/dev/null
  cp "$BATS_TEST_TMPDIR/p-resolved" "$CATCHUP_ROOT/frontend/app/p.ts"
  catchup_commit_merge

  [ "$(members_that_changed "$before" "$(digests)")" = "$FRONTEND" ]
  scope_for "$FRONTEND" "$anchor" 'frontend/app/*'
  [ "$CHANGED_PATHS" = "frontend/app/p.ts" ]
  diff_has '+guard alpha rewritten'
  scope_for "$SHELL_MEMBER" "$anchor" '.githooks/*'
  [ -z "$CHANGED_PATHS" ]

  [ -z "$(members_that_changed "$before_path_only" "$(digests "$path_only")")" ]
}

@test "a conflict where both sides appended keeps both lines, rotates the covering member and shows the resolution" {
  supports_remerge
  seed_base frontend/app/p.ts 40
  seed_base .githooks/hook.sh 10
  catchup_branch_commit frontend/app/p.ts "$(lines_file p-branch 40 40+='branch tail')"
  anchor="$CATCHUP_HEAD"
  before="$(digests)"
  no_context="$(mutate no-context 's/-U3/-U0/')"
  before_no_context="$(digests "$no_context")"

  catchup_base_commit frontend/app/p.ts "$(lines_file p-base 40 40+='base tail')"
  catchup_merge_base --no-commit
  [ -n "$(catchup_git diff --name-only --diff-filter=U)" ]
  lines_file p-resolved 40 40+='base tail' >/dev/null
  printf 'branch tail\n' >>"$BATS_TEST_TMPDIR/p-resolved"
  cp "$BATS_TEST_TMPDIR/p-resolved" "$CATCHUP_ROOT/frontend/app/p.ts"
  catchup_commit_merge

  [ "$(members_that_changed "$before" "$(digests)")" = "$FRONTEND" ]
  scope_for "$FRONTEND" "$anchor" 'frontend/app/*'
  [ "$CHANGED_PATHS" = "frontend/app/p.ts" ]
  diff_has '+branch tail'
  diff_has ' base tail'

  # Disabled: with no context lines the base's appended line never enters the
  # branch's hunk, so the resolution leaves the digest where it was.
  [ -z "$(members_that_changed "$before_no_context" "$(digests "$no_context")")" ]
}

# ---------------------------------------------------------------------------
# A merge from a ref that is not the base
# ---------------------------------------------------------------------------

@test "merging another branch cut from an older base is the branch's own work, and the base's newer lines stay out" {
  seed_base frontend/app/p.ts 40
  seed_base .githooks/hook.sh 10
  catchup_branch_commit .githooks/hook.sh "$(lines_file hook-branch 10 2='branch two')"
  anchor="$CATCHUP_HEAD"
  before="$(digests)"

  catchup_side_ref side/other frontend/app/p.ts "$(lines_file p-side 40 10='side ten')"
  catchup_base_commit frontend/app/p.ts "$(lines_file p-base 40 30='base thirty')"
  catchup_merge_ref side/other
  catchup_merge_base

  [ "$(members_that_changed "$before" "$(digests)")" = "$FRONTEND" ]
  scope_for "$FRONTEND" "$anchor" 'frontend/app/*'
  [ "$CHANGED_PATHS" = "frontend/app/p.ts" ]
  diff_has '+side ten'
  diff_has 'base thirty' && return 1
  scope_for "$SHELL_MEMBER" "$anchor" '.githooks/*'
  [ -z "$CHANGED_PATHS" ]
}

@test "the same content arriving through the base rotates nothing" {
  seed_base frontend/app/p.ts 40
  seed_base .githooks/hook.sh 10
  catchup_branch_commit .githooks/hook.sh "$(lines_file hook-branch 10 2='branch two')"
  anchor="$CATCHUP_HEAD"
  before="$(digests)"

  catchup_side_ref side/other frontend/app/p.ts "$(lines_file p-side 40 10='side ten')"
  catchup_base_commit frontend/app/p.ts "$(lines_file p-base 40 30='base thirty')"
  catchup_merge_into_base side/other
  catchup_merge_base
  catchup_git show HEAD:frontend/app/p.ts | grep -qx 'side ten'

  [ -z "$(members_that_changed "$before" "$(digests)")" ]
  scope_for "$FRONTEND" "$anchor" 'frontend/app/*'
  [ -z "$CHANGED_PATHS" ]
  [ ! -s "$REVIEW_DIFF_FILE" ]
}

# ---------------------------------------------------------------------------
# A path the base renamed or deleted under the branch's edit
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# A line moved without changing it
# ---------------------------------------------------------------------------

# call_precedes_guard: in the review diff the first `call();` line comes before
# the first added `guard();` line, which is the order after the move.
call_precedes_guard() {
  local call_line guard_line
  call_line="$(grep -n -m1 -xF ' call();' "$REVIEW_DIFF_FILE" | cut -d: -f1)"
  guard_line="$(grep -n -m1 -xF '+guard();' "$REVIEW_DIFF_FILE" | cut -d: -f1)"
  [ -n "$call_line" ] && [ -n "$guard_line" ] && [ "$call_line" -lt "$guard_line" ]
}

@test "a merge resolution that moves a branch-added guard below its call rotates the covering member and shows the move" {
  supports_remerge
  seed_base frontend/app/p.ts 40
  catchup_base_commit frontend/app/p.ts "$(lines_file p-seed 40 20='call();')"
  catchup_merge_base
  seed_base .githooks/hook.sh 10
  catchup_branch_commit frontend/app/p.ts "$(lines_file p-branch 40 20='call();' 19+='guard();')"
  anchor="$CATCHUP_HEAD"
  before="$(digests)"
  no_context="$(mutate no-context 's/-U3/-U0/')"
  before_no_context="$(digests "$no_context")"

  catchup_base_commit frontend/app/p.ts "$(lines_file p-base 40 19='base nineteen' 20='call();')"
  catchup_merge_base --no-commit
  [ -n "$(catchup_git diff --name-only --diff-filter=U)" ]
  lines_file p-resolved 40 19='base nineteen' 20='call();' 20+='guard();' >/dev/null
  cp "$BATS_TEST_TMPDIR/p-resolved" "$CATCHUP_ROOT/frontend/app/p.ts"
  catchup_commit_merge

  [ "$(members_that_changed "$before" "$(digests)")" = "$FRONTEND" ]
  scope_for "$FRONTEND" "$anchor" 'frontend/app/*'
  [ "$CHANGED_PATHS" = "frontend/app/p.ts" ]
  call_precedes_guard
  scope_for "$SHELL_MEMBER" "$anchor" '.githooks/*'
  [ -z "$CHANGED_PATHS" ]

  # Disabled: without context lines the moved guard is the same one-line hunk.
  [ -z "$(members_that_changed "$before_no_context" "$(digests "$no_context")")" ]
}

@test "an ordinary branch commit that moves a guard below its call rotates the covering member and shows the move" {
  seed_base frontend/app/p.ts 40
  catchup_base_commit frontend/app/p.ts "$(lines_file p-seed 40 20='call();')"
  catchup_merge_base
  seed_base .githooks/hook.sh 10
  catchup_branch_commit frontend/app/p.ts "$(lines_file p-branch 40 20='call();' 19+='guard();')"
  anchor="$CATCHUP_HEAD"
  before="$(digests)"
  no_context="$(mutate no-context 's/-U3/-U0/')"
  before_no_context="$(digests "$no_context")"

  catchup_branch_commit frontend/app/p.ts "$(lines_file p-moved 40 20='call();' 20+='guard();')"

  [ "$(members_that_changed "$before" "$(digests)")" = "$FRONTEND" ]
  scope_for "$FRONTEND" "$anchor" 'frontend/app/*'
  [ "$CHANGED_PATHS" = "frontend/app/p.ts" ]
  call_precedes_guard
  scope_for "$SHELL_MEMBER" "$anchor" '.githooks/*'
  [ -z "$CHANGED_PATHS" ]

  [ -z "$(members_that_changed "$before_no_context" "$(digests "$no_context")")" ]
}

@test "a base edit more than three lines from every branch hunk, merged cleanly, rotates nothing" {
  seed_base frontend/app/p.ts 40
  catchup_base_commit frontend/app/p.ts "$(lines_file p-seed 40 20='call();')"
  catchup_merge_base
  seed_base .githooks/hook.sh 10
  catchup_branch_commit frontend/app/p.ts "$(lines_file p-branch 40 20='call();' 19+='guard();')"
  before="$(digests)"

  catchup_base_commit frontend/app/p.ts "$(lines_file p-base 40 20='call();' 35='base thirty-five')"
  catchup_merge_base

  [ -z "$(members_that_changed "$before" "$(digests)")" ]
}

# ---------------------------------------------------------------------------
# What a member is asked to list and read after a catch-up
# ---------------------------------------------------------------------------

@test "after a clean catch-up and one branch commit, CHANGED holds only the paths that commit changed" {
  seed_base frontend/app/p.ts 40
  seed_base .githooks/hook.sh 10
  catchup_branch_commit frontend/app/p.ts "$(lines_file p-branch 40 20='branch twenty')"
  anchor="$CATCHUP_HEAD"

  catchup_base_commit frontend/app/incoming.ts "incoming from the base"
  catchup_base_commit frontend/app/p.ts "$(lines_file p-base 40 35='base thirty-five')"
  catchup_base_commit .githooks/hook.sh "$(lines_file hook-base 10 4='base four')"
  catchup_merge_base
  catchup_branch_commit frontend/app/q.ts "new branch work"

  scope_for "$FRONTEND" "$anchor" 'frontend/app/*'
  [ "$CHANGED_PATHS" = "frontend/app/q.ts" ]
  diff_has '+new branch work'
  scope_for "$FRONTEND" "$anchor"
  [ "$CHANGED_PATHS" = "frontend/app/q.ts" ]
  scope_for "$SHELL_MEMBER" "$anchor" '.githooks/*'
  [ -z "$CHANGED_PATHS" ]
  [ ! -s "$REVIEW_DIFF_FILE" ]

  # Disabled: a helper that ignores the anchor lists the branch's earlier work
  # again, which is the whole-branch re-review this scoping exists to end.
  mutate_scope_script 's/list_anchor="\$anchor_commit"/list_anchor="$BASE_TIP"/'
  scope_for "$FRONTEND" "$anchor" 'frontend/app/*'
  [ "$CHANGED_PATHS" != "frontend/app/q.ts" ]
  printf '%s\n' "$CHANGED_PATHS" | grep -qxF 'frontend/app/p.ts'
}

@test "with no anchor CHANGED is every branch-own path and none the base brought in" {
  seed_base frontend/app/p.ts 40
  seed_base .githooks/hook.sh 10
  catchup_branch_commit frontend/app/p.ts "$(lines_file p-branch 40 20='branch twenty')"
  catchup_base_commit frontend/app/incoming.ts "incoming from the base"
  catchup_merge_base
  catchup_branch_commit frontend/app/q.ts "new branch work"

  scope_for "$FRONTEND" ""
  [ "$(value_of "$SCOPE_OUTPUT" BASE_REF)" = "refs/remotes/origin/main" ]
  [ "$(printf '%s\n' "$CHANGED_PATHS" | tr '\n' ' ')" = "frontend/app/p.ts frontend/app/q.ts " ]
  diff_has '+branch twenty'
  diff_has '+new branch work'
  # A path the branch adds appears whole; a path it edits appears as hunks.
  grep -qxF -- '+new branch work' "$REVIEW_DIFF_FILE"
  diff_carries_line 'line 1' && return 1
  true
}

@test "an empty CHANGED writes an empty review diff and never the whole branch diff" {
  seed_base frontend/app/p.ts 40
  seed_base .githooks/hook.sh 10
  anchor="$CATCHUP_HEAD"
  catchup_branch_commit frontend/app/p.ts "$(lines_file p-branch 40 20='branch twenty')"

  scope_for "$SHELL_MEMBER" "$anchor" '.githooks/*'
  [ -z "$CHANGED_PATHS" ]
  [ ! -s "$REVIEW_DIFF_FILE" ]

  # Disabled: a scratch copy that hands the helper an empty path list asks for
  # every changed path, and the file stops being empty.
  mutated="$BATS_TEST_TMPDIR/resolve-scope-mutated.sh"
  sed -e 's/elif \[ "\${#changed\[@\]}" -eq 0 \]; then/elif false; then/' \
    "$CATCHUP_ROOT/.gaia/scripts/audit-resolve-scope.sh" >"$mutated"
  if cmp -s "$mutated" "$CATCHUP_ROOT/.gaia/scripts/audit-resolve-scope.sh"; then
    echo "mutation changed nothing" >&2
    return 1
  fi
  cp "$mutated" "$CATCHUP_ROOT/.gaia/scripts/audit-resolve-scope.sh"
  scope_for "$SHELL_MEMBER" "$anchor" '.githooks/*'
  [ -s "$REVIEW_DIFF_FILE" ]
  diff_has 'frontend/app/p.ts'
}

@test "without remerge-diff support a blended path's review diff is its full branch-own patch, still a diff" {
  supports_remerge
  seed_base frontend/app/p.ts 40
  catchup_branch_commit frontend/app/p.ts "$(lines_file p-branch 40 20='branch twenty')"
  anchor="$CATCHUP_HEAD"
  catchup_base_commit frontend/app/p.ts "$(lines_file p-base 40 20='base twenty')"
  catchup_merge_base --no-commit
  [ -n "$(catchup_git diff --name-only --diff-filter=U)" ]
  lines_file p-resolved 40 20='resolved twenty' >/dev/null
  cp "$BATS_TEST_TMPDIR/p-resolved" "$CATCHUP_ROOT/frontend/app/p.ts"
  catchup_commit_merge

  scope_for "$FRONTEND" "$anchor" 'frontend/app/*'
  diff_has '<<<<<<<'

  fallback="$(mutate no-remerge 's/^\(audit_branch_patch_supports_remerge_diff() {\)$/\1 return 1;/')"
  cp "$fallback" "$CATCHUP_ROOT/.claude/hooks/lib/audit-branch-patch.sh"
  scope_for "$FRONTEND" "$anchor" 'frontend/app/*'
  diff_has '<<<<<<<' && return 1
  [ "$(grep -c '^diff --git' "$REVIEW_DIFF_FILE")" -eq 1 ]
  diff_has '@@'
  diff_has '+resolved twenty'
}

@test "a rename on the base carries the branch's edit to the new path and only the covering member rotates" {
  seed_base frontend/app/f.ts 40
  seed_base .githooks/hook.sh 10
  catchup_branch_commit frontend/app/f.ts "$(lines_file f-branch 40 20='branch twenty')"
  anchor="$CATCHUP_HEAD"
  before="$(digests)"

  catchup_rename_on_base frontend/app/f.ts frontend/app/g.ts
  catchup_merge_base
  catchup_git show HEAD:frontend/app/g.ts | grep -qx 'branch twenty'

  [ "$(members_that_changed "$before" "$(digests)")" = "$FRONTEND" ]
  scope_for "$FRONTEND" "$anchor" 'frontend/app/*'
  printf '%s\n' "$CHANGED_PATHS" | grep -qxF 'frontend/app/g.ts'
  diff_has 'b/frontend/app/g.ts'
  diff_has '+branch twenty'
  scope_for "$SHELL_MEMBER" "$anchor" '.githooks/*'
  [ -z "$CHANGED_PATHS" ]
}

@test "a rename the branch itself makes lists the old and the new path" {
  seed_base frontend/app/f.ts 40
  seed_base .githooks/hook.sh 10
  catchup_branch_commit .githooks/hook.sh "$(lines_file hook-branch 10 2='branch two')"
  anchor="$CATCHUP_HEAD"
  before="$(digests)"
  catchup_git mv -- frontend/app/f.ts frontend/app/h.ts
  catchup_git commit -q -m "branch: rename f to h"

  [ "$(members_that_changed "$before" "$(digests)")" = "$FRONTEND" ]
  scope_for "$FRONTEND" "$anchor" 'frontend/app/*'
  [ "$(printf '%s\n' "$CHANGED_PATHS" | sort | tr '\n' ' ')" = "frontend/app/f.ts frontend/app/h.ts " ]
  diff_has 'deleted file mode'
  diff_has 'new file mode'
}

@test "a rename made inside a merge commit reaches the reviewer as a deletion and an addition, never as a bare rename record" {
  supports_remerge
  seed_base frontend/app/f.ts 40
  seed_base .githooks/hook.sh 10
  catchup_branch_commit frontend/app/f.ts "$(lines_file f-branch 40 20='branch twenty')"
  anchor="$CATCHUP_HEAD"
  catchup_base_commit frontend/app/incoming.ts "incoming from the base"
  catchup_merge_base --no-commit
  catchup_git mv -- frontend/app/f.ts frontend/app/h.ts
  catchup_commit_merge

  scope_for "$FRONTEND" "$anchor" 'frontend/app/*'
  diff_has 'rename from' && return 1
  diff_has 'rename to' && return 1
  grep -qxF -- '+branch twenty' "$REVIEW_DIFF_FILE"

  # Disabled: a scratch copy of the library that lets git detect renames shows
  # the move in the merge commit as one content-free rename record.
  renames="$(mutate renames 's/ --no-renames//g')"
  cp "$renames" "$CATCHUP_ROOT/.claude/hooks/lib/audit-branch-patch.sh"
  scope_for "$FRONTEND" "$anchor" 'frontend/app/*'
  diff_has 'rename from'
}

@test "a base deletion under the branch's edit, resolved by keeping the file, shows the file as content the branch adds" {
  seed_base frontend/app/f.ts 40
  seed_base .githooks/hook.sh 10
  catchup_branch_commit frontend/app/f.ts "$(lines_file f-branch 40 20='branch twenty')"
  anchor="$CATCHUP_HEAD"
  before="$(digests)"

  catchup_delete_on_base frontend/app/f.ts
  catchup_merge_base --no-commit
  [ -n "$(catchup_git diff --name-only --diff-filter=U)" ]
  catchup_commit_merge
  catchup_git show HEAD:frontend/app/f.ts | grep -qx 'branch twenty'

  [ "$(members_that_changed "$before" "$(digests)")" = "$FRONTEND" ]
  scope_for "$FRONTEND" "$anchor" 'frontend/app/*'
  [ "$CHANGED_PATHS" = "frontend/app/f.ts" ]
  diff_has 'new file mode'
  grep -qxF -- '+line 1' "$REVIEW_DIFF_FILE"
  grep -qxF -- '+branch twenty' "$REVIEW_DIFF_FILE"
}

@test "a base deletion under the branch's edit, resolved by accepting the deletion, still rotates the file's owner" {
  seed_base frontend/app/f.ts 40
  seed_base .githooks/hook.sh 10
  catchup_branch_commit frontend/app/f.ts "$(lines_file f-branch 40 20='branch twenty')"
  anchor="$CATCHUP_HEAD"
  before="$(digests)"

  catchup_delete_on_base frontend/app/f.ts
  catchup_merge_base --no-commit
  [ -n "$(catchup_git diff --name-only --diff-filter=U)" ]
  catchup_git rm -q -- frontend/app/f.ts
  catchup_commit_merge
  [ ! -e "$CATCHUP_ROOT/frontend/app/f.ts" ]

  [ "$(members_that_changed "$before" "$(digests)")" = "$FRONTEND" ]
  scope_for "$FRONTEND" "$anchor" 'frontend/app/*'
  [ "$CHANGED_PATHS" = "frontend/app/f.ts" ]
  scope_for "$SHELL_MEMBER" "$anchor" '.githooks/*'
  [ -z "$CHANGED_PATHS" ]

  # Disabled: a path only the anchor's patch held falls out of a narrowed list
  # when the pathspec is applied to the target's side alone.
  mutate_scope_script 's/for side_commit in HEAD \${anchor_commit:+"\$anchor_commit"}; do/for side_commit in HEAD; do/'
  scope_for "$FRONTEND" "$anchor" 'frontend/app/*'
  [ -z "$CHANGED_PATHS" ]
}
