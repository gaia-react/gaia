#!/usr/bin/env bats

# Adversarial suite for .gaia/tests/run-bats-parallel.sh, the hand-run parallel
# bats runner. The runner and .github/workflows/audit-ci-tests.yml consume the
# same partition from .gaia/tests/bats-shards.sh, the workflow one shard per
# matrix leg and the runner every shard at once, so the workflow never
# calls this script itself. The exit-code propagation this suite proves is
# load-bearing on both paths: a bug that greens a failing suite wedges nothing
# and lets everything through, which is the worse direction, and that same
# reasoning lives in the aggregator job (which depends on every shard leg
# succeeding to report the declared-required check) and in bats-shards.sh's own
# fail-closed rules (a shard resolving zero files, or a pinned entry gone
# missing, is an error rather than a silent green).
#
# NOTHING here ever forks bats, which is what lets this suite run inside
# .gaia/tests/lib/, the directory the lib shard runs it from, with no recursion
# and no meaningful contention. Most fixtures reach that by driving the runner
# through its --table seam with trivial commands (true, false, printf, sleep,
# rm); the table-shape tests read builtin_table() back out by sourcing the
# runner and ask bats-shards.sh for its shard ids only, never for a shard's
# files and never for a run.
#
# Every @test that runs the runner as a runner passes an explicit
# --log-dir "$BATS_TEST_TMPDIR", so nothing here can write into the log
# directory an outer live invocation is using. The exceptions are stated at
# their own tests: the table-shape tests never run a suite at all, and the
# default-log-directory test exists precisely to exercise the omitted flag and
# confines the runner's self-created directory with RUNNER_TEMP instead.
#
# The two fail-closed tests are the only ones that invoke the runner with no
# --table, and each runs a COPY of it from a scratch directory holding no
# .gaia/tests/bats-shards.sh. That working directory is the honest limit of
# those two checks: should a regression ever build rows despite an unreachable
# sharder, a row's repo-relative command field resolves to nothing there and
# the test reds harmlessly, where from the repo root it would fork a real shard
# from inside the one already running this suite.
#
# Assertion style per .claude/rules/bats-assertions.md: no bare mid-test
# [[ ... ]], POSIX [ ] and grep only, so a broken assertion still fails on
# macOS bash 3.2.

setup() {
  RUNNER="$BATS_TEST_DIRNAME/../run-bats-parallel.sh"
  SHARDER="$BATS_TEST_DIRNAME/../bats-shards.sh"
  TABLE="$BATS_TEST_TMPDIR/suites.tsv"
}

# Writes a suite table from triples of slug / label / command.
mk_table() {
  printf '%s\t%s\t%s\n' "$@" >"$TABLE"
}

# Writes an executable-by-`bash` fixture script, one body line per argument.
write_script() {
  script_path="$1"
  shift
  printf '%s\n' "$@" >"$script_path"
}

# Counts the runner's self-created default log directories under this test's
# tmpdir. A literal unmatched glob is not a directory, so an empty tree is 0.
count_default_dirs() {
  local n candidate
  n=0
  for candidate in "$BATS_TEST_TMPDIR"/bats-parallel.*; do
    if [ -d "$candidate" ]; then
      n=$((n + 1))
    fi
  done
  printf '%s\n' "$n"
}

@test "F1: a failing middle suite fails the run and is named in the failure summary" {
  mk_table \
    s1 'first suite' true \
    s2 'middle suite' false \
    s3 'third suite' true
  run bash "$RUNNER" --table "$TABLE" --log-dir "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ]
  summary=$(grep -F -- '::error::' <<<"$output")
  grep -qF -- 'middle suite' <<<"$summary"
  grep -qF -- 'first suite' <<<"$summary" && return 1
  grep -qF -- 'third suite' <<<"$summary" && return 1
  true
}

@test "F2: a failure in the first position, and separately in the last, both fail the run" {
  mk_table \
    s1 'alpha suite' false \
    s2 'beta suite' true \
    s3 'gamma suite' true
  run bash "$RUNNER" --table "$TABLE" --log-dir "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ]
  grep -qE '^::error::.*alpha suite' <<<"$output"

  mk_table \
    s1 'alpha suite' true \
    s2 'beta suite' true \
    s3 'gamma suite' false
  run bash "$RUNNER" --table "$TABLE" --log-dir "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ]
  grep -qE '^::error::.*gamma suite' <<<"$output"
}

@test "F3: three passing suites exit 0 with no error annotation" {
  mk_table \
    s1 'first suite' true \
    s2 'second suite' true \
    s3 'third suite' true
  run bash "$RUNNER" --table "$TABLE" --log-dir "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  grep -qF -- '::error::' <<<"$output" && return 1
  true
}

