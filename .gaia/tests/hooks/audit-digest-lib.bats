#!/usr/bin/env bats
# Tests for .claude/hooks/lib/audit-digest.sh, the single per-member
# content-digest derive point, and its CLI entrypoint
# .gaia/scripts/audit-member-digest.sh.
#
# A member's digest is a sha256 over exactly the files that member owns plus the
# shared gate machinery (plus the in-scope-but-ownerless paths for the default
# member), classified by the existing ownership classifier + machinery matcher,
# never by git pathspec. The headline behavior: an out-of-glob-only commit
# leaves every member's digest byte-identical, so its marker re-validates with no
# re-audit. Every degradation resolves fail-closed (empty output, non-zero exit).
#
# Fixtures seed the committed roster (git_init writes its auditors: block) and
# probe a subset of it, deliberately rather than for want of coverage:
# code-audit-frontend (default), code-audit-maintainer-shell and
# code-audit-maintainer-node. The members left out have their ownership routing
# covered in audit-scope-lib.bats and audit-scope-routing-parity.bats, so what
# this suite adds for them would be a second copy of that. Membership is proved
# by ROTATION: a path is
# in member M's digest set iff flipping one byte in it rotates M's digest.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  . "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/tests/helpers/audit-roster.sh"
  . "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/tests/helpers/catchup-fixture.sh"
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  DIGEST_LIBRARY="$REPO_ROOT/.claude/hooks/lib/audit-digest.sh"
  CLI="$REPO_ROOT/.gaia/scripts/audit-member-digest.sh"
  [ -f "$DIGEST_LIBRARY" ] || skip "audit-digest.sh not present"
  # The digest needs a sha256 tool + git; it does NOT need jq.
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    skip "no sha256 tool"
  fi
}

git_init() {
  local repository_directory="$1"
  git -C "$repository_directory" init --quiet --initial-branch=main
  git -C "$repository_directory" config user.email "test@example.com"
  git -C "$repository_directory" config user.name "Test"
  git -C "$repository_directory" config commit.gpgsign false
  seed_audit_roster "$repository_directory"
}

# Seed a fixture repo with an owned file for each probed member, a
# machinery file (in every member's set), a nested rules machinery file, an
# out-of-glob CHANGELOG, and a wiki file (both ownerless + allowlisted).
seed_repo() {
  local repository_directory="$1"
  mkdir -p "$repository_directory/app" "$repository_directory/.gaia/scripts" "$repository_directory/.gaia/cli/src" "$repository_directory/.gaia" \
    "$repository_directory/.claude/rules/foo" "$repository_directory/wiki"
  git_init "$repository_directory"
  echo "export const x = 1;"  > "$repository_directory/app/x.ts"                 # frontend (auditable base)
  echo "#!/usr/bin/env bash"  > "$repository_directory/.gaia/scripts/foo.sh"     # maintainer-shell owned, not machinery
  echo "export const y = 2;"  > "$repository_directory/.gaia/cli/src/index.ts"   # maintainer-node
  printf '1.6.1\n'            > "$repository_directory/.gaia/VERSION"             # machinery (all members)
  echo "rule body"            > "$repository_directory/.claude/rules/foo/bar.md" # machinery (.claude/rules/**), nested
  echo "# changelog"          > "$repository_directory/CHANGELOG.md"             # out-of-glob (ownerless + allowlisted)
  echo "doc"                  > "$repository_directory/wiki/x.md"                # out-of-glob (ownerless + allowlisted)
  git -C "$repository_directory" add -A
  git -C "$repository_directory" commit --quiet -m "seed"
}

# digest_of <root> <member> [<git_reference>] -> 64-hex on stdout, non-zero on fail-closed.
digest_of() {
  local root="$1" member="$2" git_reference="${3:-HEAD}"
  bash -c '. "$1"; audit_member_digest "$2" "$3" "$4"' _ "$DIGEST_LIBRARY" "$root" "$member" "$git_reference"
}

# Commit a one-line mutation to <path> and echo "<pre> <post>" (the shas before
# and after), so a test can compute each member's digest at both.
mutate_commit() {
  local root="$1" path="$2" pre post
  pre="$(git -C "$root" rev-parse HEAD)"
  printf 'mutation-%s\n' "$RANDOM" >> "$root/$path"
  git -C "$root" commit -aqm "mutate $path"
  post="$(git -C "$root" rev-parse HEAD)"
  printf '%s %s' "$pre" "$post"
}

# ---------------------------------------------------------------------------
# The recipe-version sentinel, pinned as a literal.
#
# Editing this string does not rotate a digest the way an ordinary machinery
# edit does. It moves the whole audit key space at once: every clearance
# marker and posted status already in the wild becomes
# unfindable rather than stale, and there is no version field, no migration,
# and no grace window that would let a reader tell the two apart. A typo, a
# reflexive v1 -> v2 bump carried along by an unrelated edit, or a
# search-and-replace that happens to catch the string would do that with the
# whole suite still green, and the damage surfaces later as markers nobody
# can find, with nothing pointing back at the edit.
#
# So the constant gets exactly one intentional edit path: change it and this
# reds, saying what the change costs. The pin is at the hash-input site, not
# anywhere in the file, because that is the occurrence that decides the key
# space -- a lingering mention in this lib's own header comment must not keep
# a moved sentinel looking pinned. The second assertion holds that site
# singular, which is the "single derive point" this suite's header claims:
# a digest computation copied within this lib would give the sentinel a
# second feed that the first assertion alone would never have looked at.
#
# The singularity claim reaches this file and no further. A recipe copied
# into a DIFFERENT file is outside both assertions, deliberately: what may
# derive a digest is the ownership classifier's and the machinery matcher's
# answer, and restating it here would be a second list nobody recounts.
# `grep -oF | wc -l` rather than `grep -cF`, because -c counts matching
# LINES: a duplicate appended to the existing line would read as one site.
# ---------------------------------------------------------------------------

@test "the recipe-version sentinel feeding the digest hash is gaia-audit-digest-v1" {
  grep -qF -- "printf 'gaia-audit-digest-v1\0'" "$DIGEST_LIBRARY" || return 1
  sites="$(grep -oF -- "printf 'gaia-audit-digest-v1\0'" "$DIGEST_LIBRARY" | wc -l | tr -d ' ')"
  [ "$sites" -eq 1 ]
}

# ---------------------------------------------------------------------------
# audit_digests_all: one line per roster member, each a 64-hex digest.
# ---------------------------------------------------------------------------

