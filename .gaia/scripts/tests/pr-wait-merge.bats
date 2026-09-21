#!/usr/bin/env bats
# Tests for .gaia/scripts/pr-wait-merge.sh, the shipped merge wait.
#
# The script polls a pull request to a terminal state and exits on a distinct
# code per verdict. Everything it reads comes from `gh`, so the whole surface
# is driven through a `gh` stub placed on PATH ahead of any real one: a stub
# makes the arms hermetic and deterministic, including the ones a live tracker
# cannot be made to exhibit on demand (a `CONFLICTING` base, a cancelled
# required check, a `gh pr checks` that has registered nothing yet).
#
# `--interval 0` throughout, so the suite does not spend the script's real
# thirty-second spacing. The interval is a flag rather than an environment
# override precisely so the tests can do this without a back door in the
# script.
#
# The suite's job is to prove each verdict can be REACHED and that the
# keep-waiting rules actually keep waiting. The keep-waiting half is the one
# worth the fixtures: each rule exists to stop the wait abandoning a merge that
# is about to land, so a rule that quietly stopped waiting would show up as a
# TIMEOUT-shaped exit nobody looks at twice. Each is asserted by driving the
# state that must NOT end the wait and pinning the TIMEOUT outcome.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md. `run`
# captures status instead of letting a non-zero exit abort the test body, and
# `$status` is compared with POSIX `[ ]`.

setup() {
  THIS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO_ROOT="$(cd "$THIS_DIR/../../.." && pwd)"
  WAIT="$REPO_ROOT/.gaia/scripts/pr-wait-merge.sh"
  TMP="$(mktemp -d -t pr-wait-merge-XXXXXX)"
  # Absolute, because the gh-absent test below empties PATH, and `env` could
  # then not find the interpreter itself.
  BASH_ABS="$(command -v bash)"
}

teardown() {
  [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf "$TMP"
  return 0
}

# stub_gh <view-tsv> [checks-answer]
#
# Answers `gh pr view` with <view-tsv>, the tab-separated `state<TAB>mergeable`
# line the script's own --jq filter produces. With [checks-answer] given,
# `gh pr checks` prints it; omitted, `gh pr checks` prints nothing and exits
# non-zero, which is what gh really does before any check has registered.
#
# Every call is logged to argv.log, so a test can assert HOW MANY reads the
# script made. That is the only way to tell "it broke out of the loop" from
# "it ran every attempt and timed out", since both can print the same token.
stub_gh() {
  mkdir -p "$TMP/bin"
  printf '%s' "$1" >"$TMP/view.tsv"
  if [ "$#" -ge 2 ]; then
    printf '%s\n' "$2" >"$TMP/checks.txt"
  else
    rm -f "$TMP/checks.txt"
  fi
  cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DIR/argv.log"
case "$2" in
  view) cat "$STUB_DIR/view.tsv"; printf '\n' ;;
  checks)
    [ -f "$STUB_DIR/checks.txt" ] || exit 1
    cat "$STUB_DIR/checks.txt"
    ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$TMP/bin/gh"
  STUB_DIR="$TMP"
  export STUB_DIR
  PATH="$TMP/bin:$PATH"
  export PATH
}

# The number of `gh pr view` calls the stub logged.
view_calls() {
  grep -c 'pr view' "$TMP/argv.log" 2>/dev/null || printf '0\n'
}

tsv() {
  printf '%s\t%s' "$1" "$2"
}

# --- each verdict is reachable ------------------------------------------------

@test "MERGED exits 0 and prints the token" {
  stub_gh "$(tsv MERGED CLEAN)"
  run bash "$WAIT" --pr 7 --interval 0
  [ "$status" -eq 0 ]
  grep -qF -- 'MERGED' <<<"$output"
}

@test "CONFLICTING exits 3 and points at the conflict repair" {
  stub_gh "$(tsv OPEN CONFLICTING)"
  run bash "$WAIT" --pr 7 --interval 0
  [ "$status" -eq 3 ]
  grep -qF -- 'CONFLICTING' <<<"$output"
  grep -qF -- 'Conflict found mid-wait' <<<"$output"
}

@test "a failed required check exits 4" {
  stub_gh "$(tsv OPEN MERGEABLE)" 2
  run bash "$WAIT" --pr 7 --interval 0
  [ "$status" -eq 4 ]
  grep -qF -- 'CHECK_FAILED' <<<"$output"
}

@test "a still-pending merge spends its bound and exits 5" {
  stub_gh "$(tsv OPEN MERGEABLE)" 0
  run bash "$WAIT" --pr 7 --attempts 3 --interval 0
  [ "$status" -eq 5 ]
  grep -qF -- 'TIMEOUT' <<<"$output"
}

@test "TIMEOUT says the merge may still land, rather than reporting a failure" {
  stub_gh "$(tsv OPEN MERGEABLE)" 0
  run bash "$WAIT" --pr 7 --attempts 1 --interval 0
  [ "$status" -eq 5 ]
  grep -qF -- 'This is not a failure' <<<"$output"
}

# --- a terminal verdict stops the loop, it does not merely report -------------
#
# Without this the MERGED test above passes on a script that reads the state
# five times and reports the first answer, which would spend four needless
# round trips per wait and, with a real interval, two extra minutes.

@test "MERGED breaks out rather than running the whole bound" {
  stub_gh "$(tsv MERGED CLEAN)"
  run bash "$WAIT" --pr 7 --attempts 5 --interval 0
  [ "$status" -eq 0 ]
  [ "$(view_calls)" -eq 1 ]
}

@test "CONFLICTING breaks out rather than running the whole bound" {
  stub_gh "$(tsv OPEN CONFLICTING)"
  run bash "$WAIT" --pr 7 --attempts 5 --interval 0
  [ "$status" -eq 3 ]
  [ "$(view_calls)" -eq 1 ]
}