@test "F4: logs replay in table order, not completion order" {
  # Sleeps invert the two orders: the table is A, B, C and the suites finish
  # C, B, A. Replaying in completion order would emit MARK-C first.
  write_script "$BATS_TEST_TMPDIR/a.sh" 'sleep 0.6' "printf 'MARK-A\n'"
  write_script "$BATS_TEST_TMPDIR/b.sh" 'sleep 0.3' "printf 'MARK-B\n'"
  write_script "$BATS_TEST_TMPDIR/c.sh" "printf 'MARK-C\n'"
  mk_table \
    sa 'suite A' "bash $BATS_TEST_TMPDIR/a.sh" \
    sb 'suite B' "bash $BATS_TEST_TMPDIR/b.sh" \
    sc 'suite C' "bash $BATS_TEST_TMPDIR/c.sh"
  run bash "$RUNNER" --table "$TABLE" --log-dir "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  order=$(grep -o 'MARK-[ABC]' <<<"$output" | tr '\n' ' ')
  [ "$order" = "MARK-A MARK-B MARK-C " ]
}

@test "F5: a suite writing only to stderr has its bytes captured and replayed" {
  write_script "$BATS_TEST_TMPDIR/e.sh" "printf 'ONLY-ON-STDERR\n' >&2"
  mk_table se 'stderr suite' "bash $BATS_TEST_TMPDIR/e.sh"
  run bash "$RUNNER" --table "$TABLE" --log-dir "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  # The log file itself, not merely the combined output: bats' `run` merges the
  # runner's own stderr into $output, so an uncaptured suite's stderr would
  # still show up there and a bare $output grep would green a dropped `2>&1`.
  [ -f "$BATS_TEST_TMPDIR/se.log" ]
  grep -qF -- 'ONLY-ON-STDERR' "$BATS_TEST_TMPDIR/se.log"
  # And inside that suite's replay group, not loose in the stream.
  replayed=$(awk '/^::group::stderr suite$/ {g = 1; next} /^::endgroup::$/ {g = 0} g' <<<"$output")
  grep -qF -- 'ONLY-ON-STDERR' <<<"$replayed"
}

@test "F6: an empty table and a blank-lines-only table both exit 2, never green" {
  : >"$TABLE"
  run bash "$RUNNER" --table "$TABLE" --log-dir "$BATS_TEST_TMPDIR"
  [ "$status" -eq 2 ]
  grep -qF -- 'zero suites' <<<"$output"

  printf '\n   \n\t\n\n' >"$TABLE"
  run bash "$RUNNER" --table "$TABLE" --log-dir "$BATS_TEST_TMPDIR"
  [ "$status" -eq 2 ]
  grep -qF -- 'zero suites' <<<"$output"
}

@test "F7: a two-field row and an empty command field both exit 2 naming the row" {
  # A valid row rides along in both tables on purpose. A runner that skipped
  # malformed rows silently would otherwise be caught by the empty-table guard
  # instead of by this fixture, and the fixture would prove nothing.
  printf 'good\tgood suite\ttrue\nonlytwo\tfields\n' >"$TABLE"
  run bash "$RUNNER" --table "$TABLE" --log-dir "$BATS_TEST_TMPDIR"
  [ "$status" -eq 2 ]
  grep -qF -- 'malformed table row 2' <<<"$output"
  grep -qF -- 'onlytwo' <<<"$output"

  printf 'good\tgood suite\ttrue\nblankcmd\tblank command suite\t\n' >"$TABLE"
  run bash "$RUNNER" --table "$TABLE" --log-dir "$BATS_TEST_TMPDIR"
  [ "$status" -eq 2 ]
  grep -qF -- 'malformed table row 2' <<<"$output"
  grep -qF -- 'blankcmd' <<<"$output"
}

@test "F8: a log missing at replay time exits 2 rather than replaying nothing" {
  # The command field is word-split on whitespace, so this fixture needs a
  # space-free tmpdir. Assert that rather than silently mis-splitting.
  [ "$BATS_TEST_TMPDIR" = "${BATS_TEST_TMPDIR// /}" ]
  # The suite deletes its own log while its stdout fd is still open, so the log
  # is gone by replay time and the suite itself exits 0.
  mk_table selfdel 'self-deleting suite' "rm -f $BATS_TEST_TMPDIR/selfdel.log"
  run bash "$RUNNER" --table "$TABLE" --log-dir "$BATS_TEST_TMPDIR"
  [ "$status" -eq 2 ]
  grep -qF -- 'missing log' <<<"$output"
}

@test "T-A: the built-in table is one three-field row per shard id, with no quoted or globbing command" {
  # Reads the table out of the runner by sourcing it, which the runner's
  # sourcing guard makes side-effect free. No suite runs, so there is no log
  # directory for this test to point anywhere.
  run bash -c "source '$RUNNER'; builtin_table"
  [ "$status" -eq 0 ]
  expected_rows=$(bash "$SHARDER" shards | wc -l | tr -d ' ')
  [ "${#lines[@]}" -eq "$expected_rows" ]
  malformed=$(printf '%s\n' "$output" | awk -F'\t' 'NF != 3' | wc -l | tr -d ' ')
  [ "$malformed" -eq 0 ]
  # Pins the no-eval word-splitting precondition: a quote or a glob character in
  # a command field would be taken literally by `read -ra`.
  commands=$(printf '%s\n' "$output" | cut -f3)
  grep -q "['\"]" <<<"$commands" && return 1
  grep -q '[*?]' <<<"$commands" && return 1
  true
}