@test "audit_digests_all emits every roster member with a 64-hex digest" {
  ROOT="$BATS_TEST_TMPDIR/all"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  out="$(bash -c '. "$1"; audit_digests_all "$2"' _ "$DIGEST_LIBRARY" "$ROOT")"
  for member_name in code-audit-frontend code-audit-maintainer-shell code-audit-maintainer-node; do
    line_digest="$(grep -F "$member_name"$'\t' <<<"$out" | cut -f2)"
    [ "${#line_digest}" -eq 64 ] || return 1
    case "$line_digest" in *[!0-9a-f]*) return 1 ;; esac
  done
}

# ---------------------------------------------------------------------------
# UAT-001 / SC1: the flagship out-of-glob no-op. A CHANGELOG-only edit A->B
# touches no path any member owns and no machinery path, so EVERY member's
# digest is byte-identical across A and B.
# ---------------------------------------------------------------------------

@test "UAT-001: a CHANGELOG-only commit leaves every member's digest unchanged" {
  ROOT="$BATS_TEST_TMPDIR/uat001"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  refs="$(mutate_commit "$ROOT" "CHANGELOG.md")"
  commit_sha_before="${refs% *}"
  commit_sha_after="${refs#* }"
  for member_name in code-audit-frontend code-audit-maintainer-shell code-audit-maintainer-node; do
    digest_before="$(digest_of "$ROOT" "$member_name" "$commit_sha_before")"
    digest_after="$(digest_of "$ROOT" "$member_name" "$commit_sha_after")"
    [ -n "$digest_before" ] || return 1
    [ "$digest_before" = "$digest_after" ] || return 1
  done
}

# ---------------------------------------------------------------------------
# UAT-006: the real fail-open direction. Flipping a byte in an owned path
# rotates that member's digest (so the owned path IS in the input set); an
# unrelated member's digest is unchanged; an out-of-set edit rotates nothing.
# ---------------------------------------------------------------------------

@test "UAT-006: a specialist-owned (node) byte flip rotates only that member's digest" {
  ROOT="$BATS_TEST_TMPDIR/uat006node"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  refs="$(mutate_commit "$ROOT" ".gaia/cli/src/index.ts")"
  commit_sha_before="${refs% *}"; commit_sha_after="${refs#* }"
  [ "$(digest_of "$ROOT" code-audit-maintainer-node "$commit_sha_before")" != "$(digest_of "$ROOT" code-audit-maintainer-node "$commit_sha_after")" ] || return 1
  [ "$(digest_of "$ROOT" code-audit-frontend "$commit_sha_before")" = "$(digest_of "$ROOT" code-audit-frontend "$commit_sha_after")" ] || return 1
  [ "$(digest_of "$ROOT" code-audit-maintainer-shell "$commit_sha_before")" = "$(digest_of "$ROOT" code-audit-maintainer-shell "$commit_sha_after")" ] || return 1
}

@test "UAT-006: a default-member auditable-base (app) byte flip rotates only the frontend digest" {
  ROOT="$BATS_TEST_TMPDIR/uat006app"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  refs="$(mutate_commit "$ROOT" "app/x.ts")"
  commit_sha_before="${refs% *}"; commit_sha_after="${refs#* }"
  [ "$(digest_of "$ROOT" code-audit-frontend "$commit_sha_before")" != "$(digest_of "$ROOT" code-audit-frontend "$commit_sha_after")" ] || return 1
  [ "$(digest_of "$ROOT" code-audit-maintainer-node "$commit_sha_before")" = "$(digest_of "$ROOT" code-audit-maintainer-node "$commit_sha_after")" ] || return 1
  [ "$(digest_of "$ROOT" code-audit-maintainer-shell "$commit_sha_before")" = "$(digest_of "$ROOT" code-audit-maintainer-shell "$commit_sha_after")" ] || return 1
}

@test "UAT-006: a machinery (.gaia/VERSION) byte flip rotates every member's digest" {
  ROOT="$BATS_TEST_TMPDIR/uat006mach"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  refs="$(mutate_commit "$ROOT" ".gaia/VERSION")"
  commit_sha_before="${refs% *}"; commit_sha_after="${refs#* }"
  for member_name in code-audit-frontend code-audit-maintainer-shell code-audit-maintainer-node; do
    [ "$(digest_of "$ROOT" "$member_name" "$commit_sha_before")" != "$(digest_of "$ROOT" "$member_name" "$commit_sha_after")" ] || return 1
  done
}

@test "UAT-006: an out-of-set (wiki) edit rotates no member's digest" {
  ROOT="$BATS_TEST_TMPDIR/uat006wiki"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  refs="$(mutate_commit "$ROOT" "wiki/x.md")"
  commit_sha_before="${refs% *}"; commit_sha_after="${refs#* }"
  for member_name in code-audit-frontend code-audit-maintainer-shell code-audit-maintainer-node; do
    [ "$(digest_of "$ROOT" "$member_name" "$commit_sha_before")" = "$(digest_of "$ROOT" "$member_name" "$commit_sha_after")" ] || return 1
  done
}

# ---------------------------------------------------------------------------
# UAT-009: membership is the classifier's, matching dispatch, for a nested
# .claude/rules/ path (machinery via .claude/rules/**), an app/ path (default
# member's auditable base), and a .gaia/cli/src/ path (specialist ERE), never
# git pathspec.
# ---------------------------------------------------------------------------

@test "UAT-009: nested .claude/rules/foo/bar.md is machinery (rotates every member)" {
  ROOT="$BATS_TEST_TMPDIR/uat009rules"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  refs="$(mutate_commit "$ROOT" ".claude/rules/foo/bar.md")"
  commit_sha_before="${refs% *}"; commit_sha_after="${refs#* }"
  for member_name in code-audit-frontend code-audit-maintainer-shell code-audit-maintainer-node; do
    [ "$(digest_of "$ROOT" "$member_name" "$commit_sha_before")" != "$(digest_of "$ROOT" "$member_name" "$commit_sha_after")" ] || return 1
  done
}

@test "UAT-009: app/x.ts lands only in the frontend digest; .gaia/cli/src only in node" {
  ROOT="$BATS_TEST_TMPDIR/uat009own"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  # app path: frontend only.
  refs="$(mutate_commit "$ROOT" "app/x.ts")"
  commit_sha_before="${refs% *}"; commit_sha_after="${refs#* }"
  [ "$(digest_of "$ROOT" code-audit-frontend "$commit_sha_before")" != "$(digest_of "$ROOT" code-audit-frontend "$commit_sha_after")" ] || return 1
  [ "$(digest_of "$ROOT" code-audit-maintainer-node "$commit_sha_before")" = "$(digest_of "$ROOT" code-audit-maintainer-node "$commit_sha_after")" ] || return 1
  # cli path: node only.
  refs="$(mutate_commit "$ROOT" ".gaia/cli/src/index.ts")"
  commit_sha_before="${refs% *}"; commit_sha_after="${refs#* }"
  [ "$(digest_of "$ROOT" code-audit-maintainer-node "$commit_sha_before")" != "$(digest_of "$ROOT" code-audit-maintainer-node "$commit_sha_after")" ] || return 1
  [ "$(digest_of "$ROOT" code-audit-frontend "$commit_sha_before")" = "$(digest_of "$ROOT" code-audit-frontend "$commit_sha_after")" ] || return 1
}

