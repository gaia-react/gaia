#!/usr/bin/env bats
# Tests for .gaia/tests/whole-tree-invariants.sh: the one command that runs
# every check whose input is the whole tree.
#
# Four jobs, and the reason each is a test rather than a sentence.
#
# 1. Membership completeness. The runner carries a hardcoded member list, which
#    is the same fail-open shape it was written to close: a whole-tree checker
#    added later has no path that selects it, so nothing would notice it never
#    joined the set. This suite sweeps the five `.sh` naming families that have
#    produced a member and fails when a candidate appears in neither the member
#    table nor the excluded table, which makes every exclusion an answer someone
#    wrote down rather than an omission. The test body says why the `.bats`
#    family is out despite WTI_BATS naming a member from it.
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
#    does not already know it exists, so every instruction site a reader would
#    reach for has to name it. That claim is about this
#    repository and it is falsifiable, so it is a test.
#
# The aggregation tests run against a fixture tree of stubs rather than the real
# members. That is what keeps proving "a failing member fails the run" from
# costing the real set's ~40 seconds, and it is why the runner invokes members
# relative to the current directory. There is deliberately no "the real tree is
# clean" test here: each member already owns that in its own CI coverage, and
# adding ~40s to whichever shard holds this file would repack the weighted split
# for nothing -- the hazard the shard member is in the set to catch.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  RUNNER="$REPO_ROOT/.gaia/tests/whole-tree-invariants.sh"
  TMP=""
  # path_shim_without, for the bats --jobs backend-absence drives below.
  . "$BATS_TEST_DIRNAME/../helpers/path.sh"
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

  # Sweep every `.sh` naming family that has produced a member, not just
  # `check-*`. Every WTI_SCRIPTS entry in the runner that is not a
  # `.gaia/scripts/check-*.sh` path lives outside that one glob, so a
  # `check-*`-only sweep leaves the families they belong to unwatched: a checker
  # added there and left off the roster would join neither table and this test
  # would still pass.
  #
  # The `.bats` family is out on purpose, though WTI_BATS names a member from
  # it. The only glob that reaches it, .gaia/tests/lib/*.bats, enumerates every
  # ordinary suite in that directory, so the exclusion table would have to carry
  # an entry per suite saying nothing, which is a roster of a different kind and
  # a worse one. The single bats member is named directly in WTI_BATS instead.
  unaccounted=""
  for path in "$REPO_ROOT"/.gaia/scripts/check-*.sh \
              "$REPO_ROOT"/.gaia/scripts/audit-*-complete.sh \
              "$REPO_ROOT"/.gaia/scripts/lint-*.sh \
              "$REPO_ROOT"/.gaia/scripts/verify-*.sh \
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

