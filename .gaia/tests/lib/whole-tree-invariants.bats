#!/usr/bin/env bats
# Tests for .gaia/tests/whole-tree-invariants.sh: the one command that runs
# every check whose input is the whole tree.
#
# Four jobs, and the reason each is a test rather than a sentence.
#
# 1. Membership completeness. The runner carries a hardcoded member list, which
#    is the same fail-open shape it was written to close: a whole-tree checker
#    added later has no path that selects it, so nothing would notice it never
#    joined the set. This suite sweeps every naming family that has actually
#    produced a member and fails when a candidate appears in neither the member
#    table nor the excluded table, which makes every exclusion an answer someone
#    wrote down rather than an omission.
#
# 2. Aggregation. A runner that stops at the first failure, that quietly skips
#    a member whose path is gone, or that loses the rest of the set to a member
#    draining the loop's stdin, reports green in exactly the case it exists to
#    catch.
#
# 3. Argument handling. The runner documents one optional argument, so a second
#    one is a typo, and answering a typo with a success is how a caller comes to
#    believe a check ran.
#
# 4. Discoverability. The runner's whole value is being findable by someone who
#    does not already know it exists, so the two instruction sites that used to
#    describe the set by hand have to name it. That claim is about this
#    repository and it is falsifiable, so it is a test.
#
# The aggregation tests run against a fixture tree of stubs rather than the real
# members. That is what keeps proving "a failing member fails the run" from
# costing the real set's ~41 seconds, and it is why the runner invokes members
# relative to the current directory. There is deliberately no "the real tree is
# clean" test here: each member already owns that in its own CI coverage, and
# adding ~41s to whichever shard holds this file would repack the weighted split
# for nothing -- the hazard the shard member is in the set to catch.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  RUNNER="$REPO_ROOT/.gaia/tests/whole-tree-invariants.sh"
  TMP=""
}

teardown() {
  [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"
  return 0
}

# fixture_tree: a tmp tree holding a stub for every member the runner names,
# each passing. A `.bats` member gets a real one-test bats file, so the fixture
# exercises the same interpreter branch the real run takes.
fixture_tree() {
  TMP="$(mktemp -d -t whole-tree-invariants-XXXXXX)"
  local path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    mkdir -p "$TMP/$( dirname "$path" )"
    stub_exits "$path" 0
  done < <( bash "$RUNNER" --list )
}

# stub_exits <member-path> <status>: write one stub that exits <status>.
stub_exits() {
  case "$1" in
    *.bats) printf '#!/usr/bin/env bats\n\n@test "stub" {\n  [ %s -eq 0 ]\n}\n' "$2" > "$TMP/$1" ;;
    *) printf '#!/usr/bin/env bash\nexit %s\n' "$2" > "$TMP/$1" ;;
  esac
}