# ---------------------------------------------------------------------------
# Determinism: the frontend digest folds the in-scope-but-ownerless set, so a
# root Makefile change rotates it while a wiki file (allowlisted) does not.
#
# The witness must be a root file that is in scope AND that no member's globs
# claim, or this test rotates the digest through the ordinary owned-glob branch
# and asserts nothing about the fold. A root `Makefile` is that file: it appears
# in no roster glob, and no arm of the out-of-scope allowlist admits it.
# `Dockerfile`, `.npmrc`, `.nvmrc`, `.prettierignore` and the rest of the root
# tooling fail that bar: the default member's globs claim them, which leaves the
# guard hollow enough that deleting the fold outright would still green this
# suite.
# ---------------------------------------------------------------------------

@test "determinism: an in-scope-but-ownerless root Makefile rotates the frontend digest; a wiki file does not" {
  ROOT="$BATS_TEST_TMPDIR/ownerless"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  echo "all:" > "$ROOT/Makefile"
  git -C "$ROOT" add Makefile
  git -C "$ROOT" commit --quiet -m "add Makefile"

  # A Makefile edit rotates the frontend digest (folded in).
  refs="$(mutate_commit "$ROOT" "Makefile")"
  commit_sha_before="${refs% *}"; commit_sha_after="${refs#* }"
  [ "$(digest_of "$ROOT" code-audit-frontend "$commit_sha_before")" != "$(digest_of "$ROOT" code-audit-frontend "$commit_sha_after")" ] || return 1

  # A wiki edit does not.
  refs="$(mutate_commit "$ROOT" "wiki/x.md")"
  commit_sha_before="${refs% *}"; commit_sha_after="${refs#* }"
  [ "$(digest_of "$ROOT" code-audit-frontend "$commit_sha_before")" = "$(digest_of "$ROOT" code-audit-frontend "$commit_sha_after")" ] || return 1
}

# ---------------------------------------------------------------------------
# UAT-012: path-name framing (scoped per CG-001). A space in a path is the
# BINDING assertion: two owned sets identical except one path embeds a space
# yield different digests, and a recompute of the same content agrees. The
# embedded-newline case is a documented known limitation (the reused classifiers
# read newline-delimited stdin), asserted as fail-closed rather than fixed.
# ---------------------------------------------------------------------------

@test "UAT-012: a space in an owned path changes the digest, and a recompute agrees" {
  R1="$BATS_TEST_TMPDIR/nospace"
  R2="$BATS_TEST_TMPDIR/space"
  mkdir -p "$R1/app" "$R2/app"
  git_init "$R1"
  git_init "$R2"
  # Identical content, path differs only by a space.
  echo "export const z = 3;" > "$R1/app/normal.ts"
  echo "export const z = 3;" > "$R2/app/with space.ts"
  git -C "$R1" add -A && git -C "$R1" commit --quiet -m "seed"
  git -C "$R2" add -A && git -C "$R2" commit --quiet -m "seed"

  d1="$(digest_of "$R1" code-audit-frontend)"
  d2="$(digest_of "$R2" code-audit-frontend)"
  [ "${#d1}" -eq 64 ] || return 1
  [ "${#d2}" -eq 64 ] || return 1
  [ "$d1" != "$d2" ] || return 1
  # Recompute of the space-path repo agrees (determinism under a space).
  [ "$d2" = "$(digest_of "$R2" code-audit-frontend)" ] || return 1
}