@test "every instruction site names the runner" {
  # Three sites, because three are where a reader looks: the always-loaded rule,
  # the workflow page it points at, and the README of the directory the runner
  # lives in, which is where someone asking "what do I run pre-merge" lands.
  grep -Fq -- 'whole-tree-invariants.sh' "$REPO_ROOT/.claude/rules/pr-merge.md" || return 1
  grep -Fq -- 'whole-tree-invariants.sh' "$REPO_ROOT/wiki/concepts/PR Merge Workflow.md" || return 1
  grep -Fq -- 'whole-tree-invariants.sh' "$REPO_ROOT/.gaia/tests/README.md"
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
  # The observed member is the LAST of the whole list, which is the sole bats
  # member and so runs in the runner's second loop. Watching it alone therefore
  # says nothing about the first loop: an early exit confined to the script
  # members leaves this test's other three assertions all true. Counting what
  # actually ran is the assertion that spans both loops.
  total="$( bash "$RUNNER" --list | grep -c . )"
  reported="$( printf '%s\n' "$output" | grep -cE '^(PASS|FAIL)  ' )"
  [ "$reported" -eq "$total" ]
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

@test "a member failing in the first dispatch slot reds the run and every other member still reports" {
  fixture_tree
  # Dispatch order and replay order are independent (README.md FC-2 in this
  # plan): the runner forks the WTI_BATS member FIRST because it is the
  # pool's long pole, ahead of every WTI_SCRIPTS member. That is a different
  # slot from the REPLAY-order "first" the earlier test above already covers,
  # so a regression that loses the pool's own first fork needs its own drive.
  first_dispatched="$( bash "$RUNNER" --list | tail -1 )"
  total="$( bash "$RUNNER" --list | grep -c . )"
  stub_exits "$first_dispatched" 1

  run bash -c "cd '$TMP' && bash '$RUNNER'"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -Fq -- "FAIL  $first_dispatched"
  reported="$( printf '%s\n' "$output" | grep -cE '^(PASS|FAIL)  ' )"
  [ "$reported" -eq "$total" ]
}

@test "a member failing in the last dispatch slot reds the run and every other member still reports" {
  fixture_tree
  # The last WTI_SCRIPTS entry, not WTI_BATS: WTI_BATS dispatches first (see
  # the test above), so the last member the pool forks is the last line of
  # the WTI_SCRIPTS block. `sed '$d'` drops --list's trailing WTI_BATS line
  # portably (macOS `head` has no `-n -1`).
  last_dispatched="$( bash "$RUNNER" --list | sed '$d' | tail -1 )"
  total="$( bash "$RUNNER" --list | grep -c . )"
  stub_exits "$last_dispatched" 1

  run bash -c "cd '$TMP' && bash '$RUNNER'"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -Fq -- "FAIL  $last_dispatched"
  reported="$( printf '%s\n' "$output" | grep -cE '^(PASS|FAIL)  ' )"
  [ "$reported" -eq "$total" ]
}

@test "two members failing at once are both named" {
  fixture_tree
  # A bare `wait` regression collects only the last job's status and would
  # green one of these two; two failures at once is what that leaves no room
  # to hide behind a single-failure test.
  first="$( bash "$RUNNER" --list | head -1 )"
  last="$( bash "$RUNNER" --list | tail -1 )"
  stub_exits "$first" 1
  stub_exits "$last" 1

  errfile="$TMP/stderr.txt"
  outfile="$TMP/stdout.txt"
  bash -c "cd '$TMP' && bash '$RUNNER'" > "$outfile" 2> "$errfile" || true

  grep -Fq -- '2 member(s) failed:' "$errfile"
  grep -Fq -- "$first" "$errfile"
  grep -Fq -- "$last" "$errfile"
}

@test "stdout and stderr stay on separate streams per member" {
  fixture_tree
  # Captured through real redirection into two files, never through bats
  # `run`, which merges both streams into $output and so cannot see a `2>&1`
  # regression at all -- the same reason the existing failure-summary test
  # above avoids `run` for its own stream-split assertion.
  first="$( bash "$RUNNER" --list | head -1 )"
  printf '#!/usr/bin/env bash\nprintf "STDOUT-SENTINEL\\n"\nprintf "STDERR-SENTINEL\\n" >&2\nexit 0\n' > "$TMP/$first"

  outfile="$TMP/stdout.txt"
  errfile="$TMP/stderr.txt"
  bash -c "cd '$TMP' && bash '$RUNNER'" > "$outfile" 2> "$errfile" || true

  grep -Fq -- 'STDOUT-SENTINEL' "$outfile"
  grep -Fq -- 'STDOUT-SENTINEL' "$errfile" && return 1
  grep -Fq -- 'STDERR-SENTINEL' "$errfile"
  grep -Fq -- 'STDERR-SENTINEL' "$outfile" && return 1
  true
}

@test "a missing per-member log reds the member rather than passing it" {
  fixture_tree
  # The member deletes its own stdout log via WTI_LOG_DIR, the directory the
  # runner exports to every forked member for exactly this drive, even though
  # the member itself exits 0. The slug derivation mirrors slug_for() in the
  # runner (replace '/' with '_'); the test cannot source the runner to reuse
  # it directly, because sourcing it invokes main() unconditionally.
  first="$( bash "$RUNNER" --list | head -1 )"
  first_slug="$( printf '%s' "$first" | tr '/' '_' )"
  printf '#!/usr/bin/env bash\nrm -f "$WTI_LOG_DIR/%s.out"\nexit 0\n' "$first_slug" > "$TMP/$first"

  run bash -c "cd '$TMP' && bash '$RUNNER'"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -Fq -- "FAIL  $first"
  printf '%s\n' "$output" | grep -Fq -- 'missing log'
}

@test "a mismatched member count refuses to run rather than running stale" {
  # Drives the staleness lever from a scratch copy per README.md FC-2 in this
  # plan's task doc: never edit the live tree to prove a refusal.
  copy="$BATS_TEST_TMPDIR/whole-tree-invariants.sh"
  sed 's/^readonly WTI_SCRIPTS_COUNT_ASOF=.*/readonly WTI_SCRIPTS_COUNT_ASOF=999/' "$RUNNER" > "$copy"

  run bash "$copy"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -Fq -- 're-measure the runtime paragraph'
  # `|| true`: grep -c exits 1 on a zero count despite printing "0", and this
  # assertion's whole point is a zero count, so the bare assignment would abort
  # the test under bats' own set -e before the assertion below ever runs
  # (.claude/rules/bats-assertions.md).
  reported="$( printf '%s\n' "$output" | grep -cE '^(PASS|FAIL)  ' || true )"
  [ "$reported" -eq 0 ]
}

@test "the per-member log directory is removed when the run ends" {
  fixture_tree
  # RUNNER_TEMP is the runner's own knob for where it mints that directory, so
  # pointing it at a scratch dir makes the leftovers countable without going
  # near the shared /tmp. The failure this pins is not a wrong verdict: the
  # cleanup runs from an EXIT trap, the trap body expands its variable after
  # main() has returned, and a variable that is out of scope there aborts the
  # trap under the runner's `set -u`. The run still reports PASS for every
  # member, so nothing but this test distinguishes a cleaned run from one that
  # leaves its whole log directory behind on every invocation.
  scratch="$BATS_TEST_TMPDIR/runner-temp"
  mkdir -p "$scratch"

  run bash -c "cd '$TMP' && RUNNER_TEMP='$scratch' bash '$RUNNER'"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fq -- 'unbound variable' && return 1

  # `|| true`: grep -c exits 1 on the zero count this asserts
  # (.claude/rules/bats-assertions.md).
  leftover="$( find "$scratch" -maxdepth 1 -name 'whole-tree-invariants.*' | grep -c . || true )"
  [ "$leftover" -eq 0 ]
}

@test "WTI_JOBS=1 still runs every member and still reds a failure" {
  fixture_tree
  # The degenerate bound someone reaches for while debugging a fork/wait bug
  # has to be the same bounded-pool code as everyone else, not a silently
  # different serial path.
  first="$( bash "$RUNNER" --list | head -1 )"
  total="$( bash "$RUNNER" --list | grep -c . )"
  stub_exits "$first" 1

  run bash -c "cd '$TMP' && WTI_JOBS=1 bash '$RUNNER'"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -Fq -- "FAIL  $first"
  reported="$( printf '%s\n' "$output" | grep -cE '^(PASS|FAIL)  ' )"
  [ "$reported" -eq "$total" ]
}

@test "the fixture tree runs measurably faster forked than under WTI_JOBS=1" {
  # An instant stub finishes before fork/wait machinery could show a
  # difference either way, so every member gets a fixed delay here to make
  # overlap observable. This does not stand in for the real aggregate
  # (README.md FC-2b: the orchestrator takes that figure once, on the real
  # tree); it only proves the pool actually overlaps members rather than
  # serializing them under a new name.
  fixture_tree
  path=''
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
      *.bats) printf '#!/usr/bin/env bats\n\n@test "stub" {\n  sleep 0.2\n}\n' > "$TMP/$path" ;;
      *) printf '#!/usr/bin/env bash\nsleep 0.2\nexit 0\n' > "$TMP/$path" ;;
    esac
  done < <( bash "$RUNNER" --list )

  serial_start=$(date +%s)
  bash -c "cd '$TMP' && WTI_JOBS=1 bash '$RUNNER'" >/dev/null 2>&1
  serial_secs=$(( $(date +%s) - serial_start ))

  parallel_start=$(date +%s)
  bash -c "cd '$TMP' && bash '$RUNNER'" >/dev/null 2>&1
  parallel_secs=$(( $(date +%s) - parallel_start ))

  [ "$parallel_secs" -lt "$serial_secs" ]
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

