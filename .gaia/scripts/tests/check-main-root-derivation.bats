#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/check-main-root-derivation.sh -- Check
# B, task 7.4's regression gate. Where check-resolver-singleton.sh (Check A)
# catches a second named resolver DEFINITION, this check catches a
# hand-rolled main-root DERIVATION inlined into a consumer that declares no
# resolver function at all: three cheap ingredient scans
# (--git-common-dir, a worktrees parameter-expansion trim, and
# `worktree list --porcelain` piped to a first-record reader), each proven
# against tracked source to carry zero legitimate use outside the resolver.
#
# This suite IS the gate: nothing else in the repo invokes the check, so
# the "real repo" test below is what actually fails a build when a new
# hand-rolled derivation lands (same shape as
# check-resolver-singleton.bats's own "real repo" tests).
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/check-main-root-derivation.bats`.
#
# Assertion style note: per .claude/rules/bats-assertions.md, non-final
# absence checks use a positive match for the bad case plus an explicit
# `return 1`, never `!`-negation; equality/numeric/empty checks use POSIX
# `[ ... ]`, which fails correctly on every bash version.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CHECK="$SCRIPT_DIR/check-main-root-derivation.sh"
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  # shellcheck source=.gaia/scripts/check-main-root-derivation.sh
  source "$CHECK"
  FIXTURE_REPOS=()
}

teardown() {
  local d
  for d in "${FIXTURE_REPOS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  return 0
}

# make_fixture_repo <name>: a fresh, empty git repo under BATS_TEST_TMPDIR.
# Each test writes its own files into it before committing, so the fixture
# shape stays local to the test that needs it. Returns the repo path on
# stdout.
make_fixture_repo() {
  local name="$1"
  local dir="$BATS_TEST_TMPDIR/$name"
  mkdir -p "$dir"
  git init -q --initial-branch=main "$dir"
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name T
  git -C "$dir" config commit.gpgsign false
  FIXTURE_REPOS+=("$dir")
  printf '%s' "$dir"
}

commit_fixture() {
  local dir="$1"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m fixture
}

@test "structural: check-main-root-derivation.sh is executable" {
  [ -x "$CHECK" ]
}

@test "structural: sourcing the script defines gaia_check_main_root_derivation with no side effects" {
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    type gaia_check_main_root_derivation >/dev/null
    echo OK
  ' _ "$CHECK"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "real repo: all three scans are clean against tracked source" {
  run gaia_check_main_root_derivation "$REPO_ROOT"
  [ "$status" -eq 0 ]
  grep -qF "hand-rolled --git-common-dir uses outside the resolver: 0" <<<"$output" || return 1
  grep -qF "worktrees parameter-expansion string surgery found: 0" <<<"$output" || return 1
  grep -qF "worktree list --porcelain piped to a first-record reader: 0" <<<"$output" || return 1
}

@test "fixture: a bare --git-common-dir derivation in a consumer fails" {
  local repo
  repo="$(make_fixture_repo bad-common-dir)"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'common="$(git rev-parse --git-common-dir)"\n'
    printf 'main_root="$(dirname "$common")"\n'
  } >"$repo/consumer.sh"
  commit_fixture "$repo"
  run gaia_check_main_root_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "hand-rolled --git-common-dir uses outside the resolver: 1" <<<"$output" || return 1
  grep -qF "consumer.sh" <<<"$output" || return 1
}

@test "fixture: --git-common-dir mentioned only in a comment does not fail" {
  local repo
  repo="$(make_fixture_repo comment-common-dir)"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# this used to call git rev-parse --git-common-dir by hand\n'
    printf 'echo hi\n'
  } >"$repo/consumer.sh"
  commit_fixture "$repo"
  run gaia_check_main_root_derivation "$repo"
  [ "$status" -eq 0 ]
  grep -qF "hand-rolled --git-common-dir uses outside the resolver: 0" <<<"$output" || return 1
}

@test "fixture: --git-common-dir mentioned only in a markdown file does not fail" {
  local repo
  repo="$(make_fixture_repo md-common-dir)"
  printf 'Resolves main via `git rev-parse --git-common-dir`.\n' >"$repo/NOTES.md"
  commit_fixture "$repo"
  run gaia_check_main_root_derivation "$repo"
  [ "$status" -eq 0 ]
  grep -qF "hand-rolled --git-common-dir uses outside the resolver: 0" <<<"$output" || return 1
}

@test "fixture: --git-common-dir in a *.test.ts fixture does not fail" {
  local repo
  repo="$(make_fixture_repo test-common-dir)"
  printf "execFileSync('git', ['rev-parse', '--git-common-dir']);\n" >"$repo/consumer.test.ts"
  commit_fixture "$repo"
  run gaia_check_main_root_derivation "$repo"
  [ "$status" -eq 0 ]
  grep -qF "hand-rolled --git-common-dir uses outside the resolver: 0" <<<"$output" || return 1
}

@test "fixture: a worktrees parameter-expansion trim fails" {
  local repo
  repo="$(make_fixture_repo worktrees-surgery)"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'common="/repo/.claude/worktrees/foo/.git"\n'
    printf 'main_root="${common%%/.git/worktrees/*}"\n'
  } >"$repo/consumer.sh"
  commit_fixture "$repo"
  run gaia_check_main_root_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "worktrees parameter-expansion string surgery found: 1" <<<"$output" || return 1
  grep -qF "consumer.sh" <<<"$output" || return 1
}

@test "fixture: worktree list --porcelain piped to head -1 fails" {
  local repo
  repo="$(make_fixture_repo porcelain-head)"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'main_root=$(git worktree list --porcelain | head -1 | cut -d" " -f2)\n'
  } >"$repo/consumer.sh"
  commit_fixture "$repo"
  run gaia_check_main_root_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "worktree list --porcelain piped to a first-record reader: 1" <<<"$output" || return 1
  grep -qF "consumer.sh" <<<"$output" || return 1
}

@test "fixture: worktree list --porcelain piped to sed -n '1p' fails" {
  local repo
  repo="$(make_fixture_repo porcelain-sed)"
  {
    printf '#!/usr/bin/env bash\n'
    printf "git worktree list --porcelain \\\\\n"
    printf "  | sed -n '1p'\n"
  } >"$repo/consumer.sh"
  commit_fixture "$repo"
  run gaia_check_main_root_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "worktree list --porcelain piped to a first-record reader: 1" <<<"$output" || return 1
}

@test "fixture: worktree list --porcelain piped to a full awk parse does not fail" {
  local repo
  repo="$(make_fixture_repo porcelain-full-awk)"
  {
    printf '#!/usr/bin/env bash\n'
    printf "git -C \"\$main\" worktree list --porcelain | awk '\n"
    printf '  $1=="worktree"{ p=substr($0,10) }\n'
    printf "  \$1==\"\"{ if(p!=\"\") print p; p=\"\" }\n"
    printf "'\n"
  } >"$repo/consumer.sh"
  commit_fixture "$repo"
  run gaia_check_main_root_derivation "$repo"
  [ "$status" -eq 0 ]
  grep -qF "worktree list --porcelain piped to a first-record reader: 0" <<<"$output" || return 1
}

@test "fixture: a bad derivation inside a *.bats fixture does not fail" {
  local repo
  repo="$(make_fixture_repo bats-fixture)"
  {
    printf '#!/usr/bin/env bats\n'
    printf '@test "plants the defect" {\n'
    printf '  common="$(git rev-parse --git-common-dir)"\n'
    printf '}\n'
  } >"$repo/plant.bats"
  commit_fixture "$repo"
  run gaia_check_main_root_derivation "$repo"
  [ "$status" -eq 0 ]
  grep -qF "hand-rolled --git-common-dir uses outside the resolver: 0" <<<"$output" || return 1
}

@test "fixture: a clean repo with no derivation passes with all-zero counts" {
  local repo
  repo="$(make_fixture_repo clean)"
  printf '#!/usr/bin/env bash\necho hi\n' >"$repo/consumer.sh"
  commit_fixture "$repo"
  run gaia_check_main_root_derivation "$repo"
  [ "$status" -eq 0 ]
  grep -qF "hand-rolled --git-common-dir uses outside the resolver: 0" <<<"$output" || return 1
  grep -qF "worktrees parameter-expansion string surgery found: 0" <<<"$output" || return 1
  grep -qF "worktree list --porcelain piped to a first-record reader: 0" <<<"$output" || return 1
}