@test "UAT-012: an embedded-newline path is a documented known limitation (fail-closed, not a wrong digest)" {
  # The membership classifiers read newline-delimited stdin, so a path whose
  # name embeds a literal newline is mis-split during selection. The engine
  # detects the resulting count mismatch and fails closed (empty, non-zero)
  # rather than hashing a mis-aligned set -- safe, never a wrong digest. This
  # is out of scope to "fix" (it would mean changing the classifier semantics).
  NEWLINE_REPOSITORY="$BATS_TEST_TMPDIR/newline"
  mkdir -p "$NEWLINE_REPOSITORY/app"
  git_init "$NEWLINE_REPOSITORY"
  printf 'export const z = 3;\n' > "$NEWLINE_REPOSITORY/app/x.ts"
  # A tracked path literally containing a newline byte.
  bad="$(printf 'app/we\nird.ts')"
  printf 'export const w = 4;\n' > "$NEWLINE_REPOSITORY/$bad"
  git -C "$NEWLINE_REPOSITORY" add -A
  git -C "$NEWLINE_REPOSITORY" commit --quiet -m "seed with newline path"

  run bash -c '. "$1"; audit_member_digest "$2" code-audit-frontend' _ "$DIGEST_LIBRARY" "$NEWLINE_REPOSITORY"
  # Either it fails closed (preferred) -- never a bare/partial digest match.
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# UAT-013: fail-closed. A masked sha256 tool, a failing git ls-tree, or a
# non-git root each emit NOTHING and exit non-zero -- never a partial/empty
# digest that could key or match a marker.
# ---------------------------------------------------------------------------

@test "UAT-013: sha256 tool masked -> emit nothing, exit non-zero" {
  ROOT="$BATS_TEST_TMPDIR/uat013mask"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  run bash -c '
    sha256sum() { return 1; }
    shasum() { return 1; }
    . "$1"
    audit_member_digest "$2" code-audit-frontend
  ' _ "$DIGEST_LIBRARY" "$ROOT"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "UAT-013: a failing git ls-tree (invalid ref) -> emit nothing, exit non-zero" {
  ROOT="$BATS_TEST_TMPDIR/uat013ref"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  run bash -c '. "$1"; audit_member_digest "$2" code-audit-frontend "no-such-ref"' _ "$DIGEST_LIBRARY" "$ROOT"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "UAT-013: a non-git root -> emit nothing, exit non-zero" {
  ROOT="$BATS_TEST_TMPDIR/uat013nogit"
  mkdir -p "$ROOT"
  # Seeded so the failure under test is the missing repository, not the
  # missing roster.
  seed_audit_roster "$ROOT"
  run bash -c '. "$1"; audit_member_digest "$2" code-audit-frontend' _ "$DIGEST_LIBRARY" "$ROOT"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# The CLI entrypoint mirrors the lib: a 64-hex digest + exit 0, and a non-zero
# exit on any fail-closed condition (never swallowed into 0). Usage errors exit 2.
# ---------------------------------------------------------------------------

@test "CLI: prints the member's branch-own digest line the lib computes, exit 0" {
  v2_seed "$BATS_TEST_TMPDIR/cli" || return 1
  catchup_branch_commit frontend/app/x.ts "$(catchup_lines 40 x 5=edited)" || return 1
  run bash "$CLI" --root "$CATCHUP_ROOT" --member "$FRONTEND_MEMBER"
  [ "$status" -eq 0 ]
  [ "${#output}" -eq 64 ]
  [ "$output" = "$(v2_local | awk -F'\t' -v member="$FRONTEND_MEMBER" '$1 == member { print $2 }')" ] || return 1
}

@test "CLI: missing --root or --member exits 2" {
  run bash "$CLI" --member code-audit-frontend
  [ "$status" -eq 2 ]
  ROOT="$BATS_TEST_TMPDIR/cli2"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  run bash "$CLI" --root "$ROOT"
  [ "$status" -eq 2 ]
}

@test "CLI: a fail-closed digest exits non-zero with empty stdout (never swallowed)" {
  v2_seed "$BATS_TEST_TMPDIR/cli3" || return 1
  run bash "$CLI" --root "$CATCHUP_ROOT" --member "$FRONTEND_MEMBER"
  [ "$status" -eq 0 ]
  run bash -c 'bash "$1" --root "$2" --member "$3" --ref no-such-ref 2>/dev/null' _ "$CLI" "$CATCHUP_ROOT" "$FRONTEND_MEMBER"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# ===========================================================================
# The branch-own digest (recipe `gaia-audit-digest-v2`).
#
# Each fixture is a sandbox with a bare origin, the committed roster, and a
# copy of the libraries under test committed on the base, so the digest runs
# from the checkout it measures and a base commit can edit the roster, the
# machinery list or the out-of-scope allowlist. Members in the roster: the
# default member (frontend), a workflow specialist, a shell specialist and a
# node specialist; the workflow specialist covers none of the changed paths in
# most fixtures, so a "no other member rotates" assertion can fail.
# ===========================================================================

FRONTEND_MEMBER=code-audit-frontend
WORKFLOWS_MEMBER=code-audit-github-workflows
SHELL_MEMBER=code-audit-maintainer-shell
NODE_MEMBER=code-audit-maintainer-node

# v2_copy_libraries <root>: the libraries the branch-own digest loads, at the
# relative paths audit-digest.sh finds them from its own location.
v2_copy_libraries() {
  local destination="$1" library
  mkdir -p "$destination/.claude/hooks/lib" "$destination/.gaia/scripts" || return 1
  for library in audit-digest.sh audit-scope.sh audit-machinery.sh audit-branch-patch.sh audit-base-provenance.sh; do
    cp "$REPO_ROOT/.claude/hooks/lib/$library" "$destination/.claude/hooks/lib/$library" || return 1
  done
  cp "$REPO_ROOT/.gaia/scripts/audit-key-lib.sh" "$destination/.gaia/scripts/audit-key-lib.sh"
}

# v2_replace_literal <file> <from> <to>: replace the first occurrence of the
# literal <from>; fails when it is absent, so a mutation that no longer matches
# the code is a red setup and never a silently unmutated copy. <to> must not
# contain an ampersand: bash 5.2 expands it to the matched text.
v2_replace_literal() {
  local file="$1" from="$2" to="$3" content
  content="$(cat "$file"; printf x)"
  content="${content%x}"
  case "$content" in
    *"$from"*) ;;
    *) return 1 ;;
  esac
  printf '%s' "${content/"$from"/$to}" >"$file"
}

# v2_use_mutant <library file name> <from> <to>: point the digest at a scratch
# copy of the libraries whose <library file name> has <from> replaced.
v2_use_mutant() {
  V2_LIBRARY_ROOT="$BATS_TEST_TMPDIR/mutant-$1"
  v2_copy_libraries "$V2_LIBRARY_ROOT" || return 1
  v2_replace_literal "$V2_LIBRARY_ROOT/.claude/hooks/lib/$1" "$2" "$3"
}

# v2_seed <directory>: a sandbox whose base carries one file per ownership
# class and whose feature branch sits at the base tip.
v2_seed() {
  local directory="$1"
  catchup_init "$directory" || return 1
  v2_copy_libraries "$CATCHUP_ROOT" || return 1
  seed_audit_roster "$CATCHUP_ROOT" || return 1
  mkdir -p "$CATCHUP_ROOT/frontend/app" "$CATCHUP_ROOT/.gaia/scripts" "$CATCHUP_ROOT/.gaia/cli/src" \
    "$CATCHUP_ROOT/.github/workflows" "$CATCHUP_ROOT/docs" "$CATCHUP_ROOT/.claude/rules" || return 1
  catchup_lines 40 x >"$CATCHUP_ROOT/frontend/app/x.ts"
  catchup_lines 10 unrelated >"$CATCHUP_ROOT/frontend/app/unrelated.ts"
  catchup_lines 10 shell >"$CATCHUP_ROOT/.gaia/scripts/foo.sh"
  catchup_lines 10 clearance >"$CATCHUP_ROOT/.gaia/scripts/audit-write-clearance.sh"
  catchup_lines 10 index >"$CATCHUP_ROOT/.gaia/cli/src/index.ts"
  catchup_lines 10 other >"$CATCHUP_ROOT/.gaia/cli/src/other.ts"
  catchup_lines 10 workflow >"$CATCHUP_ROOT/.github/workflows/ci.yml"
  catchup_lines 10 notes >"$CATCHUP_ROOT/docs/notes.md"
  catchup_lines 10 gate >"$CATCHUP_ROOT/.claude/rules/quality-gate.md"
  catchup_git add -A && catchup_git commit -q -m "seed sandbox" || return 1
  catchup_git push -q origin HEAD:refs/heads/main 2>/dev/null || return 1
  catchup_git fetch -q origin
}

# v2_local [<tree-ish>]: the branch-own digests against the local base.
v2_local() {
  bash -c '. "$1/.claude/hooks/lib/audit-digest.sh"; audit_branch_digests_local "$2" "$3"' \
    _ "${V2_LIBRARY_ROOT:-$CATCHUP_ROOT}" "$CATCHUP_ROOT" "${1:-HEAD}"
}

# v2_all <merge-base> [<tree-ish>]: the branch-own digests over a merge base.
v2_all() {
  bash -c '. "$1/.claude/hooks/lib/audit-digest.sh"; audit_branch_digests_all "$2" "$3" "$4"' \
    _ "${V2_LIBRARY_ROOT:-$CATCHUP_ROOT}" "$CATCHUP_ROOT" "$1" "${2:-HEAD}"
}

# v2_members <digest lines>: the member names, one per line.
v2_members() {
  printf '%s\n' "$1" | cut -f1
}

# v2_rotated <before> <after>: the members whose digest line differs.
v2_rotated() {
  local before="$1" after="$2" line
  while IFS= read -r line; do
    grep -qxF -- "$line" <<<"$after" || printf '%s\n' "${line%%$'\t'*}"
  done <<<"$before"
}

# v2_expect_rotated <before> <after> [<member>...]: exactly those members
# rotated, over the same roster, and the roster is the one the fixtures assume.
v2_expect_rotated() {
  local before="$1" after="$2" actual expected member_name
  shift 2
  [ "$(v2_members "$before")" = "$(v2_members "$after")" ] || return 1
  for member_name in "$FRONTEND_MEMBER" "$WORKFLOWS_MEMBER" "$SHELL_MEMBER" "$NODE_MEMBER"; do
    v2_members "$before" | grep -qxF -- "$member_name" || return 1
  done
  actual="$(v2_rotated "$before" "$after" | sort)"
  expected=""
  if [ "$#" -gt 0 ]; then
    expected="$(printf '%s\n' "$@" | sort)"
  fi
  if [ "$actual" != "$expected" ]; then
    printf 'rotated: [%s]\nexpected: [%s]\n' "$actual" "$expected" >&2
    return 1
  fi
}

# v2_expect_rotated_all_but <before> <after> [<member>...]: every roster
# member rotated except the named ones, which held.
v2_expect_rotated_all_but() {
  local before="$1" after="$2" member_name excluded skip rotating=()
  shift 2
  while IFS= read -r member_name; do
    skip=0
    for excluded in "$@"; do
      [ "$member_name" = "$excluded" ] && skip=1
    done
    [ "$skip" = 1 ] || rotating[${#rotating[@]}]="$member_name"
  done <<<"$(v2_members "$before")"
  [ "${#rotating[@]}" -gt 0 ] || return 1
  v2_expect_rotated "$before" "$after" "${rotating[@]}"
}

# The branch's own edits to files of every class but the base never touches.
v2_branch_work() {
  catchup_branch_commit frontend/app/x.ts "$(catchup_lines 40 x 5=branch-edit)" || return 1
  catchup_branch_commit .gaia/scripts/foo.sh "$(catchup_lines 10 shell 3=branch-edit)" || return 1
  catchup_branch_commit .gaia/cli/src/index.ts "$(catchup_lines 10 index 2=branch-edit)" || return 1
  catchup_branch_commit .github/workflows/ci.yml "$(catchup_lines 10 workflow 2=branch-edit)" || return 1
}

@test "the branch-own recipe sentinel feeding the digest hash is gaia-audit-digest-v2, at one site" {
  grep -qF -- "printf 'gaia-audit-digest-v2\0" "$DIGEST_LIBRARY" || return 1
  sites="$(grep -oF -- "printf 'gaia-audit-digest-v2\0" "$DIGEST_LIBRARY" | wc -l | tr -d ' ')"
  [ "$sites" -eq 1 ]
}

@test "branch-own: every roster member gets one 64-hex line and the single-member form agrees" {
  v2_seed "$BATS_TEST_TMPDIR/shape" || return 1
  v2_branch_work || return 1
  all="$(v2_local)"
  [ "$(v2_members "$all" | sort -u | wc -l | tr -d ' ')" -ge 4 ] || return 1
  while IFS= read -r line; do
    digest="${line#*$'\t'}"
    [ "${#digest}" -eq 64 ] || return 1
    case "$digest" in *[!0-9a-f]*) return 1 ;; esac
  done <<<"$all"
  merge_base="$(catchup_git merge-base refs/remotes/origin/main HEAD)"
  [ "$(v2_all "$merge_base")" = "$all" ] || return 1
  single="$(bash -c '. "$1/.claude/hooks/lib/audit-digest.sh"; audit_branch_member_digest "$2" "$3" "$4"' \
    _ "$CATCHUP_ROOT" "$CATCHUP_ROOT" "$SHELL_MEMBER" "$merge_base")"
  [ "$single" = "$(grep -F "$SHELL_MEMBER"$'\t' <<<"$all" | cut -f2)" ] || return 1
  true
}

# ---------------------------------------------------------------------------
# A clean catch-up merge of the base moves no member's digest.
# ---------------------------------------------------------------------------

@test "a clean catch-up merge leaves every member's branch-own digest byte-identical" {
  v2_seed "$BATS_TEST_TMPDIR/clean" || return 1
  v2_branch_work || return 1
  merge_base_before="$(catchup_git merge-base refs/remotes/origin/main HEAD)"
  before="$(v2_all "$merge_base_before")"
  [ -n "$before" ] || return 1
  content_before="$(bash -c '. "$1/.claude/hooks/lib/audit-digest.sh"; audit_digests_all "$2"' _ "$CATCHUP_ROOT" "$CATCHUP_ROOT")"
  catchup_base_commit frontend/app/x.ts "$(catchup_lines 40 x 40=base-edit)" || return 1
  catchup_base_commit .gaia/cli/src/other.ts "$(catchup_lines 10 other 6=base-edit)" || return 1
  catchup_base_commit .gaia/scripts/audit-write-clearance.sh "$(catchup_lines 10 clearance 6=base-edit)" || return 1
  catchup_merge_base || return 1
  merge_base_after="$(catchup_git merge-base refs/remotes/origin/main HEAD)"
  [ "$merge_base_after" != "$merge_base_before" ] || return 1
  after="$(v2_all "$merge_base_after")"
  [ "$after" = "$before" ] || return 1
  [ "$(v2_local)" = "$before" ] || return 1
  # The fixture does exercise what the content digest could not: the same
  # catch-up rotated it.
  content_after="$(bash -c '. "$1/.claude/hooks/lib/audit-digest.sh"; audit_digests_all "$2"' _ "$CATCHUP_ROOT" "$CATCHUP_ROOT")"
  [ "$content_after" != "$content_before" ] || return 1
  true
}

# ---------------------------------------------------------------------------
# An edit made inside a merge commit to a path the branch changed rotates the
# members covering that path and no other, for each kind of change an
# identity must see; each is paired with a clean catch-up over a branch that
# already changed that kind of path.
# ---------------------------------------------------------------------------

# v2_inside_merge_run <directory> <whitespace|mode|symlink|binary> <edit|clean>:
# sets V2_BEFORE and V2_AFTER around a catch-up merge, the merge carrying the
# kind's edit to the branch's path when the mode is edit.
v2_inside_merge_run() {
  local directory="$1" kind="$2" mode="$3"
  v2_seed "$directory" || return 1
  case "$kind" in
    whitespace | mode) catchup_branch_commit frontend/app/x.ts "$(catchup_lines 40 x 5=branch-edit)" || return 1 ;;
    symlink) catchup_symlink branch frontend/app/link.ts target-a || return 1 ;;
    binary) catchup_binary branch frontend/app/blob.bin one || return 1 ;;
  esac
  V2_BEFORE="$(v2_local)" || return 1
  catchup_base_commit docs/base-note.md "base note" || return 1
  catchup_merge_base --no-commit || return 1
  if [ "$mode" = edit ]; then
    case "$kind" in
      whitespace)
        catchup_lines 40 x 5=branch-edit '30=x 30 ' >"$CATCHUP_ROOT/frontend/app/x.ts" || return 1
        catchup_git add -- frontend/app/x.ts || return 1
        ;;
      mode) catchup_mode worktree frontend/app/x.ts +x || return 1 ;;
      symlink) catchup_symlink worktree frontend/app/link.ts target-b || return 1 ;;
      binary) catchup_binary worktree frontend/app/blob.bin two || return 1 ;;
    esac
  fi
  catchup_commit_merge || return 1
  V2_AFTER="$(v2_local)"
}