@test "T-B: every row names one real shard, its label matches, and the row set equals the shard set" {
  run bash -c "source '$RUNNER'; builtin_table"
  [ "$status" -eq 0 ]
  # A zero-status run proves nothing on its own: builtin_table returns 0 even
  # when the sharder dies, because printing nothing is how it fails closed.
  # Without this the loop below iterates zero times and the set equality
  # degenerates to "" = "", so the test would green over an empty table while
  # asserting nothing about the runner's rows.
  [ "${#lines[@]}" -gt 0 ]
  ids=''
  for row in "${lines[@]}"; do
    slug=$(printf '%s\n' "$row" | cut -f1)
    label=$(printf '%s\n' "$row" | cut -f2)
    cmd=$(printf '%s\n' "$row" | cut -f3)
    [ "$(printf '%s\n' "$cmd" | awk '{print $1, $2, $3}')" = 'bash .gaia/tests/bats-shards.sh run' ]
    id=$(printf '%s\n' "$cmd" | awk '{print $NF}')
    [ "$slug" = "$id" ]
    # The label is what the runner prints as the group header and in the
    # failure summary, so nothing else in this suite reads field 2.
    [ "$label" = "shard $slug" ]
    ids="$ids$id"$'\n'
  done
  # Equality in both directions: a superset would run a shard twice, a subset
  # would drop one and still green.
  [ "$(printf '%s' "$ids" | LC_ALL=C sort)" = "$(bash "$SHARDER" shards | LC_ALL=C sort)" ]
}

@test "T-C: table order follows the sharder's declared shard order" {
  run bash -c "source '$RUNNER'; builtin_table"
  [ "$status" -eq 0 ]
  # Unsorted, because the runner replays logs in table order and this is what
  # keeps that order predictable.
  ordered=$(printf '%s\n' "$output" | cut -f3 | awk '{print $NF}')
  # Same reason as T-B's row-count guard: an empty table would compare "" to ""
  # and green while pinning no order at all.
  [ -n "$ordered" ]
  [ "$ordered" = "$(bash "$SHARDER" shards)" ]
}

@test "T-D: a runner that cannot reach the sharder exits 2 rather than running a partial table" {
  dir="$BATS_TEST_TMPDIR/no-sharder"
  mkdir -p "$dir"
  cp "$RUNNER" "$dir/run-bats-parallel.sh"
  [ ! -e "$dir/bats-shards.sh" ]
  # The runner runs from $dir, where the command field's repo-relative
  # `.gaia/tests/bats-shards.sh` resolves to nothing. Should a regression ever
  # build rows here anyway, they fail harmlessly instead of forking a real
  # shard from inside the shard already running this suite.
  [ ! -e "$dir/.gaia" ]
  run bash -c "cd '$dir' && bash ./run-bats-parallel.sh --log-dir '$BATS_TEST_TMPDIR'"
  [ "$status" -eq 2 ]
  grep -qF -- 'zero suites' <<<"$output"
}

@test "T-E: a sharder that fails after printing ids exits 2 and contributes no rows" {
  dir="$BATS_TEST_TMPDIR/failing-sharder"
  mkdir -p "$dir"
  cp "$RUNNER" "$dir/run-bats-parallel.sh"
  # Prints plausible ids and then dies. A runner that streamed the lookup into
  # its rows would build two suites out of this and run them.
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" hooks-1 hooks-2\nexit 3\n' >"$dir/bats-shards.sh"
  [ ! -e "$dir/.gaia" ]
  run bash -c "cd '$dir' && bash ./run-bats-parallel.sh --log-dir '$BATS_TEST_TMPDIR'"
  [ "$status" -eq 2 ]
  grep -qF -- 'zero suites' <<<"$output"
}

@test "with no --log-dir the runner creates a fresh directory that is unique per invocation" {
  # The one @test that cannot pass --log-dir, because the omitted flag is what
  # it measures. RUNNER_TEMP confines the runner's self-created directory to
  # this test's tmpdir, so it still cannot touch an outer invocation's logs.
  export RUNNER_TEMP="$BATS_TEST_TMPDIR"
  mk_table s1 'only suite' true

  [ "$(count_default_dirs)" -eq 0 ]
  run bash "$RUNNER" --table "$TABLE"
  [ "$status" -eq 0 ]
  [ "$(count_default_dirs)" -eq 1 ]

  run bash "$RUNNER" --table "$TABLE"
  [ "$status" -eq 0 ]
  [ "$(count_default_dirs)" -eq 2 ]
}
