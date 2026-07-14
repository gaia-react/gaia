#!/usr/bin/env bats
#
# Bats suite for .gaia/scripts/gh-artifact-lib.sh, the shared breadcrumb lib
# for the GitHub pull-request artifact a run produced. Sourced, not executed:
# every test sources the lib in setup() and calls its functions directly.
#
# Assertion style note (`.claude/rules/bats-assertions.md`): macOS's system
# `/bin/bash` (3.2) does not fail a bats @test on a false bare `[[ ... ]]`
# that isn't the test's last command, so non-final assertions below use
# POSIX `[ ]`, `grep -qF`, or an explicit `return 1`, never a bare mid-test
# `[[ ]]` and never a non-final `!`-negation.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  LIB="$SCRIPT_DIR/gh-artifact-lib.sh"
  # shellcheck source=.gaia/scripts/gh-artifact-lib.sh
  source "$LIB"
  unset GAIA_GH_ARTIFACT_CACHE_DIR
}

# ========== source-time purity ==========

# ---------- 1 ----------
@test "sourcing the lib has no side effects: succeeds under set -u with no git repo and no external PATH" {
  scratch="$BATS_TEST_TMPDIR/no-side-effects"
  mkdir -p "$scratch"
  run bash -c "cd '$scratch' && PATH='' && set -u && source '$LIB' && echo sourced-ok"
  [ "$status" -eq 0 ]
  grep -qF "sourced-ok" <<<"$output"
  [ -z "$(ls -A "$scratch")" ]
}

# ========== gaia_gh_artifact_cache_dir ==========

# ---------- 2 ----------
@test "gaia_gh_artifact_cache_dir: GAIA_GH_ARTIFACT_CACHE_DIR test seam wins" {
  GAIA_GH_ARTIFACT_CACHE_DIR=/x/y
  export GAIA_GH_ARTIFACT_CACHE_DIR
  run gaia_gh_artifact_cache_dir
  [ "$status" -eq 0 ]
  [ "$output" = "/x/y" ]
}

# ---------- 3 ----------
@test "gaia_gh_artifact_cache_dir: inside a real repo, echoes <repo-root>/.gaia/local/cache" {
  repo="$BATS_TEST_TMPDIR/repo3"
  mkdir -p "$repo"
  git init -q "$repo"
  repo_abs="$(cd "$repo" && pwd)"
  out="$(cd "$repo" && gaia_gh_artifact_cache_dir)"
  [ "$out" = "$repo_abs/.gaia/local/cache" ]
}

# ---------- 4 ----------
@test "gaia_gh_artifact_cache_dir: worktree-safe, resolves the MAIN checkout's cache dir" {
  main="$BATS_TEST_TMPDIR/wtmain"
  linked="$BATS_TEST_TMPDIR/wtlinked"
  mkdir -p "$main"
  git init -q "$main"
  git -C "$main" -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m init
  git -C "$main" worktree add -q -b feat-wt "$linked" >/dev/null
  # pwd -P: macOS resolves /var -> /private/var inside `git rev-parse`, and
  # the function's output comes back through that canonical form, so the
  # comparison side must canonicalize too (mirrors create-worktree.bats).
  main_abs="$(cd "$main" && pwd -P)"
  wt_abs="$(cd "$linked" && pwd -P)"
  out="$(cd "$linked" && gaia_gh_artifact_cache_dir)"
  [ "$out" = "$main_abs/.gaia/local/cache" ]
  [ "$out" != "$wt_abs/.gaia/local/cache" ]
}

