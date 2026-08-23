#!/usr/bin/env bats
#
# Tests for .claude/hooks/lib/audit-base-provenance.sh, the shared
# provenance-keyed base resolver: audit_resolve_base_provenance,
# audit_provenance_changed_files, audit_provenance_empty_is_decisive.
#
# Fixture technique lifted from
# .gaia/scripts/tests/audit-base-agreement.bats' "the write side and the
# verify side agree across three repository shapes": an origin-sim branch
# sharing no ancestry with the local fork point beyond the root,
# refs/remotes/origin/main written directly with update-ref (a remote-tracking
# ref only ever needs to resolve, never to fetch), and refs/remotes/origin/HEAD
# set with symbolic-ref.
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md):
#   bash .gaia/scripts/bats5.sh .gaia/tests/hooks/audit-base-provenance-lib.bats
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO_ROOT="$(git -C "$THIS_DIR" rev-parse --show-toplevel)"
  LIB="$REPO_ROOT/.claude/hooks/lib/audit-base-provenance.sh"
}

# make_repo <name>: an isolated repo with an initial commit on main.
make_repo() {
  local name="$1"
  local dir="$BATS_TEST_TMPDIR/$name"
  git init -q --initial-branch=main "$dir"
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name T
  git -C "$dir" config commit.gpgsign false
  commit_file "$dir" "root.txt" "init"
  printf '%s' "$dir"
}

# commit_file <repo> <path> <message>: writes a line into <path> and commits.
commit_file() {
  local repo="$1" path="$2" message="$3"
  mkdir -p "$(dirname "$repo/$path")"
  printf 'touched by %s\n' "$message" >> "$repo/$path"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "$message"
}

# resolve <root> <anchor-request> [<supplied-base>] [<record-base-branch>]:
# sources the lib and calls audit_resolve_base_provenance, leaving stdout in
# $output and the exit status in $status (bats' own run() semantics). The
# usage-error diagnostic is a deliberate stderr line (see the lib's own
# contract), so it is discarded here rather than folded into $output, which
# would otherwise make a usage error look like non-empty stdout.
resolve() {
  run bash -c '. "$1"; audit_resolve_base_provenance "$2" "$3" "$4" "$5" 2>/dev/null' _ \
    "$LIB" "$1" "$2" "${3:-}" "${4:-}"
}

# --- the remote-vs-local-vs-shadow default-branch ladder ---------------------

@test "remote trust: refs/remotes/origin/HEAD set, refs/remotes/origin/main resolves" {
  local repo base_sha
  repo="$(make_repo remote-trust)"
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" "feat.txt" "feat commit"
  base_sha="$(git -C "$repo" rev-parse main)"
  git -C "$repo" update-ref refs/remotes/origin/main refs/heads/main
  git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

  resolve "$repo" default-branch
  [ "$status" -eq 0 ]
  [ "$output" = "remote	default-branch	$base_sha" ]
}

@test "local trust: no remote-tracking ref, local main resolves" {
  local repo base_sha
  repo="$(make_repo local-trust)"
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" "feat.txt" "feat commit"
  base_sha="$(git -C "$repo" rev-parse main)"

  resolve "$repo" default-branch
  [ "$status" -eq 0 ]
  [ "$output" = "local	default-branch	$base_sha" ]
}

@test "unresolvable: neither a remote-tracking ref nor a local branch of the default name" {
  local repo
  repo="$(make_repo no-default)"
  git -C "$repo" branch -m trunk
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" "feat.txt" "feat commit"

  resolve "$repo" default-branch
  [ "$status" -eq 0 ]
  [ "$output" = "unresolvable	default-branch	" ]
}

@test "SEC-001: a local branch literally named origin/main never shadows the remote-tracking ref" {
  local repo real_base shadow_sha
  repo="$(make_repo shadow)"
  git -C "$repo" checkout -q -b origin-sim
  commit_file "$repo" "docs/origin-only.md" "origin-sim commit"
  git -C "$repo" checkout -q main
  commit_file "$repo" "docs/main-advance.md" "advance local main"
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" "docs/note.md" "feat commit"

  # The shadowing local branch: named exactly like the bare revspec, pointing
  # at origin-sim's unrelated history.
  git -C "$repo" branch "origin/main" origin-sim
  git -C "$repo" update-ref refs/remotes/origin/main refs/heads/main
  real_base="$(git -C "$repo" merge-base HEAD refs/remotes/origin/main)"
  shadow_sha="$(git -C "$repo" rev-parse origin-sim)"

  resolve "$repo" default-branch
  [ "$status" -eq 0 ]
  [ "$output" = "remote	default-branch	$real_base" ]
  [ "$output" != "remote	default-branch	$shadow_sha" ]
}

# --- supplied override --------------------------------------------------------

@test "supplied trust: an override that resolves" {
  local repo target
  repo="$(make_repo supplied-ok)"
  commit_file "$repo" "a.txt" "second"
  target="$(git -C "$repo" rev-parse HEAD)"
  commit_file "$repo" "b.txt" "third"

  resolve "$repo" default-branch "$target"
  [ "$status" -eq 0 ]
  [ "$output" = "supplied	default-branch	$target" ]
}

@test "supplied override naming an unresolvable revision is unresolvable, not empty-diff decisive" {
  local repo
  repo="$(make_repo supplied-bad)"

  resolve "$repo" default-branch "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  [ "$status" -eq 0 ]
  [ "$output" = "unresolvable	default-branch	" ]
}

# --- pr-record anchor ---------------------------------------------------------