@test "every candidate checker is either a member or a documented exclusion" {
  run bash -c "cd '$REPO_ROOT' && bash '$RUNNER' --list"
  [ "$status" -eq 0 ]
  members="$output"

  run bash -c "cd '$REPO_ROOT' && bash '$RUNNER' --list-excluded"
  [ "$status" -eq 0 ]
  excluded="$output"

  # Sweep every naming family that has actually produced a member, not just
  # `check-*`. Four of the runner's own members (the two audit-*-complete
  # checks, lint-shipped-issue-refs, and shell-lint) live outside that one
  # glob, so a `check-*`-only sweep leaves the families they belong to
  # unwatched: a checker added there and left off the roster would join
  # neither table and this test would still pass.
  unaccounted=""
  for path in "$REPO_ROOT"/.gaia/scripts/check-*.sh \
              "$REPO_ROOT"/.gaia/scripts/audit-*-complete.sh \
              "$REPO_ROOT"/.gaia/scripts/lint-*.sh \
              "$REPO_ROOT"/.gaia/tests/*.sh; do
    [ -f "$path" ] || continue
    rel="${path#"$REPO_ROOT"/}"
    printf '%s\n' "$members" | grep -Fxq -- "$rel" && continue
    printf '%s\n' "$excluded" | grep -Fq -- "$rel|" && continue
    unaccounted="$unaccounted $rel"
  done

  [ -z "$unaccounted" ] || {
    printf 'unaccounted whole-tree check candidates:%s\n' "$unaccounted" >&2
    return 1
  }
}

@test "every exclusion carries a non-empty reason" {
  run bash -c "cd '$REPO_ROOT' && bash '$RUNNER' --list-excluded"
  [ "$status" -eq 0 ]

  bad=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    reason="${line#*|}"
    if [ "$reason" = "$line" ] || [ -z "$reason" ]; then
      bad="$bad $line"
    fi
  done <<< "$output"

  [ -z "$bad" ] || {
    printf 'exclusion with no reason:%s\n' "$bad" >&2
    return 1
  }
}

@test "every member path resolves in the real tree" {
  run bash -c "cd '$REPO_ROOT' && bash '$RUNNER' --list"
  [ "$status" -eq 0 ]

  missing=""
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ -f "$REPO_ROOT/$path" ] || missing="$missing $path"
  done <<< "$output"

  [ -z "$missing" ] || {
    printf 'member paths that do not exist:%s\n' "$missing" >&2
    return 1
  }
}

@test "both instruction sites name the runner" {
  grep -Fq -- 'whole-tree-invariants.sh' "$REPO_ROOT/.claude/rules/pr-merge.md" || return 1
  grep -Fq -- 'whole-tree-invariants.sh' "$REPO_ROOT/wiki/concepts/PR Merge Workflow.md"
}

@test "a tree where every member passes exits 0" {
  fixture_tree
  run bash -c "cd '$TMP' && bash '$RUNNER'"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fq -- 'all whole-tree invariants pass'
}

@test "one failing member fails the run and the members after it still run" {
  fixture_tree
  # Both ends come from the runner's own list rather than two literals: pinned
  # names make the assertion depend on their relative positions, so reordering
  # the roster, which nothing else here constrains, could put the observed
  # member BEFORE the failing one. The test would keep its name and stay green
  # against exactly the early-exit regression it exists to catch.
  first="$( bash "$RUNNER" --list | head -1 )"
  last="$( bash "$RUNNER" --list | tail -1 )"
  stub_exits "$first" 1

  run bash -c "cd '$TMP' && bash '$RUNNER'"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -Fq -- "FAIL  $first"
  printf '%s\n' "$output" | grep -Fq -- "PASS  $last"
  printf '%s\n' "$output" | grep -Fq -- '1 member(s) failed'
}

@test "a member that reads stdin does not swallow the members after it" {
  fixture_tree
  # Each member loop reads its list from a heredoc, so an unredirected member
  # inherits it as stdin. Draining stdin then consumes the remaining member
  # paths, the loop ends early, and the run reports every member passing having
  # invoked one. The failure leaves no FAIL line and no skip notice, so only a
  # count of what actually ran can see it.
  first="$( bash "$RUNNER" --list | head -1 )"
  last="$( bash "$RUNNER" --list | tail -1 )"
  total="$( bash "$RUNNER" --list | grep -c . )"
  printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' > "$TMP/$first"

  run bash -c "cd '$TMP' && bash '$RUNNER'"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fq -- "PASS  $last"
  reported="$( printf '%s\n' "$output" | grep -cE '^(PASS|FAIL)  ' )"
  [ "$reported" -eq "$total" ]
}

@test "a failing bats member fails the run" {
  fixture_tree
  stub_exits '.gaia/tests/lib/audit-ci-shards.bats' 1

  run bash -c "cd '$TMP' && bash '$RUNNER'"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -Fq -- 'FAIL  .gaia/tests/lib/audit-ci-shards.bats'
}

@test "a missing member path fails the run rather than being skipped" {
  fixture_tree
  rm -f "$TMP/.gaia/scripts/check-audit-key-callers.sh"

  run bash -c "cd '$TMP' && bash '$RUNNER'"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -Fq -- 'FAIL  .gaia/scripts/check-audit-key-callers.sh'
}

@test "a second argument is refused rather than discarded" {
  run bash -c "cd '$REPO_ROOT' && bash '$RUNNER' --list extra-arg"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -Fq -- 'too many arguments'
}

@test "the failure summary header travels with its member names" {
  fixture_tree
  first="$( bash "$RUNNER" --list | head -1 )"
  stub_exits "$first" 1

  # Captured with the streams kept apart on purpose: bats' own `run` merges
  # them into $output, which is exactly why a header on one stream and its
  # names on the other is invisible to every other test here. A caller reading
  # one stream must not end on a dangling colon, nor collect bare paths with no
  # header.
  errfile="$TMP/stderr.txt"
  outfile="$TMP/stdout.txt"
  bash -c "cd '$TMP' && bash '$RUNNER'" > "$outfile" 2> "$errfile" || true

  grep -Fq -- 'member(s) failed:' "$outfile" && return 1
  grep -Fq -- 'member(s) failed:' "$errfile" || return 1
  grep -Fq -- "$first" "$errfile"
}