@test "an edit inside a merge commit rotates exactly the covering members, for whitespace, mode, symlink and binary" {
  for kind in whitespace mode symlink binary; do
    v2_inside_merge_run "$BATS_TEST_TMPDIR/inside-$kind-edit" "$kind" edit || return 1
    v2_expect_rotated "$V2_BEFORE" "$V2_AFTER" "$FRONTEND_MEMBER" || return 1
    v2_inside_merge_run "$BATS_TEST_TMPDIR/inside-$kind-clean" "$kind" clean || return 1
    [ "$V2_BEFORE" = "$V2_AFTER" ] || return 1
  done
}

@test "a whitespace-only edit inside a merge stops rotating when the patch ignores whitespace" {
  v2_use_mutant audit-branch-patch.sh "-U3 --no-color" "-U3 -w --no-color" || return 1
  v2_inside_merge_run "$BATS_TEST_TMPDIR/inside-whitespace-mutant" whitespace edit || return 1
  v2_expect_rotated "$V2_BEFORE" "$V2_AFTER"
}

@test "a file-mode edit inside a merge stops rotating when the identity drops the mode frame" {
  v2_use_mutant audit-branch-patch.sh 'print "mode " old_mode[current] " " new_mode[current] > frame_file' 'x = 0' || return 1
  v2_inside_merge_run "$BATS_TEST_TMPDIR/inside-mode-mutant" mode edit || return 1
  v2_expect_rotated "$V2_BEFORE" "$V2_AFTER"
}