# ---------- 5 ----------
@test "gaia_gh_artifact_cache_dir: outside any git repo, echoes nothing and returns 0" {
  plain="$BATS_TEST_TMPDIR/no-git"
  mkdir -p "$plain"
  run bash -c "cd '$plain' && source '$LIB' && gaia_gh_artifact_cache_dir"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ========== gaia_gh_artifact_parse_url ==========

# ---------- 6 ----------
@test "gaia_gh_artifact_parse_url: parses the first anchored PR URL, number is a JSON integer" {
  blob=$'some preamble\nOpening a pull request:\nhttps://github.com/gaia-react/gaia/pull/712\ntrailer text\n'
  run gaia_gh_artifact_parse_url "$blob"
  [ "$status" -eq 0 ]
  [ "$output" = '{"type":"pr","number":712,"repo":"gaia-react/gaia"}' ]
  jq -e '.number | type == "number"' >/dev/null 2>&1 <<<"$output" || return 1
}

# ---------- 7 ----------
@test "gaia_gh_artifact_parse_url: rejects issue URLs, gitlab host, http scheme, non-numeric number, unsafe owner" {
  run gaia_gh_artifact_parse_url 'https://github.com/owner/name/issues/415'
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run gaia_gh_artifact_parse_url 'https://gitlab.com/owner/name/pull/1'
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run gaia_gh_artifact_parse_url 'http://github.com/owner/name/pull/1'
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run gaia_gh_artifact_parse_url 'https://github.com/owner/name/pull/abc'
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run gaia_gh_artifact_parse_url 'https://github.com/o;rm -rf //n/pull/1'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- 8 ----------
@test "gaia_gh_artifact_parse_url: injection canary, no command execution and no match" {
  cd "$BATS_TEST_TMPDIR" || return 1
  bad='https://github.com/o$(touch CANARY)/n/pull/1'
  run gaia_gh_artifact_parse_url "$bad"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  if [ -e "$BATS_TEST_TMPDIR/CANARY" ]; then
    return 1
  fi
}

# ---------- 9 ----------
@test "gaia_gh_artifact_parse_url: when two PR URLs are present, the first wins" {
  blob=$'https://github.com/first-org/first-repo/pull/1\nhttps://github.com/second-org/second-repo/pull/2'
  run gaia_gh_artifact_parse_url "$blob"
  [ "$status" -eq 0 ]
  [ "$output" = '{"type":"pr","number":1,"repo":"first-org/first-repo"}' ]
}

# ========== gaia_gh_artifact_write ==========

# ---------- 10 ----------
@test "gaia_gh_artifact_write: a valid write has exactly the FC-1 key set" {
  bc="$BATS_TEST_TMPDIR/write-valid.json"
  run gaia_gh_artifact_write "$bc" 712 "gaia-react/gaia" "spec-040-command-cost-telemetry" "sess-abc"
  [ "$status" -eq 0 ]
  [ -f "$bc" ]
  [ "$(jq -r 'keys | @csv' "$bc")" = '"branch","number","repo","session_id","ts","type"' ]
  [ "$(jq -r '.type' "$bc")" = "pr" ]
  jq -e '.number | type == "number"' >/dev/null 2>&1 <"$bc" || return 1
  ts_val="$(jq -r '.ts' "$bc")"
  case "$ts_val" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) return 1 ;;
  esac
}

# ---------- 11 ----------
@test "gaia_gh_artifact_write: empty branch refuses and writes nothing" {
  bc="$BATS_TEST_TMPDIR/write-nobranch.json"
  run gaia_gh_artifact_write "$bc" 712 "gaia-react/gaia" "" "sess-abc"
  [ "$status" -ne 0 ]
  [ ! -e "$bc" ]
}

# ---------- 12 ----------
@test "gaia_gh_artifact_write: empty session_id refuses and writes nothing" {
  bc="$BATS_TEST_TMPDIR/write-nosession.json"
  run gaia_gh_artifact_write "$bc" 712 "gaia-react/gaia" "some-branch" ""
  [ "$status" -ne 0 ]
  [ ! -e "$bc" ]
}

# ---------- 13 ----------
@test "gaia_gh_artifact_write: a repo outside the safe class refuses and writes nothing" {
  bc1="$BATS_TEST_TMPDIR/write-badrepo1.json"
  run gaia_gh_artifact_write "$bc1" 712 "o;rm -rf /" "some-branch" "sess-abc"
  [ "$status" -ne 0 ]
  [ ! -e "$bc1" ]

  bc2="$BATS_TEST_TMPDIR/write-badrepo2.json"
  run gaia_gh_artifact_write "$bc2" 712 "owner/na me" "some-branch" "sess-abc"
  [ "$status" -ne 0 ]
  [ ! -e "$bc2" ]
}

# ---------- 14 ----------
@test "gaia_gh_artifact_write: a non-positive-integer number refuses and writes nothing" {
  bc1="$BATS_TEST_TMPDIR/write-badnum1.json"
  run gaia_gh_artifact_write "$bc1" "1x" "gaia-react/gaia" "some-branch" "sess-abc"
  [ "$status" -ne 0 ]
  [ ! -e "$bc1" ]

  bc2="$BATS_TEST_TMPDIR/write-badnum2.json"
  run gaia_gh_artifact_write "$bc2" "" "gaia-react/gaia" "some-branch" "sess-abc"
  [ "$status" -ne 0 ]
  [ ! -e "$bc2" ]

  bc3="$BATS_TEST_TMPDIR/write-badnum3.json"
  run gaia_gh_artifact_write "$bc3" "-3" "gaia-react/gaia" "some-branch" "sess-abc"
  [ "$status" -ne 0 ]
  [ ! -e "$bc3" ]
}

# ---------- 15 ----------
@test "gaia_gh_artifact_write: a second write overwrites, last writer wins" {
  bc="$BATS_TEST_TMPDIR/write-overwrite.json"
  run gaia_gh_artifact_write "$bc" 100 "gaia-react/gaia" "branch-one" "sess-one"
  [ "$status" -eq 0 ]
  run gaia_gh_artifact_write "$bc" 200 "gaia-react/gaia" "branch-two" "sess-two"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.number' "$bc")" -eq 200 ]
  [ "$(jq -r '.branch' "$bc")" = "branch-two" ]
  # exactly one JSON object left in the file, not two concatenated (jq's
  # writer is not required to be single-line; FC-1's own example is
  # pretty-printed, so "one object" is checked structurally, not by wc -l)
  [ "$(jq -s 'length' "$bc")" -eq 1 ]
}

# ---------- 16 ----------
@test "gaia_gh_artifact_write: a repo name with legal dot/dash characters succeeds" {
  bc="$BATS_TEST_TMPDIR/write-dotdash.json"
  run gaia_gh_artifact_write "$bc" 5 "my-org/my.repo" "some-branch" "sess-abc"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.repo' "$bc")" = "my-org/my.repo" ]
}

# ========== gaia_gh_artifact_read ==========

# ---------- 17 ----------
@test "gaia_gh_artifact_read: session_id and branch match, returns the type/number/repo triple" {
  bc="$BATS_TEST_TMPDIR/read-valid.json"
  gaia_gh_artifact_write "$bc" 712 "gaia-react/gaia" "spec-040-command-cost-telemetry" "sess-abc"
  run gaia_gh_artifact_read "$bc" "sess-abc" "spec-040-command-cost-telemetry"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'keys | @csv' <<<"$output")" = '"number","repo","type"' ]
  [ "$(jq -r '.type' <<<"$output")" = "pr" ]
  [ "$(jq -r '.number' <<<"$output")" -eq 712 ]
  [ "$(jq -r '.repo' <<<"$output")" = "gaia-react/gaia" ]
}