@test "pr-record anchor: record branch's remote-tracking ref verifies" {
  local repo base_sha
  repo="$(make_repo record-ok)"
  git -C "$repo" checkout -q -b release
  commit_file "$repo" "release.txt" "release commit"
  git -C "$repo" checkout -q main
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" "feat.txt" "feat commit"
  base_sha="$(git -C "$repo" merge-base HEAD release)"
  git -C "$repo" update-ref refs/remotes/origin/release refs/heads/release

  resolve "$repo" pr-record "" "release"
  [ "$status" -eq 0 ]
  [ "$output" = "remote	pr-record	$base_sha" ]
}

@test "pr-record anchor: record ref does not verify falls back to the default-branch ladder" {
  local repo base_sha local_release
  repo="$(make_repo record-fallback)"
  git -C "$repo" checkout -q -b release
  commit_file "$repo" "release.txt" "release commit"
  git -C "$repo" checkout -q main
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" "feat.txt" "feat commit"
  base_sha="$(git -C "$repo" rev-parse main)"
  local_release="$(git -C "$repo" rev-parse release)"

  resolve "$repo" pr-record "" "release"
  [ "$status" -eq 0 ]
  [ "$output" = "local	default-branch	$base_sha" ]
  [ "$output" != "remote	pr-record	$local_release" ]
}

@test "pr-record anchor: ref verifies but merge-base fails is unresolvable, no fall-through" {
  local repo
  repo="$(make_repo record-unrelated)"
  git -C "$repo" checkout -q --orphan release
  git -C "$repo" rm -rf --quiet . 2>/dev/null || true
  commit_file "$repo" "release-root.txt" "unrelated root commit"
  git -C "$repo" checkout -q main
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" "feat.txt" "feat commit"
  git -C "$repo" update-ref refs/remotes/origin/release refs/heads/release

  resolve "$repo" pr-record "" "release"
  [ "$status" -eq 0 ]
  [ "$output" = "unresolvable	default-branch	" ]
}

@test "pr-record anchor with an empty record branch matches the default-branch request" {
  local repo default_output
  repo="$(make_repo record-empty)"
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" "feat.txt" "feat commit"

  resolve "$repo" default-branch
  default_output="$output"
  resolve "$repo" pr-record ""
  [ "$status" -eq 0 ]
  [ "$output" = "$default_output" ]
}

# --- usage errors --------------------------------------------------------------

@test "unrecognized anchor-request returns 2 with empty stdout" {
  local repo
  repo="$(make_repo bad-anchor)"

  resolve "$repo" bogus-anchor
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "empty root returns 2 with empty stdout" {
  resolve "" default-branch
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "a root that is not a work tree returns 2 with empty stdout" {
  local dir="$BATS_TEST_TMPDIR/not-a-repo"
  mkdir -p "$dir"

  resolve "$dir" default-branch
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

# --- the shape contract (UAT-008) --------------------------------------------

@test "shape: one invocation, one line of stdout, exactly three TAB-separated fields" {
  local repo lines fields
  repo="$(make_repo shape)"
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" "feat.txt" "feat commit"

  resolve "$repo" default-branch
  [ "$status" -eq 0 ]
  lines="$(printf '%s\n' "$output" | wc -l | tr -d ' ')"
  [ "$lines" -eq 1 ]
  fields="$(printf '%s' "$output" | awk -F'\t' '{print NF}')"
  [ "$fields" -eq 3 ]
}

# --- audit_provenance_changed_files ------------------------------------------

@test "changed_files: remote-verified base with no new commits returns 0 with empty stdout" {
  local repo base_sha
  repo="$(make_repo changed-empty)"
  base_sha="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" update-ref refs/remotes/origin/main refs/heads/main

  run bash -c '. "$1"; audit_provenance_changed_files "$2" "$3"' _ "$LIB" "$repo" "$base_sha"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "changed_files: an empty base returns non-zero" {
  local repo
  repo="$(make_repo changed-nobase)"

  run bash -c '. "$1"; audit_provenance_changed_files "$2" "$3"' _ "$LIB" "$repo" ""
  [ "$status" -ne 0 ]
}

@test "changed_files: a failed diff returns non-zero with empty stdout, never a real empty change set" {
  local repo
  repo="$(make_repo changed-baddiff)"

  run bash -c '. "$1"; audit_provenance_changed_files "$2" "$3"' _ "$LIB" "$repo" \
    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "changed_files: a non-ASCII path appears un-C-quoted" {
  local repo base_sha
  repo="$(make_repo changed-nonascii)"
  base_sha="$(git -C "$repo" rev-parse HEAD)"
  commit_file "$repo" "$(printf 'docs/caf\xc3\xa9.md')" "non-ascii path"

  run bash -c '. "$1"; audit_provenance_changed_files "$2" "$3"' _ "$LIB" "$repo" "$base_sha"
  [ "$status" -eq 0 ]
  grep -qF "$(printf 'docs/caf\xc3\xa9.md')" <<<"$output"
}

# --- audit_provenance_empty_is_decisive --------------------------------------

@test "empty_is_decisive: 0 for remote and supplied, 1 for local, unresolvable, empty, and unrecognized" {
  run bash -c '. "$1"; audit_provenance_empty_is_decisive remote' _ "$LIB"
  [ "$status" -eq 0 ]
  run bash -c '. "$1"; audit_provenance_empty_is_decisive supplied' _ "$LIB"
  [ "$status" -eq 0 ]
  run bash -c '. "$1"; audit_provenance_empty_is_decisive local' _ "$LIB"
  [ "$status" -eq 1 ]
  run bash -c '. "$1"; audit_provenance_empty_is_decisive unresolvable' _ "$LIB"
  [ "$status" -eq 1 ]
  run bash -c '. "$1"; audit_provenance_empty_is_decisive ""' _ "$LIB"
  [ "$status" -eq 1 ]
  run bash -c '. "$1"; audit_provenance_empty_is_decisive nonsense' _ "$LIB"
  [ "$status" -eq 1 ]
}