@test "a symlink-target edit inside a merge stops rotating when the identity drops blob ids" {
  v2_use_mutant audit-branch-patch.sh 'print "blob " old_blob[current] " " new_blob[current] > frame_file' 'x = 0' || return 1
  v2_inside_merge_run "$BATS_TEST_TMPDIR/inside-symlink-mutant" symlink edit || return 1
  v2_expect_rotated "$V2_BEFORE" "$V2_AFTER"
}

@test "a binary edit inside a merge stops rotating when the identity drops blob ids" {
  v2_use_mutant audit-branch-patch.sh 'print "blob " old_blob[current] " " new_blob[current] > frame_file' 'x = 0' || return 1
  v2_inside_merge_run "$BATS_TEST_TMPDIR/inside-binary-mutant" binary edit || return 1
  v2_expect_rotated "$V2_BEFORE" "$V2_AFTER"
}

# ---------------------------------------------------------------------------
# A marker earned on one branch never validates another.
# ---------------------------------------------------------------------------

# v2_twin_run <directory> <with-changes|empty>: sets V2_BEFORE and V2_AFTER to
# the digests of two branches cut from the same base with the same patch.
v2_twin_run() {
  local directory="$1" patch="$2"
  v2_seed "$directory" || return 1
  if [ "$patch" = with-changes ]; then
    catchup_branch_commit frontend/app/x.ts "$(catchup_lines 40 x 5=branch-edit)" || return 1
  fi
  V2_BEFORE="$(v2_local)" || return 1
  catchup_git checkout -q -b feat/twin refs/remotes/origin/main || return 1
  catchup_git config branch.feat/twin.gaia-audit-base main || return 1
  if [ "$patch" = with-changes ]; then
    catchup_branch_commit frontend/app/x.ts "$(catchup_lines 40 x 5=branch-edit)" || return 1
  fi
  V2_AFTER="$(v2_local)"
}

@test "two branches with byte-identical patches, or both empty, have different digests for every member" {
  for patch in with-changes empty; do
    v2_twin_run "$BATS_TEST_TMPDIR/twin-$patch" "$patch" || return 1
    [ -n "$V2_BEFORE" ] || return 1
    [ "$(v2_members "$V2_BEFORE")" = "$(v2_members "$V2_AFTER")" ] || return 1
    [ "$(v2_rotated "$V2_BEFORE" "$V2_AFTER" | sort)" = "$(v2_members "$V2_BEFORE" | sort)" ] || return 1
  done
}

@test "twin branches share one digest per member once the branch key leaves the frame" {
  v2_use_mutant audit-digest.sh "\\0%s\\0' \"\$branch_key\"" "\\0%s\\0' \"\"" || return 1
  for patch in with-changes empty; do
    v2_twin_run "$BATS_TEST_TMPDIR/twin-mutant-$patch" "$patch" || return 1
    [ -n "$V2_BEFORE" ] || return 1
    [ "$V2_BEFORE" = "$V2_AFTER" ] || return 1
  done
}

# ---------------------------------------------------------------------------
# A branch's own edit to gate machinery or a global rule rotates everyone.
# ---------------------------------------------------------------------------

@test "a branch commit editing gate machinery rotates every member" {
  v2_seed "$BATS_TEST_TMPDIR/machinery" || return 1
  catchup_branch_commit frontend/app/x.ts "$(catchup_lines 40 x 5=branch-edit)" || return 1
  before="$(v2_local)"
  catchup_branch_commit .gaia/scripts/audit-write-clearance.sh "$(catchup_lines 10 clearance 3=branch-edit)" || return 1
  after="$(v2_local)"
  v2_expect_rotated_all_but "$before" "$after"
}