# ---------- 18 ----------
@test "gaia_gh_artifact_read: never deletes the breadcrumb" {
  bc="$BATS_TEST_TMPDIR/read-nodelete.json"
  gaia_gh_artifact_write "$bc" 712 "gaia-react/gaia" "some-branch" "sess-abc"
  gaia_gh_artifact_read "$bc" "sess-abc" "some-branch" >/dev/null
  [ -f "$bc" ]
}

# ---------- 19 ----------
@test "gaia_gh_artifact_read: reading twice returns identical output" {
  bc="$BATS_TEST_TMPDIR/read-twice.json"
  gaia_gh_artifact_write "$bc" 42 "gaia-react/gaia" "some-branch" "sess-xyz"
  first="$(gaia_gh_artifact_read "$bc" "sess-xyz" "some-branch")"
  second="$(gaia_gh_artifact_read "$bc" "sess-xyz" "some-branch")"
  [ -n "$first" ]
  [ "$first" = "$second" ]
}

# ---------- 20 ----------
@test "gaia_gh_artifact_read: branch mismatch echoes nothing" {
  bc="$BATS_TEST_TMPDIR/read-branchmismatch.json"
  gaia_gh_artifact_write "$bc" 42 "gaia-react/gaia" "branch-a" "sess-xyz"
  run gaia_gh_artifact_read "$bc" "sess-xyz" "branch-b"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- 21 ----------
@test "gaia_gh_artifact_read: session mismatch echoes nothing" {
  bc="$BATS_TEST_TMPDIR/read-sessionmismatch.json"
  gaia_gh_artifact_write "$bc" 42 "gaia-react/gaia" "branch-a" "sess-xyz"
  run gaia_gh_artifact_read "$bc" "sess-other" "branch-a"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- 22 ----------
@test "gaia_gh_artifact_read: a ts older than the TTL echoes nothing" {
  old="$BATS_TEST_TMPDIR/read-old.json"
  printf '{"type":"pr","number":1,"repo":"gaia-react/gaia","branch":"branch-a","session_id":"sess-xyz","ts":"2020-01-01T00:00:00Z"}' >"$old"
  run gaia_gh_artifact_read "$old" "sess-xyz" "branch-a"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  fresh="$BATS_TEST_TMPDIR/read-fresh-tinyttl.json"
  gaia_gh_artifact_write "$fresh" 1 "gaia-react/gaia" "branch-a" "sess-xyz"
  run gaia_gh_artifact_read "$fresh" "sess-xyz" "branch-a" 0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- 23 ----------
@test "gaia_gh_artifact_read: a ts more than 60s in the future echoes nothing" {
  future_ts="$(date -u -v+2H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  if [ -z "$future_ts" ]; then
    future_ts="$(date -u -d '+2 hours' +%Y-%m-%dT%H:%M:%SZ)"
  fi
  future="$BATS_TEST_TMPDIR/read-future.json"
  printf '{"type":"pr","number":1,"repo":"gaia-react/gaia","branch":"branch-a","session_id":"sess-xyz","ts":"%s"}' "$future_ts" >"$future"
  run gaia_gh_artifact_read "$future" "sess-xyz" "branch-a"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- 24 ----------
@test "gaia_gh_artifact_read: missing/empty/malformed/array/missing-number inputs all echo nothing" {
  run gaia_gh_artifact_read "$BATS_TEST_TMPDIR/does-not-exist.json" "sess-xyz" "branch-a"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  empty="$BATS_TEST_TMPDIR/read-empty.json"
  : >"$empty"
  run gaia_gh_artifact_read "$empty" "sess-xyz" "branch-a"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  garbage="$BATS_TEST_TMPDIR/read-garbage.json"
  printf 'not json at all {{{' >"$garbage"
  run gaia_gh_artifact_read "$garbage" "sess-xyz" "branch-a"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  arr="$BATS_TEST_TMPDIR/read-array.json"
  printf '[1,2,3]' >"$arr"
  run gaia_gh_artifact_read "$arr" "sess-xyz" "branch-a"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  now_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  missing_num="$BATS_TEST_TMPDIR/read-missingnum.json"
  printf '{"type":"pr","repo":"gaia-react/gaia","branch":"branch-a","session_id":"sess-xyz","ts":"%s"}' "$now_ts" >"$missing_num"
  run gaia_gh_artifact_read "$missing_num" "sess-xyz" "branch-a"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- 25 ----------
@test "gaia_gh_artifact_read: jq unavailable on PATH echoes nothing and returns 0" {
  bc="$BATS_TEST_TMPDIR/read-nojq.json"
  gaia_gh_artifact_write "$bc" 1 "gaia-react/gaia" "branch-a" "sess-xyz"
  saved_path="$PATH"
  # shellcheck disable=SC2123 # deliberately blank PATH to make jq unfindable; restored right after the call
  PATH=""
  run gaia_gh_artifact_read "$bc" "sess-xyz" "branch-a"
  PATH="$saved_path"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