@test "a pending merge really does read the state once per attempt" {
  stub_gh "$(tsv OPEN MERGEABLE)" 0
  run bash "$WAIT" --pr 7 --attempts 4 --interval 0
  [ "$status" -eq 5 ]
  [ "$(view_calls)" -eq 4 ]
}

# --- the keep-waiting rules ---------------------------------------------

@test "mergeable UNKNOWN keeps waiting, it is neither clean nor conflicting" {
  stub_gh "$(tsv OPEN UNKNOWN)" 0
  run bash "$WAIT" --pr 7 --attempts 2 --interval 0
  [ "$status" -eq 5 ]
  grep -qF -- 'TIMEOUT' <<<"$output"
}

@test "a null mergeable is read as UNKNOWN, not as a conflict" {
  # gh answers `null` before it has computed mergeability; the script's jq
  # filter maps that to the literal UNKNOWN, so the tab-separated line the
  # stub returns here is what the real gh produces in that window.
  stub_gh "$(tsv OPEN UNKNOWN)" 0
  run bash "$WAIT" --pr 7 --attempts 1 --interval 0
  [ "$status" -eq 5 ]
}

@test "gh pr checks exiting non-zero with no output keeps waiting" {
  # No second argument: the stub's `checks` arm exits 1 with nothing on stdout,
  # which is what gh does before any check registers. Reading that as a failure
  # would abandon every merge queued before CI starts.
  stub_gh "$(tsv OPEN MERGEABLE)"
  run bash "$WAIT" --pr 7 --attempts 2 --interval 0
  [ "$status" -eq 5 ]
  grep -qF -- 'TIMEOUT' <<<"$output"
}

@test "zero failed required checks keeps waiting" {
  stub_gh "$(tsv OPEN MERGEABLE)" 0
  run bash "$WAIT" --pr 7 --attempts 1 --interval 0
  [ "$status" -eq 5 ]
}

@test "a non-numeric checks answer keeps waiting rather than ending the wait" {
  stub_gh "$(tsv OPEN MERGEABLE)" 'some gh error text'
  run bash "$WAIT" --pr 7 --attempts 1 --interval 0
  [ "$status" -eq 5 ]
}

@test "an unreadable gh answer keeps waiting rather than reading as a state" {
  # The view arm prints an empty line, so the script's split finds no tab. It
  # must blank both halves rather than let the whole line stand in for `state`.
  stub_gh '' 0
  run bash "$WAIT" --pr 7 --attempts 1 --interval 0
  [ "$status" -eq 5 ]
}

# --- MERGED wins over a conflict on the same read -----------------------------

@test "a merged PR reporting CONFLICTING still exits MERGED" {
  # GitHub can leave a stale mergeability on a PR that has already merged.
  # Reading the conflict first would report a failure on a landed merge, and
  # the caller would skip its cleanup.
  stub_gh "$(tsv MERGED CONFLICTING)"
  run bash "$WAIT" --pr 7 --interval 0
  [ "$status" -eq 0 ]
  grep -qF -- 'MERGED' <<<"$output"
}

# --- usage errors are refusals, never verdicts --------------------------------
#
# Each of these must exit 2 rather than any verdict code. A bad bound silently
# defaulting is the specific hazard: a caller's deliberate 20-attempt release
# wait becoming a 5-attempt one shows up only as a TIMEOUT on a merge that was
# going to land.

@test "a missing --pr is a usage error" {
  stub_gh "$(tsv MERGED CLEAN)"
  run bash "$WAIT" --interval 0
  [ "$status" -eq 2 ]
  grep -qF -- '--pr is required' <<<"$output"
}

@test "a non-numeric --pr is a usage error" {
  stub_gh "$(tsv MERGED CLEAN)"
  run bash "$WAIT" --pr abc --interval 0
  [ "$status" -eq 2 ]
}

@test "a non-numeric --attempts is a usage error, not a silent default" {
  stub_gh "$(tsv MERGED CLEAN)"
  run bash "$WAIT" --pr 7 --attempts zero --interval 0
  [ "$status" -eq 2 ]
  grep -qF -- '--attempts' <<<"$output"
}

@test "a zero --attempts is a usage error" {
  stub_gh "$(tsv MERGED CLEAN)"
  run bash "$WAIT" --pr 7 --attempts 0 --interval 0
  [ "$status" -eq 2 ]
}

@test "a negative --interval is a usage error" {
  stub_gh "$(tsv MERGED CLEAN)"
  run bash "$WAIT" --pr 7 --interval -5
  [ "$status" -eq 2 ]
}

@test "a flag with no value is a usage error" {
  stub_gh "$(tsv MERGED CLEAN)"
  run bash "$WAIT" --pr
  [ "$status" -eq 2 ]
}

@test "an unrecognized argument is a usage error" {
  stub_gh "$(tsv MERGED CLEAN)"
  run bash "$WAIT" --pr 7 --nope
  [ "$status" -eq 2 ]
}

@test "--help exits 0 and prints the usage" {
  run bash "$WAIT" --help
  [ "$status" -eq 0 ]
  grep -qF -- '--attempts' <<<"$output"
}

# --- gh absent is a refusal, not a verdict ------------------------------------

@test "no gh on PATH refuses rather than reporting a verdict" {
  # An empty PATH: the script's own `command -v gh` must be what fails, and it
  # must say so rather than timing out against a gh that is not there.
  run env PATH="$TMP/empty" "$BASH_ABS" "$WAIT" --pr 7 --interval 0
  [ "$status" -eq 2 ]
  grep -qF -- 'gh is not on PATH' <<<"$output"
  grep -qF -- 'not a verdict' <<<"$output"
}