@test "a branch commit editing a global-rules path rotates every member" {
  v2_seed "$BATS_TEST_TMPDIR/rules" || return 1
  catchup_branch_commit frontend/app/x.ts "$(catchup_lines 40 x 5=branch-edit)" || return 1
  before="$(v2_local)"
  catchup_branch_commit .claude/rules/quality-gate.md "$(catchup_lines 10 gate 3=branch-edit)" || return 1
  after="$(v2_local)"
  v2_expect_rotated_all_but "$before" "$after"
}

# ---------------------------------------------------------------------------
# A base-side roster, machinery or allowlist change, merged cleanly, rotates
# exactly the members whose selection of the branch's own paths it moved.
# ---------------------------------------------------------------------------

# v2_base_edit_run <directory> <base edit>: the branch changes a frontend path
# and a docs path; the base then edits a classifier input; sets V2_BEFORE and
# V2_AFTER around the clean catch-up.
v2_base_edit_run() {
  local directory="$1" edit="$2" edited="$BATS_TEST_TMPDIR/base-edited-file" line in_member=0 inserted=0
  v2_seed "$directory" || return 1
  catchup_branch_commit frontend/app/x.ts "$(catchup_lines 40 x 5=branch-edit)" || return 1
  catchup_branch_commit docs/branch-note.md "branch note" || return 1
  V2_BEFORE="$(v2_local)" || return 1
  case "$edit" in
    roster:*)
      while IFS= read -r line; do
        printf '%s\n' "$line"
        if [ "$line" = "  - name: $NODE_MEMBER" ]; then
          in_member=1
        elif [ "$in_member" = 1 ] && [ "$line" = "    globs:" ]; then
          printf '      - "%s"\n' "${edit#roster:}"
          in_member=0
          inserted=1
        fi
      done <"$CATCHUP_ROOT/.gaia/audit-ci.yml" >"$edited"
      [ "$inserted" = 1 ] || return 1
      catchup_base_commit .gaia/audit-ci.yml "$edited" || return 1
      ;;
    machinery:*)
      cp "$CATCHUP_ROOT/.claude/hooks/lib/audit-machinery.sh" "$edited" || return 1
      v2_replace_literal "$edited" "<<'EOF'"$'\n'".gaia/audit-ci.yml" "<<'EOF'"$'\n'"${edit#machinery:}"$'\n'".gaia/audit-ci.yml" || return 1
      catchup_base_commit .claude/hooks/lib/audit-machinery.sh "$edited" || return 1
      ;;
    allowlist:*)
      cp "$CATCHUP_ROOT/.claude/hooks/lib/audit-scope.sh" "$edited" || return 1
      case "${edit#allowlist:}" in
        docs) v2_replace_literal "$edited" ".gaia/*|docs/*)" ".gaia/*)" || return 1 ;;
        wiki) v2_replace_literal "$edited" "wiki/*|.claude/*" ".claude/*" || return 1 ;;
        *) return 1 ;;
      esac
      catchup_base_commit .claude/hooks/lib/audit-scope.sh "$edited" || return 1
      ;;
  esac
  catchup_merge_base || return 1
  V2_AFTER="$(v2_local)"
}

@test "a base roster change moving a branch path to another member rotates exactly the two members" {
  v2_base_edit_run "$BATS_TEST_TMPDIR/roster-move" "roster:frontend/app/x.ts" || return 1
  v2_expect_rotated "$V2_BEFORE" "$V2_AFTER" "$FRONTEND_MEMBER" "$NODE_MEMBER"
}

@test "the same base roster change on a path outside the branch's patch rotates nothing" {
  v2_base_edit_run "$BATS_TEST_TMPDIR/roster-move-outside" "roster:frontend/app/unrelated.ts" || return 1
  v2_expect_rotated "$V2_BEFORE" "$V2_AFTER"
}

@test "a base change adding a branch path to the machinery list rotates the members that did not already select it" {
  v2_base_edit_run "$BATS_TEST_TMPDIR/machinery-add" "machinery:frontend/app/x.ts" || return 1
  v2_expect_rotated_all_but "$V2_BEFORE" "$V2_AFTER" "$FRONTEND_MEMBER"
}

@test "the same machinery-list change on a path outside the branch's patch rotates nothing" {
  v2_base_edit_run "$BATS_TEST_TMPDIR/machinery-add-outside" "machinery:frontend/app/unrelated.ts" || return 1
  v2_expect_rotated "$V2_BEFORE" "$V2_AFTER"
}

@test "a base change removing a branch path's prefix from the out-of-scope allowlist rotates the default member only" {
  v2_base_edit_run "$BATS_TEST_TMPDIR/allowlist-remove" "allowlist:docs" || return 1
  v2_expect_rotated "$V2_BEFORE" "$V2_AFTER" "$FRONTEND_MEMBER"
}

@test "the same allowlist change on a prefix no branch path uses rotates nothing" {
  v2_base_edit_run "$BATS_TEST_TMPDIR/allowlist-remove-outside" "allowlist:wiki" || return 1
  v2_expect_rotated "$V2_BEFORE" "$V2_AFTER"
}

# ---------------------------------------------------------------------------
# The branch-own digest is not the content digest, and never falls back to it.
# ---------------------------------------------------------------------------

@test "for the same checkout, the content digest and the branch-own digest of every member differ" {
  v2_seed "$BATS_TEST_TMPDIR/versus" || return 1
  v2_branch_work || return 1
  branch_own="$(v2_local)"
  content="$(bash -c '. "$1/.claude/hooks/lib/audit-digest.sh"; audit_digests_all "$2"' _ "$CATCHUP_ROOT" "$CATCHUP_ROOT")"
  [ "$(v2_members "$content")" = "$(v2_members "$branch_own")" ] || return 1
  while IFS= read -r line; do
    member_name="${line%%$'\t'*}"
    [ "${line#*$'\t'}" != "$(grep -F "$member_name"$'\t' <<<"$content" | cut -f2)" ] || return 1
  done <<<"$branch_own"
  true
}

# ---------------------------------------------------------------------------
# Fail closed: nothing on stdout and a non-zero status, atomically.
# ---------------------------------------------------------------------------