@test "an unknown argument is refused rather than run" {
  run bash -c "cd '$REPO_ROOT' && bash '$RUNNER' --lst"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -Fq -- 'unknown argument'
  # The bad outcome is the runner treating a typo as no-argument and running the
  # whole set, so pin the absence of a run alongside the exit status.
  printf '%s\n' "$output" | grep -Fq -- 'all whole-tree invariants pass' && return 1
  true
}

@test "--help prints the usage and exits 0" {
  run bash -c "cd '$REPO_ROOT' && bash '$RUNNER' --help"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fq -- 'usage: bash .gaia/tests/whole-tree-invariants.sh'
}

# The tests below drive the WTI_BATS member's own --jobs invocation (this
# plan's task-bats-jobs-shards.md). A fake `bats` prepended onto PATH ahead
# of the real one, logging its own argv via BATS_ARGV_LOG (a fork/exec
# boundary, so it has to be exported, the same reason WTI_LOG_DIR above is),
# proves what this RUNNER decided to invoke without depending on a real
# `bats --jobs` run actually succeeding. A fake `parallel` alongside it
# only needs to exist for `command -v` to find, since nothing here asks it
# to run anything.
fake_bats_argv_logger() {
  local fakebin="$TMP/fakebin"
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >"$BATS_ARGV_LOG"\nexit 0\n' >"$fakebin/bats"
  chmod +x "$fakebin/bats"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$fakebin/parallel"
  chmod +x "$fakebin/parallel"
  printf '%s\n' "$fakebin"
}

