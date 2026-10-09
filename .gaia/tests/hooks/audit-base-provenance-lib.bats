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
  THIS_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO_ROOT="$(git -C "$THIS_DIRECTORY" rev-parse --show-toplevel)"
  PROVENANCE_LIBRARY="$REPO_ROOT/.claude/hooks/lib/audit-base-provenance.sh"
}

# make_repo <name>: an isolated repo with an initial commit on main.
make_repo() {
  local name="$1"
  local repository_directory="$BATS_TEST_TMPDIR/$name"
  git init -q --initial-branch=main "$repository_directory"
  git -C "$repository_directory" config user.email t@example.com
  git -C "$repository_directory" config user.name T
  git -C "$repository_directory" config commit.gpgsign false
  commit_file "$repository_directory" "root.txt" "init"
  printf '%s' "$repository_directory"
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
    "$PROVENANCE_LIBRARY" "$1" "$2" "${3:-}" "${4:-}"
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
  local non_repository_directory="$BATS_TEST_TMPDIR/not-a-repo"
  mkdir -p "$non_repository_directory"

  resolve "$non_repository_directory" default-branch
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

  run bash -c '. "$1"; audit_provenance_changed_files "$2" "$3"' _ "$PROVENANCE_LIBRARY" "$repo" "$base_sha"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "changed_files: an empty base returns non-zero" {
  local repo
  repo="$(make_repo changed-nobase)"

  run bash -c '. "$1"; audit_provenance_changed_files "$2" "$3"' _ "$PROVENANCE_LIBRARY" "$repo" ""
  [ "$status" -ne 0 ]
}

@test "changed_files: a failed diff returns non-zero with empty stdout, never a real empty change set" {
  local repo
  repo="$(make_repo changed-baddiff)"

  run bash -c '. "$1"; audit_provenance_changed_files "$2" "$3"' _ "$PROVENANCE_LIBRARY" "$repo" \
    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "changed_files: a non-ASCII path appears un-C-quoted" {
  local repo base_sha
  repo="$(make_repo changed-nonascii)"
  base_sha="$(git -C "$repo" rev-parse HEAD)"
  commit_file "$repo" "$(printf 'docs/caf\xc3\xa9.md')" "non-ascii path"

  run bash -c '. "$1"; audit_provenance_changed_files "$2" "$3"' _ "$PROVENANCE_LIBRARY" "$repo" "$base_sha"
  [ "$status" -eq 0 ]
  grep -qF "$(printf 'docs/caf\xc3\xa9.md')" <<<"$output"
}

@test "changed_files: a rename lists both its old and its new path" {
  local repo base_sha
  repo="$(make_repo changed-rename)"
  mkdir -p "$repo/app"
  printf 'export const moved = "a line long enough to be detected as a rename";\n' > "$repo/app/moved.ts"
  git -C "$repo" add app/moved.ts
  git -C "$repo" commit --quiet -m "app source"
  base_sha="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" mv app/moved.ts wiki-moved.md
  git -C "$repo" commit --quiet -m "move"

  run bash -c '. "$1"; audit_provenance_changed_files "$2" "$3"' _ "$PROVENANCE_LIBRARY" "$repo" "$base_sha"
  [ "$status" -eq 0 ]
  grep -qxF "app/moved.ts" <<<"$output"
  grep -qxF "wiki-moved.md" <<<"$output"
}

# --- audit_provenance_empty_is_decisive --------------------------------------

@test "empty_is_decisive: 0 for remote and supplied, 1 for local, unresolvable, empty, and unrecognized" {
  run bash -c '. "$1"; audit_provenance_empty_is_decisive remote' _ "$PROVENANCE_LIBRARY"
  [ "$status" -eq 0 ]
  run bash -c '. "$1"; audit_provenance_empty_is_decisive supplied' _ "$PROVENANCE_LIBRARY"
  [ "$status" -eq 0 ]
  run bash -c '. "$1"; audit_provenance_empty_is_decisive local' _ "$PROVENANCE_LIBRARY"
  [ "$status" -eq 1 ]
  run bash -c '. "$1"; audit_provenance_empty_is_decisive unresolvable' _ "$PROVENANCE_LIBRARY"
  [ "$status" -eq 1 ]
  run bash -c '. "$1"; audit_provenance_empty_is_decisive ""' _ "$PROVENANCE_LIBRARY"
  [ "$status" -eq 1 ]
  run bash -c '. "$1"; audit_provenance_empty_is_decisive nonsense' _ "$PROVENANCE_LIBRARY"
  [ "$status" -eq 1 ]
}

# --- GitHub-sourced trusted base and the local base reference ------------------

# use_gh_stub: installs the gh stub first on PATH and points its log at a fresh
# file. Every case below drives gh through it, never a real gh.
use_gh_stub() {
  . "$REPO_ROOT/.gaia/tests/helpers/gh-base-stub.sh"
  STUB_BIN="$BATS_TEST_TMPDIR/stub-bin"
  gh_base_stub_install "$STUB_BIN"
  export PATH="$STUB_BIN:$PATH"
  export GH_STUB_LOG="$BATS_TEST_TMPDIR/gh.log"
  export GH_STUB_PID_LOG="$BATS_TEST_TMPDIR/gh.pids"
  export GH_STUB_BASE_TIP="1111111111111111111111111111111111111111"
  : > "$GH_STUB_LOG"
}

# call_function <function> [args...]: runs a library function with stdout in
# $output and stderr in $STDERR_FILE.
call_function() {
  STDERR_FILE="$BATS_TEST_TMPDIR/stderr.txt"
  run bash -c '. "$1"; error_file="$2"; shift 2; "$@" 2>"$error_file"' _ "$PROVENANCE_LIBRARY" "$STDERR_FILE" "$@"
}

# make_feature_repo <name>: a repo on branch feat with refs/remotes/origin/main.
make_feature_repo() {
  local repo
  repo="$(make_repo "$1")"
  git -C "$repo" update-ref refs/remotes/origin/main refs/heads/main
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" "feat.txt" "feat commit"
  printf '%s' "$repo"
}

# mutated_library <name> <sed-expression>: a scratch copy of the library with
# one sed mutation; fails when the mutation did not change the file.
mutated_library() {
  local copy="$BATS_TEST_TMPDIR/$1.sh"
  sed -e "$2" "$PROVENANCE_LIBRARY" > "$copy"
  if cmp -s "$copy" "$PROVENANCE_LIBRARY"; then
    echo "mutation $1 did not change the library" >&2
    return 1
  fi
  printf '%s' "$copy"
}

@test "github_base_tip: prints the stubbed tip and makes exactly one branches call" {
  use_gh_stub
  local repo
  repo="$(make_feature_repo tip-ok)"

  call_function audit_github_base_tip "$repo" owner/repo main
  [ "$status" -eq 0 ]
  [ "$output" = "$GH_STUB_BASE_TIP" ]
  [ "$(grep -c '^api repos/owner/repo/branches/main' "$GH_STUB_LOG")" -eq 1 ]
}

@test "github_base_tip: a gh failure returns 5 with empty stdout and one stderr line" {
  use_gh_stub
  local repo
  repo="$(make_feature_repo tip-fail)"

  GH_STUB_FAIL=1 call_function audit_github_base_tip "$repo" owner/repo main
  [ "$status" -eq 5 ]
  [ -z "$output" ]
  [ "$(wc -l < "$STDERR_FILE" | tr -d ' ')" -eq 1 ]
  grep -qi 'gh' "$STDERR_FILE"
}

@test "github_base_tip: the failure guard can fail (mutated copy answers the stub value and returns 0)" {
  use_gh_stub
  local repo mutated
  repo="$(make_feature_repo tip-fail-mutated)"
  mutated="$(mutated_library fail-open 's/^  return 5$/  printf "%s\\n" "${GH_STUB_BASE_TIP:-}"; return 0/')"

  GH_STUB_FAIL=1 run bash -c '. "$1"; audit_github_base_tip "$2" owner/repo main 2>/dev/null' _ "$mutated" "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "$GH_STUB_BASE_TIP" ]
}

@test "github_base_tip: a hung gh returns 5 within the deadline and leaves no process" {
  use_gh_stub
  local repo started elapsed pid
  repo="$(make_feature_repo tip-hang)"

  started="$(date +%s)"
  GH_STUB_HANG=1 GAIA_AUDIT_GH_DEADLINE_SECONDS=2 call_function audit_github_base_tip "$repo" owner/repo main
  elapsed=$(( $(date +%s) - started ))
  [ "$status" -eq 5 ]
  [ -z "$output" ]
  [ "$elapsed" -le 4 ]
  grep -qi 'timed out' "$STDERR_FILE"
  [ -s "$GH_STUB_PID_LOG" ]
  for pid in $(cat "$GH_STUB_PID_LOG"); do
    if kill -0 "$pid" 2>/dev/null; then
      echo "process $pid survived the deadline" >&2
      return 1
    fi
  done
  true
}

@test "github_base_tip: a branches-only hang does not stall other gh calls" {
  use_gh_stub
  local repo
  repo="$(make_feature_repo tip-branches-only)"

  GH_STUB_HANG_BRANCHES=1 GAIA_AUDIT_GH_DEADLINE_SECONDS=2 call_function audit_github_base_tip "$repo" owner/repo main
  [ "$status" -eq 5 ]
  GH_STUB_HANG_BRANCHES=1 call_function audit_github_repository "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "owner/repo" ]
}

@test "github_base_tip: a non-hex answer returns 5" {
  use_gh_stub
  local repo
  repo="$(make_feature_repo tip-nonhex)"

  GH_STUB_BASE_TIP=not-a-sha call_function audit_github_base_tip "$repo" owner/repo main
  [ "$status" -eq 5 ]
  [ -z "$output" ]
  GH_STUB_BASE_TIP=ABCDEF1111111111111111111111111111111111 call_function audit_github_base_tip "$repo" owner/repo main
  [ "$status" -eq 5 ]
  GH_STUB_BASE_TIP=11111111 call_function audit_github_base_tip "$repo" owner/repo main
  [ "$status" -eq 5 ]
}

@test "github_base_tip: gh absent from PATH returns 5" {
  local repo
  repo="$(make_feature_repo tip-no-gh)"
  mkdir -p "$BATS_TEST_TMPDIR/bare-bin"
  ln -s "$(command -v git)" "$BATS_TEST_TMPDIR/bare-bin/git"
  ln -s "$(command -v bash)" "$BATS_TEST_TMPDIR/bare-bin/bash"

  STDERR_FILE="$BATS_TEST_TMPDIR/stderr.txt"
  PATH="$BATS_TEST_TMPDIR/bare-bin" run bash -c '. "$1"; audit_github_base_tip "$2" owner/repo main 2>"$3"' _ \
    "$PROVENANCE_LIBRARY" "$repo" "$STDERR_FILE"
  [ "$status" -eq 5 ]
  [ -z "$output" ]
}

@test "github_pr_base_branch: prints the PR base branch the stub reports" {
  use_gh_stub
  local repo
  repo="$(make_feature_repo pr-base)"

  GH_STUB_BASE_BRANCH=release/2 call_function audit_github_pr_base_branch "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "release/2" ]
  GH_STUB_FAIL=1 call_function audit_github_pr_base_branch "$repo"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "github_repository: equals the status poster's own derivation in the same sandbox" {
  use_gh_stub
  local repo poster_derivation
  repo="$(make_feature_repo repository)"
  export GH_STUB_REPOSITORY="acme/widgets"

  poster_derivation="$(cd "$repo" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
  call_function audit_github_repository "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "$poster_derivation" ]
  [ "$output" = "acme/widgets" ]

  GH_STUB_FAIL=1 call_function audit_github_repository "$repo"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "local_base_reference: a cached name answers with no gh call" {
  use_gh_stub
  local repo
  repo="$(make_feature_repo cache-hit)"
  git -C "$repo" update-ref refs/remotes/origin/release refs/heads/main
  git -C "$repo" config branch.feat.gaia-audit-base release

  call_function audit_local_base_reference "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "refs/remotes/origin/release" ]
  [ ! -s "$GH_STUB_LOG" ]
}

@test "local_base_reference: a cache miss asks gh once, writes the cache, and the second call makes no gh call" {
  use_gh_stub
  local repo
  repo="$(make_feature_repo cache-miss)"
  git -C "$repo" update-ref refs/remotes/origin/release refs/heads/main

  GH_STUB_BASE_BRANCH=release call_function audit_local_base_reference "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "refs/remotes/origin/release" ]
  [ "$(git -C "$repo" config --get branch.feat.gaia-audit-base)" = "release" ]
  [ "$(grep -c '^pr view' "$GH_STUB_LOG")" -eq 1 ]

  : > "$GH_STUB_LOG"
  GH_STUB_BASE_BRANCH=release call_function audit_local_base_reference "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "refs/remotes/origin/release" ]
  [ ! -s "$GH_STUB_LOG" ]
}

@test "local_base_reference: the cache is what removes the network cost (mutated copy without the cache read calls gh again)" {
  use_gh_stub
  local repo mutated
  repo="$(make_feature_repo cache-mutated)"
  git -C "$repo" update-ref refs/remotes/origin/release refs/heads/main
  git -C "$repo" config branch.feat.gaia-audit-base release
  mutated="$(mutated_library no-cache-read 's/^\( *\)cached_name=.*config --get.*$/\1cached_name=""/')"

  GH_STUB_BASE_BRANCH=release run bash -c '. "$1"; audit_local_base_reference "$2" 2>/dev/null' _ "$mutated" "$repo"
  [ "$status" -eq 0 ]
  grep -q '^pr view' "$GH_STUB_LOG"
}

@test "local_base_reference: a gh failure writes no cache key and falls back to the origin HEAD target" {
  use_gh_stub
  local repo
  repo="$(make_feature_repo gh-fails-head)"
  git -C "$repo" update-ref refs/remotes/origin/trunk refs/heads/main
  git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk

  GH_STUB_FAIL=1 call_function audit_local_base_reference "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "refs/remotes/origin/trunk" ]
  git -C "$repo" config --get branch.feat.gaia-audit-base && return 1
  true
}

@test "local_base_reference: with gh failing and no origin HEAD it falls back to origin main" {
  use_gh_stub
  local repo
  repo="$(make_feature_repo gh-fails-main)"

  GH_STUB_FAIL=1 call_function audit_local_base_reference "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "refs/remotes/origin/main" ]
  git -C "$repo" config --get branch.feat.gaia-audit-base && return 1
  true
}

@test "local_base_reference: a detached HEAD skips the cache and gh" {
  use_gh_stub
  local repo
  repo="$(make_feature_repo detached)"
  git -C "$repo" update-ref refs/remotes/origin/release refs/heads/main
  git -C "$repo" config branch.feat.gaia-audit-base release
  git -C "$repo" checkout -q --detach

  GH_STUB_BASE_BRANCH=release call_function audit_local_base_reference "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "refs/remotes/origin/main" ]
  [ ! -s "$GH_STUB_LOG" ]
}

@test "local_base_reference: a resolved ref that does not exist returns 1 naming git fetch origin" {
  use_gh_stub
  local repo
  repo="$(make_feature_repo ref-missing)"
  git -C "$repo" config branch.feat.gaia-audit-base ghost

  call_function audit_local_base_reference "$repo"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$(wc -l < "$STDERR_FILE" | tr -d ' ')" -eq 1 ]
  grep -qF 'git fetch origin' "$STDERR_FILE"
}

@test "local_base_reference: a local branch named origin/main never stands in for the remote-tracking ref" {
  use_gh_stub
  local repo forged_sha real_sha mutated
  repo="$(make_feature_repo forged)"
  git -C "$repo" checkout -q main
  commit_file "$repo" "main-advance.txt" "advance main"
  git -C "$repo" update-ref refs/remotes/origin/main refs/heads/main
  git -C "$repo" checkout -q feat
  git -C "$repo" branch "origin/main" feat
  real_sha="$(git -C "$repo" rev-parse refs/remotes/origin/main)"
  forged_sha="$(git -C "$repo" rev-parse refs/heads/origin/main)"
  [ "$real_sha" != "$forged_sha" ]

  call_function audit_local_base_reference "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "refs/remotes/origin/main" ]
  [ "$(git -C "$repo" rev-parse "$output")" = "$real_sha" ]

  mutated="$(mutated_library bare-revspec 's@refs/remotes/origin/\${name}@origin/${name}@')"
  run bash -c '. "$1"; audit_local_base_reference "$2" 2>/dev/null' _ "$mutated" "$repo"
  [ "$status" -eq 0 ]
  [ "$(git -C "$repo" rev-parse "$output")" = "$forged_sha" ]
}

@test "local_base_reference: no remote-tracking ref at all returns 1 even with a local main" {
  use_gh_stub
  local repo
  repo="$(make_repo no-remote)"
  git -C "$repo" checkout -q -b feat
  commit_file "$repo" "feat.txt" "feat commit"

  call_function audit_local_base_reference "$repo"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -qF 'git fetch origin' "$STDERR_FILE"
}

@test "the new functions never run git fetch" {
  use_gh_stub
  local repo real_git
  repo="$(make_feature_repo no-fetch)"
  real_git="$(command -v git)"
  mkdir -p "$BATS_TEST_TMPDIR/git-wrapper"
  cat > "$BATS_TEST_TMPDIR/git-wrapper/git" <<WRAPPER
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$BATS_TEST_TMPDIR/git.log"
exec "$real_git" "\$@"
WRAPPER
  chmod +x "$BATS_TEST_TMPDIR/git-wrapper/git"
  export PATH="$BATS_TEST_TMPDIR/git-wrapper:$PATH"

  call_function audit_local_base_reference "$repo"
  call_function audit_github_repository "$repo"
  call_function audit_github_pr_base_branch "$repo"
  GH_STUB_FAIL=1 call_function audit_github_base_tip "$repo" owner/repo main
  call_function audit_github_base_tip "$repo" owner/repo main

  [ -s "$BATS_TEST_TMPDIR/git.log" ]
  grep -qE '(^| )fetch( |$)' "$BATS_TEST_TMPDIR/git.log" && return 1
  true
}

@test "empty_is_decisive: github is decisive; local and unresolvable still are not" {
  run bash -c '. "$1"; audit_provenance_empty_is_decisive github' _ "$PROVENANCE_LIBRARY"
  [ "$status" -eq 0 ]
  run bash -c '. "$1"; audit_provenance_empty_is_decisive local' _ "$PROVENANCE_LIBRARY"
  [ "$status" -eq 1 ]
  run bash -c '. "$1"; audit_provenance_empty_is_decisive unresolvable' _ "$PROVENANCE_LIBRARY"
  [ "$status" -eq 1 ]
}