@test "branch-own: an undeterminable branch key emits nothing and fails; a supplied key succeeds" {
  v2_seed "$BATS_TEST_TMPDIR/detached" || return 1
  v2_branch_work || return 1
  merge_base="$(catchup_git merge-base refs/remotes/origin/main HEAD)"
  catchup_git checkout -q --detach || return 1
  run env -u GAIA_AUDIT_KEY_BRANCH bash -c '. "$1/.claude/hooks/lib/audit-digest.sh"; audit_branch_digests_all "$1" "$2"' _ "$CATCHUP_ROOT" "$merge_base"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  run env GAIA_AUDIT_KEY_BRANCH=ci bash -c '. "$1/.claude/hooks/lib/audit-digest.sh"; audit_branch_digests_all "$1" "$2"' _ "$CATCHUP_ROOT" "$merge_base"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "branch-own: a PATH with no sha256 tool emits nothing and fails; the same PATH with one succeeds" {
  v2_seed "$BATS_TEST_TMPDIR/nosha" || return 1
  v2_branch_work || return 1
  merge_base="$(catchup_git merge-base refs/remotes/origin/main HEAD)"
  tools="$BATS_TEST_TMPDIR/tools"
  mkdir -p "$tools"
  for tool in git mktemp sort awk sed cat rm tr grep cut head mkdir uname env bash dirname basename wc find; do
    real="$(command -v "$tool")" || continue
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$real" >"$tools/$tool"
    chmod +x "$tools/$tool"
  done
  run bash -c '. "$1/.claude/hooks/lib/audit-digest.sh"; PATH="$3"; audit_branch_digests_all "$1" "$2"' _ "$CATCHUP_ROOT" "$merge_base" "$tools"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  for tool in sha256sum shasum; do
    real="$(command -v "$tool")" || continue
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$real" >"$tools/$tool"
    chmod +x "$tools/$tool"
  done
  run bash -c '. "$1/.claude/hooks/lib/audit-digest.sh"; PATH="$3"; audit_branch_digests_all "$1" "$2"' _ "$CATCHUP_ROOT" "$merge_base" "$tools"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "branch-own: a merge base the identity listing cannot read emits nothing and fails" {
  v2_seed "$BATS_TEST_TMPDIR/identity-failure" || return 1
  v2_branch_work || return 1
  merge_base="$(catchup_git merge-base refs/remotes/origin/main HEAD)"
  run v2_all 1111111111111111111111111111111111111111
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  run v2_all "$merge_base"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "branch-own: a root with no auditors emits nothing and fails" {
  catchup_init "$BATS_TEST_TMPDIR/no-roster" || return 1
  merge_base="$(catchup_git merge-base refs/remotes/origin/main HEAD)"
  # The classifier names the missing roster on stderr, which is not the stdout
  # this case pins.
  run bash -c '. "$1"; audit_branch_digests_all "$2" "$3" 2>/dev/null' _ "$DIGEST_LIBRARY" "$CATCHUP_ROOT" "$merge_base"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  seed_audit_roster "$CATCHUP_ROOT" || return 1
  run bash -c '. "$1"; audit_branch_digests_all "$2" "$3"' _ "$DIGEST_LIBRARY" "$CATCHUP_ROOT" "$merge_base"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "branch-own local: a base tip that is not a commit here returns 4 and emits nothing" {
  v2_seed "$BATS_TEST_TMPDIR/absent-tip" || return 1
  v2_branch_work || return 1
  run bash -c '
    . "$1/.claude/hooks/lib/audit-digest.sh"
    audit_local_base_reference() { printf "%s\n" 1111111111111111111111111111111111111111; }
    audit_branch_digests_local "$1"
  ' _ "$CATCHUP_ROOT"
  [ "$status" -eq 4 ]
  [ -z "$output" ]
}

@test "branch-own local: a criss-cross history returns 3 and emits nothing" {
  v2_seed "$BATS_TEST_TMPDIR/criss-cross" || return 1
  catchup_criss_cross || return 1
  run bash -c '. "$1/.claude/hooks/lib/audit-digest.sh"; audit_branch_digests_local "$1"' _ "$CATCHUP_ROOT"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Target tree-ish and batching.
# ---------------------------------------------------------------------------

@test "branch-own: a bare tree id of HEAD's content gives the HEAD result, and a different tree differs" {
  v2_seed "$BATS_TEST_TMPDIR/tree" || return 1
  v2_branch_work || return 1
  merge_base="$(catchup_git merge-base refs/remotes/origin/main HEAD)"
  tree="$(catchup_git write-tree)"
  [ -n "$tree" ] || return 1
  [ "$(v2_all "$merge_base" "$tree")" = "$(v2_all "$merge_base")" ] || return 1
  [ "$(v2_local "$tree")" = "$(v2_local)" ] || return 1
  catchup_lines 40 x 5=branch-edit 9=staged-edit >"$CATCHUP_ROOT/frontend/app/x.ts"
  catchup_git add -- frontend/app/x.ts || return 1
  edited_tree="$(catchup_git write-tree)"
  [ "$(v2_all "$merge_base" "$edited_tree")" != "$(v2_all "$merge_base")" ] || return 1
  true
}

# v2_identity_listings: the number of identity listings one
# audit_branch_digests_all call makes, read from a `git` wrapper that logs its
# argv; the member count of that call is left in V2_MEMBER_COUNT.
v2_identity_listings() {
  local merge_base stub log real_git
  merge_base="$(catchup_git merge-base refs/remotes/origin/main HEAD)"
  stub="$BATS_TEST_TMPDIR/git-stub"
  log="$BATS_TEST_TMPDIR/git-calls.log"
  real_git="$(command -v git)"
  mkdir -p "$stub"
  : >"$log"
  cat >"$stub/git" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$log"
exec "$real_git" "\$@"
STUB
  chmod +x "$stub/git"
  V2_MEMBERS_OUTPUT="$(PATH="$stub:$PATH" bash -c '. "$1/.claude/hooks/lib/audit-digest.sh"; audit_branch_digests_all "$2" "$3"' \
    _ "${V2_LIBRARY_ROOT:-$CATCHUP_ROOT}" "$CATCHUP_ROOT" "$merge_base")" || return 1
  V2_MEMBER_COUNT="$(printf '%s\n' "$V2_MEMBERS_OUTPUT" | wc -l | tr -d ' ')"
  V2_LISTINGS="$(grep -c -- '--raw' "$log")" || true
}

@test "branch-own: one call lists the branch's identities once, however many members the roster has" {
  v2_seed "$BATS_TEST_TMPDIR/batching" || return 1
  v2_branch_work || return 1
  v2_identity_listings || return 1
  [ "$V2_MEMBER_COUNT" -ge 4 ] || return 1
  [ "$V2_LISTINGS" -eq 1 ]
}

@test "the identity listing count rises with the roster when the listing moves into the member loop" {
  v2_use_mutant audit-digest.sh ': >"$work/frame" || return 1' ': >"$work/frame" || return 1; audit_branch_patch_identities "$root" "$merge_base" "$target" >/dev/null 2>/dev/null' || return 1
  v2_seed "$BATS_TEST_TMPDIR/batching-mutant" || return 1
  v2_branch_work || return 1
  v2_identity_listings || return 1
  [ "$V2_LISTINGS" -gt 1 ]
}