@test "the shard-partition member is invoked under --jobs 8 when a backend is present, with no degradation notice" {
  fixture_tree
  fakebin="$(fake_bats_argv_logger)"
  argvlog="$TMP/argv.log"

  run bash -c "cd '$TMP' && PATH='$fakebin:$PATH' BATS_ARGV_LOG='$argvlog' bash '$RUNNER'"
  [ "$status" -eq 0 ]
  joined="$(tr '\n' ' ' <"$argvlog")"
  printf '%s\n' "$joined" | grep -Fq -- '--jobs 8 .gaia/tests/lib/audit-ci-shards.bats'
  # The paired half (this plan's task doc, criterion 6): a notice that
  # always fires is noise nobody learns to trust.
  printf '%s\n' "$output" | grep -Fq -- 'no GNU parallel or rush' && return 1
  true
}

@test "WTI_BATS_JOBS overrides the default job count passed to bats" {
  fixture_tree
  fakebin="$(fake_bats_argv_logger)"
  argvlog="$TMP/argv.log"

  run bash -c "cd '$TMP' && PATH='$fakebin:$PATH' BATS_ARGV_LOG='$argvlog' WTI_BATS_JOBS=3 bash '$RUNNER'"
  [ "$status" -eq 0 ]
  joined="$(tr '\n' ' ' <"$argvlog")"
  printf '%s\n' "$joined" | grep -Fq -- '--jobs 3 .gaia/tests/lib/audit-ci-shards.bats'
}

@test "a non-numeric WTI_BATS_JOBS falls back to the default rather than refusing" {
  fixture_tree
  fakebin="$(fake_bats_argv_logger)"
  argvlog="$TMP/argv.log"

  run bash -c "cd '$TMP' && PATH='$fakebin:$PATH' BATS_ARGV_LOG='$argvlog' WTI_BATS_JOBS=nope bash '$RUNNER'"
  [ "$status" -eq 0 ]
  joined="$(tr '\n' ' ' <"$argvlog")"
  printf '%s\n' "$joined" | grep -Fq -- '--jobs 8 .gaia/tests/lib/audit-ci-shards.bats'
}

@test "WTI_BATS_JOBS=1 still runs the shard-partition member and still reds a failure" {
  # The degenerate bound people reach for while debugging. Driven against
  # the real bats binary and a real backend, unlike the argv-capture tests
  # above, because this one is proving --jobs 1 actually still propagates a
  # failure through bats itself, not just that this runner asked for it.
  command -v parallel >/dev/null 2>&1 || command -v rush >/dev/null 2>&1 || skip "no bats --jobs backend on PATH"
  fixture_tree
  stub_exits '.gaia/tests/lib/audit-ci-shards.bats' 1

  run bash -c "cd '$TMP' && WTI_BATS_JOBS=1 bash '$RUNNER'"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -Fq -- 'FAIL  .gaia/tests/lib/audit-ci-shards.bats'
}

@test "no bats on PATH still fails the member, distinct from a merely-missing backend" {
  fixture_tree
  no_bats_path="$(path_shim_without bats)"

  run bash -c "cd '$TMP' && PATH='$no_bats_path' bash '$RUNNER'"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -Fq -- 'FAIL  .gaia/tests/lib/audit-ci-shards.bats'
  printf '%s\n' "$output" | grep -Fq -- 'bats not found on PATH'
}

@test "no parallel or rush on PATH: the member still runs serially, with a loud stderr notice naming both backends" {
  fixture_tree
  # Chained rather than a single call: path_shim_without takes one name, and
  # the second call has to build its shim over the PATH the first call
  # already produced, or the first tool it stripped would reappear.
  PATH="$(path_shim_without parallel)"
  no_backend_path="$(path_shim_without rush)"

  errfile="$TMP/stderr.txt"
  outfile="$TMP/stdout.txt"
  bash -c "cd '$TMP' && PATH='$no_backend_path' bash '$RUNNER'" >"$outfile" 2>"$errfile"
  status=$?

  [ "$status" -eq 0 ]
  grep -Fq -- 'PASS  .gaia/tests/lib/audit-ci-shards.bats' "$outfile"
  grep -Fq -- 'parallel' "$errfile"
  grep -Fq -- 'rush' "$errfile"
  grep -Fq -- 'brew install parallel' "$errfile"
}
