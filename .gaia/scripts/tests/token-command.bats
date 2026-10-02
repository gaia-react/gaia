#!/usr/bin/env bats
#
# Requires Bats >= 1.5.0.
bats_require_minimum_version 1.5.0
#
# Executable oracle for `.gaia/scripts/token-tally.sh --action command` (SPEC-040
# plan FC-4/FC-5/FC-6/FC-7): the one `kind: "command"` cost record each of the
# maintenance commands appends per run, its optional GitHub-artifact
# pass-through, and the same `github` field arriving on `kind: "execute"` via
# the breadcrumb `.claude/hooks/capture-gh-artifact.sh` writes.
#
# Drives the REAL token-tally.sh and gh-artifact-lib.sh; never a mock.
#
# Fixtures reused (both hand-computed elsewhere -- see token-tally.bats's own
# header comment -- never derived by running the helper):
#   fixtures/token-tally/projects (session fixturesession0001): the anchor
#     fixture, used only to give --action command a real main transcript so
#     it is not marked partial. None of this suite's assertions depend on its
#     token totals; the `command`/`run_id`/`github` fields are structural.
#   fixtures/token-tally/multimodel/projects (session fixturemultimodel0001):
#     carries real `.message.model` usage, so it genuinely prices under the
#     default rate table ($0.01) -- needed to make test 26 (an unresolvable
#     --rate-table degrading to "cost unavailable") a real negative rather
#     than a fixture artifact (the anchor fixture carries no `.message.model`,
#     so its `by_model` is always empty and it always prices "unavailable"
#     regardless of --rate-table).
#   fixtures/token-tally/auditreview/projects (session fixtureauditreview0001):
#     the only fixture with a recorded code-review-audit window, needed to
#     exercise --action review in test 29.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md. Uses `jq -e`
# (own exit code) alongside POSIX `[ ... ]` and `grep -q`.

setup() {
  # Isolate pricing from the developer's real rate table and the network.
  export GAIA_RATES_STATE_DIRECTORY="$BATS_TEST_TMPDIR/rates-state"
  export GAIA_RATES_FEED_DISABLE=1
  SCRIPT_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$SCRIPT_DIRECTORY/token-tally.sh"
  GH_ARTIFACT_LIBRARY="$SCRIPT_DIRECTORY/gh-artifact-lib.sh"
  FIXTURE_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures/token-tally" && pwd)"

  ANCHOR="$FIXTURE_DIRECTORY/projects"                 # the shared transcript fixture
  ANCHOR_SESSION="fixturesession0001"

  LEDGER="$BATS_TEST_TMPDIR/ledger.jsonl"
  CACHE="$BATS_TEST_TMPDIR/cache"        # ISOLATED: never the developer's live cache
  mkdir -p "$CACHE"
}

# ---------- shared helpers (file-scope, mirrors token-review.bats's ledger_field()) ----------

last_row() { tail -n 1 "$LEDGER"; }

# make_execute_repo <repo_directory> <branch>: a throwaway git repo checked out on <branch>
# with one commit, so `git branch --show-current` inside it is deterministic
# regardless of the machine's init.defaultBranch config.
make_execute_repo() {
  local repo_directory="$1" branch="$2"
  mkdir -p "$repo_directory"
  git init -q "$repo_directory"
  git -C "$repo_directory" checkout -q -b "$branch"
  git -C "$repo_directory" -c user.email=gaia-test@example.com -c user.name="GAIA Test" \
    commit -q --allow-empty -m init
}

# run_execute <repo_directory> <session_id> <ledger>: drives --action execute from
# inside <repo_directory> (so GIT_BRANCH resolves to that repo's checked-out branch)
# against the shared isolated $CACHE.
run_execute() {
  local repo_directory="$1" session_id="$2" ledger="$3"
  ( cd "$repo_directory" && bash "$SCRIPT" --action execute --plan-id PLAN-777 \
      --plan-slug telemetry-oracle --out-dir "$repo_directory/out" --session-id "$session_id" \
      --projects-root "$ANCHOR" --ledger "$ledger" --cache-dir "$CACHE" )
}

# assert_github_absent_and_not_partial <ledger> <github-flags...>: runs
# --action command with the given (incomplete/invalid) --github-* flags and
# returns 1 if github leaked into the row or partial got set, 0 otherwise.
assert_github_absent_and_not_partial() {
  local ledger="$1"
  shift
  bash "$SCRIPT" --action command --command gaia-audit "$@" \
    --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$ledger" \
    >/dev/null 2>&1
  local exit_status=$?
  [ "$exit_status" -eq 0 ] || return 1
  local record
  record="$(tail -n 1 "$ledger")"
  jq -e 'has("github")' >/dev/null 2>&1 <<<"$record" && return 1
  [ "$(jq -r '.partial' <<<"$record")" = "false" ] || return 1
  return 0
}

# ================= The record's identity and shape =================

# ---------- 1 ----------
@test "1: --action command produces exactly one kind:command row with the base field set, exit 0" {
  run bash "$SCRIPT" --action command --command gaia-audit \
    --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  [ -f "$LEDGER" ]
  [ "$(wc -l < "$LEDGER" | tr -d ' ')" -eq 1 ]

  record="$(last_row)"
  [ "$(jq -r '.kind' <<<"$record")" = "command" ]
  [ "$(jq -r '.command' <<<"$record")" = "gaia-audit" ]
  [ "$(jq -r '.spec_id' <<<"$record")" = "null" ]
  [ "$(jq -r '.plan_id' <<<"$record")" = "null" ]
  [ "$(jq -r '.plan_slug' <<<"$record")" = "null" ]
  [ "$(jq -r '.partial' <<<"$record")" = "false" ]
  [ "$(jq -r '.seq' <<<"$record")" -eq 0 ]
  [ "$(jq -r '.final' <<<"$record")" = "true" ]
}

# ---------- 2 ----------
@test "2: --action command writes no cost.json sidecar even when --out-dir is passed" {
  run bash "$SCRIPT" --action command --command gaia-audit \
    --out-dir "$BATS_TEST_TMPDIR/out2" \
    --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  [ -e "$BATS_TEST_TMPDIR/out2/cost.json" ] && return 1
  [ "$(wc -l < "$LEDGER" | tr -d ' ')" -eq 1 ]
}

# ---------- 3 ----------
@test "3: a generated run_id matches <slug>-<YYYYMMDDTHHMMSSZ>-<4 lowercase hex>" {
  run bash "$SCRIPT" --action command --command gaia-audit \
    --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  run_id="$(jq -r '.run_id' <<<"$(last_row)")"
  case "$run_id" in
    gaia-audit-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) echo "run_id does not match the frozen shape: $run_id" >&2; return 1 ;;
  esac
}

# ---------- 4 ----------
@test "4: two explicit distinct --run-id values stay distinct on their own rows (never asserting collision-freedom of generated ids)" {
  run bash "$SCRIPT" --action command --command gaia-audit \
    --run-id "gaia-audit-20260714T020000Z-aaaa" \
    --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" --action command --command gaia-audit \
    --run-id "gaia-audit-20260714T020000Z-bbbb" \
    --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  [ "$(wc -l < "$LEDGER" | tr -d ' ')" -eq 2 ]
  ids="$(jq -r '.run_id' "$LEDGER" | tr '\n' ',')"
  [ "$ids" = "gaia-audit-20260714T020000Z-aaaa,gaia-audit-20260714T020000Z-bbbb," ]
}

# ---------- 5 ----------
@test "5: two invocations of the same command append two rows, never overwriting one" {
  run bash "$SCRIPT" --action command --command gaia-debt \
    --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" --action command --command gaia-debt \
    --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  [ "$(wc -l < "$LEDGER" | tr -d ' ')" -eq 2 ]
  [ "$(jq -c 'select(.kind == "command")' "$LEDGER" | wc -l | tr -d ' ')" -eq 2 ]
}

# ================= --command validation =================

# ---------- 6 ----------
@test "6: an unrecognized --command value is carried through verbatim and marks partial" {
  run bash "$SCRIPT" --action command --command not-a-real-command \
    --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  record="$(last_row)"
  [ "$(jq -r '.command' <<<"$record")" = "not-a-real-command" ]
  [ "$(jq -r '.partial' <<<"$record")" = "true" ]
}

# ---------- 7 ----------
@test "7: an absent --command writes command:null and marks partial" {
  run bash "$SCRIPT" --action command \
    --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  record="$(last_row)"
  [ "$(jq -r '.command' <<<"$record")" = "null" ]
  [ "$(jq -r '.partial' <<<"$record")" = "true" ]
}

# ---------- 8 ----------
@test "8: every recognized --command value yields partial:false (closed set, looped)" {
  for command_name in gaia-audit gaia-debt gaia-fitness gaia-forensics gaia-harden gaia-residue gaia-wiki; do
    OWN_LEDGER="$BATS_TEST_TMPDIR/recognized-$command_name.jsonl"
    run bash "$SCRIPT" --action command --command "$command_name" \
      --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$OWN_LEDGER"
    [ "$status" -eq 0 ]
    partial="$(jq -r '.partial' "$OWN_LEDGER")"
    if [ "$partial" != "false" ]; then
      echo "command $command_name unexpectedly marked partial" >&2
      return 1
    fi
    recorded_command="$(jq -r '.command' "$OWN_LEDGER")"
    if [ "$recorded_command" != "$command_name" ]; then
      echo "command $command_name round-tripped as $recorded_command" >&2
      return 1
    fi
  done
}

# ================= The github object (pass-through) =================

# ---------- 9 ----------
@test "9: --github-type pr pass-through carries an integer number and the exact repo" {
  run bash "$SCRIPT" --action command --command gaia-audit \
    --github-type pr --github-number 712 --github-repo gaia-react/gaia \
    --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  record="$(last_row)"
  [ "$(jq -c '.github' <<<"$record")" = '{"type":"pr","number":712,"repo":"gaia-react/gaia"}' ]
  jq -e '.github.number | type == "number"' >/dev/null 2>&1 <<<"$record" || return 1
}

# ---------- 10 ----------
@test "10: --github-type issue pass-through carries the exact repo the run passes, not a hardcoded one" {
  run bash "$SCRIPT" --action command --command gaia-forensics \
    --github-type issue --github-number 415 --github-repo gaia-react/gaia \
    --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  record="$(last_row)"
  [ "$(jq -r '.github.type' <<<"$record")" = "issue" ]
  [ "$(jq -r '.github.repo' <<<"$record")" = "gaia-react/gaia" ]

  # A DIFFERENT repo than the one this checkout runs in: proves genuine
  # pass-through rather than a constant that happens to match gaia-react/gaia.
  run bash "$SCRIPT" --action command --command gaia-forensics \
    --github-type issue --github-number 9 --github-repo someone-else/other-repo \
    --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  other_record="$(last_row)"
  [ "$(jq -r '.github.repo' <<<"$other_record")" = "someone-else/other-repo" ]
}

# ---------- 11 ----------
@test "11: no --github-* flags at all omits the github key entirely, partial stays false" {
  run bash "$SCRIPT" --action command --command gaia-audit \
    --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  record="$(last_row)"
  jq -e 'has("github")' >/dev/null 2>&1 <<<"$record" && return 1
  [ "$(jq -r '.partial' <<<"$record")" = "false" ]
}

# ---------- 12 ----------
@test "12: an incomplete github flag set (missing one of type/number/repo) omits github, never marks partial" {
  assert_github_absent_and_not_partial "$BATS_TEST_TMPDIR/inc1.jsonl" \
    --github-type pr --github-number 712 \
    || { echo "missing --github-repo leaked github or set partial" >&2; return 1; }
  assert_github_absent_and_not_partial "$BATS_TEST_TMPDIR/inc2.jsonl" \
    --github-type pr --github-repo gaia-react/gaia \
    || { echo "missing --github-number leaked github or set partial" >&2; return 1; }
  assert_github_absent_and_not_partial "$BATS_TEST_TMPDIR/inc3.jsonl" \
    --github-number 712 --github-repo gaia-react/gaia \
    || { echo "missing --github-type leaked github or set partial" >&2; return 1; }
}

# ---------- 13 ----------
@test "13: invalid --github-type/--github-number/--github-repo values each omit github, never mark partial" {
  assert_github_absent_and_not_partial "$BATS_TEST_TMPDIR/inv1.jsonl" \
    --github-type merge --github-number 712 --github-repo gaia-react/gaia \
    || { echo "invalid --github-type leaked github or set partial" >&2; return 1; }
  assert_github_absent_and_not_partial "$BATS_TEST_TMPDIR/inv2.jsonl" \
    --github-type pr --github-number 0 --github-repo gaia-react/gaia \
    || { echo "--github-number 0 leaked github or set partial" >&2; return 1; }
  assert_github_absent_and_not_partial "$BATS_TEST_TMPDIR/inv3.jsonl" \
    --github-type pr --github-number -3 --github-repo gaia-react/gaia \
    || { echo "negative --github-number leaked github or set partial" >&2; return 1; }
  assert_github_absent_and_not_partial "$BATS_TEST_TMPDIR/inv4.jsonl" \
    --github-type pr --github-number 1x --github-repo gaia-react/gaia \
    || { echo "alpha-suffixed --github-number leaked github or set partial" >&2; return 1; }
  assert_github_absent_and_not_partial "$BATS_TEST_TMPDIR/inv5.jsonl" \
    --github-type pr --github-number 712 --github-repo no-slash \
    || { echo "slash-less --github-repo leaked github or set partial" >&2; return 1; }
}

# ---------- 14 ----------
@test "14: shell-metacharacter --github-repo values never execute; github is omitted (UAT-014)" {
  cd "$BATS_TEST_TMPDIR"

  run bash "$SCRIPT" --action command --command gaia-audit \
    --github-type pr --github-number 712 --github-repo 'o$(touch CANARY)/n' \
    --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  record="$(last_row)"
  jq -e 'has("github")' >/dev/null 2>&1 <<<"$record" && return 1
  [ -e "$BATS_TEST_TMPDIR/CANARY" ] && return 1
  [ -e CANARY ] && return 1

  run bash "$SCRIPT" --action command --command gaia-audit \
    --github-type pr --github-number 712 --github-repo 'o;id/n' \
    --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  other_record="$(last_row)"
  jq -e 'has("github")' >/dev/null 2>&1 <<<"$other_record" && return 1
  [ -e "$BATS_TEST_TMPDIR/CANARY" ] && return 1
  [ -e CANARY ] && return 1
  return 0
}

# ---------- 15 ----------
@test "15: --action command reads no breadcrumb, even a valid one matching this session AND branch sitting in --cache-dir" {
  . "$GH_ARTIFACT_LIBRARY"
  # The breadcrumb's branch MUST match the branch the run itself is checked
  # out on (make_execute_repo, not an arbitrary literal): otherwise this assertion
  # would pass for the wrong reason (branch mismatch) even if --action command
  # were mistakenly changed to read the breadcrumb, and never actually catch
  # that regression.
  REPO="$BATS_TEST_TMPDIR/repo15"
  BRANCH="feature/telemetry-15"
  make_execute_repo "$REPO" "$BRANCH"
  breadcrumb_path="$(gaia_gh_artifact_path "$CACHE" "$BRANCH")"
  gaia_gh_artifact_write "$breadcrumb_path" 712 "gaia-react/gaia" "$BRANCH" "$ANCHOR_SESSION"
  [ -f "$breadcrumb_path" ]

  run bash -c "cd '$REPO' && bash '$SCRIPT' --action command --command gaia-audit --cache-dir '$CACHE' \
    --session-id '$ANCHOR_SESSION' --projects-root '$ANCHOR' --ledger '$LEDGER'"
  [ "$status" -eq 0 ]
  record="$(last_row)"
  jq -e 'has("github")' >/dev/null 2>&1 <<<"$record" && return 1
  return 0
}

# ================= The github object on execute (breadcrumb, read-only) =================

# ---------- 16 ----------
@test "16: execute -- session_id and branch both match the breadcrumb, github is present" {
  . "$GH_ARTIFACT_LIBRARY"
  REPO="$BATS_TEST_TMPDIR/repo16"
  BRANCH="feature/telemetry-16"
  SESSION_ID="exec-session-16"
  make_execute_repo "$REPO" "$BRANCH"
  gaia_gh_artifact_write "$(gaia_gh_artifact_path "$CACHE" "$BRANCH")" 712 "gaia-react/gaia" "$BRANCH" "$SESSION_ID"

  run run_execute "$REPO" "$SESSION_ID" "$LEDGER"
  [ "$status" -eq 0 ]
  record="$(last_row)"
  [ "$(jq -c '.github' <<<"$record")" = '{"type":"pr","number":712,"repo":"gaia-react/gaia"}' ]
}

# ---------- 17 ----------
@test "17: the breadcrumb file survives an execute read" {
  . "$GH_ARTIFACT_LIBRARY"
  REPO="$BATS_TEST_TMPDIR/repo17"
  BRANCH="feature/telemetry-17"
  SESSION_ID="exec-session-17"
  make_execute_repo "$REPO" "$BRANCH"
  breadcrumb_path="$(gaia_gh_artifact_path "$CACHE" "$BRANCH")"
  gaia_gh_artifact_write "$breadcrumb_path" 712 "gaia-react/gaia" "$BRANCH" "$SESSION_ID"

  run run_execute "$REPO" "$SESSION_ID" "$LEDGER"
  [ "$status" -eq 0 ]
  [ -f "$breadcrumb_path" ]
}

# ---------- 18 ----------
@test "18: two execute runs both carry github; final flips from the first row to the second" {
  . "$GH_ARTIFACT_LIBRARY"
  REPO="$BATS_TEST_TMPDIR/repo18"
  BRANCH="feature/telemetry-18"
  SESSION_ID="exec-session-18"
  make_execute_repo "$REPO" "$BRANCH"
  gaia_gh_artifact_write "$(gaia_gh_artifact_path "$CACHE" "$BRANCH")" 712 "gaia-react/gaia" "$BRANCH" "$SESSION_ID"

  run run_execute "$REPO" "$SESSION_ID" "$LEDGER"
  [ "$status" -eq 0 ]
  git -C "$REPO" -c user.email=gaia-test@example.com -c user.name="GAIA Test" \
    commit -q --allow-empty -m "second commit"
  run run_execute "$REPO" "$SESSION_ID" "$LEDGER"
  [ "$status" -eq 0 ]

  [ "$(wc -l < "$LEDGER" | tr -d ' ')" -eq 2 ]
  [ "$(jq -c 'select(.github.number == 712)' "$LEDGER" | wc -l | tr -d ' ')" -eq 2 ]
  first_row_final="$(sed -n '1p' "$LEDGER" | jq -r '.final')"
  second_row_final="$(sed -n '2p' "$LEDGER" | jq -r '.final')"
  [ "$first_row_final" = "false" ]
  [ "$second_row_final" = "true" ]
}

# ---------- 19 ----------
@test "19: execute -- branch mismatch omits github" {
  . "$GH_ARTIFACT_LIBRARY"
  REPO="$BATS_TEST_TMPDIR/repo19"
  SESSION_ID="exec-session-19"
  make_execute_repo "$REPO" "feature/actual-branch-19"
  # Written at the path keyed by the REPO's real branch (what the reader looks
  # up), with the BODY's branch field deliberately set to a different value --
  # isolates the read-side body-mismatch guard (gaia_gh_artifact_read's own
  # branch check) from the filename keying, which is a separate mechanism.
  gaia_gh_artifact_write "$(gaia_gh_artifact_path "$CACHE" "feature/actual-branch-19")" \
    712 "gaia-react/gaia" "feature/different-branch-19" "$SESSION_ID"

  run run_execute "$REPO" "$SESSION_ID" "$LEDGER"
  [ "$status" -eq 0 ]
  record="$(last_row)"
  jq -e 'has("github")' >/dev/null 2>&1 <<<"$record" && return 1
  return 0
}

# ---------- 20 ----------
@test "20: execute -- session_id mismatch omits github" {
  . "$GH_ARTIFACT_LIBRARY"
  REPO="$BATS_TEST_TMPDIR/repo20"
  BRANCH="feature/telemetry-20"
  make_execute_repo "$REPO" "$BRANCH"
  gaia_gh_artifact_write "$(gaia_gh_artifact_path "$CACHE" "$BRANCH")" 712 "gaia-react/gaia" "$BRANCH" \
    "some-other-session-20"

  run run_execute "$REPO" "exec-session-20" "$LEDGER"
  [ "$status" -eq 0 ]
  record="$(last_row)"
  jq -e 'has("github")' >/dev/null 2>&1 <<<"$record" && return 1
  return 0
}

# ---------- 21 ----------
@test "21: execute -- a ts older than the TTL omits github" {
  . "$GH_ARTIFACT_LIBRARY"
  REPO="$BATS_TEST_TMPDIR/repo21"
  BRANCH="feature/telemetry-21"
  SESSION_ID="exec-session-21"
  make_execute_repo "$REPO" "$BRANCH"
  breadcrumb_path="$(gaia_gh_artifact_path "$CACHE" "$BRANCH")"
  gaia_gh_artifact_write "$breadcrumb_path" 712 "gaia-react/gaia" "$BRANCH" "$SESSION_ID"

  # The production writer always stamps "now"; there is no --ts seam, so aging
  # the breadcrumb past the 86400s default TTL means patching ONLY `ts` after
  # the fact (via a captured variable, never redirecting jq into its own input
  # file, which would truncate it before jq reads it).
  old_timestamp="$(jq -rn '(now - 90000) | gmtime | strftime("%Y-%m-%dT%H:%M:%SZ")')"
  updated="$(jq --arg timestamp "$old_timestamp" '.ts = $timestamp' "$breadcrumb_path")"
  printf '%s\n' "$updated" >"$breadcrumb_path"

  run run_execute "$REPO" "$SESSION_ID" "$LEDGER"
  [ "$status" -eq 0 ]
  record="$(last_row)"
  jq -e 'has("github")' >/dev/null 2>&1 <<<"$record" && return 1
  return 0
}

# ---------- 22 ----------
@test "22: execute -- no breadcrumb at all omits github, partial unchanged, exit 0" {
  REPO="$BATS_TEST_TMPDIR/repo22"
  BRANCH="feature/telemetry-22"
  make_execute_repo "$REPO" "$BRANCH"

  LEDGER_WITH_BREADCRUMB="$BATS_TEST_TMPDIR/l22-with.jsonl"
  LEDGER_WITHOUT_BREADCRUMB="$BATS_TEST_TMPDIR/l22-without.jsonl"

  . "$GH_ARTIFACT_LIBRARY"
  breadcrumb_path="$(gaia_gh_artifact_path "$CACHE" "$BRANCH")"
  gaia_gh_artifact_write "$breadcrumb_path" 712 "gaia-react/gaia" "$BRANCH" \
    "exec-session-22"
  run run_execute "$REPO" "exec-session-22" "$LEDGER_WITH_BREADCRUMB"
  [ "$status" -eq 0 ]
  partial_with="$(jq -r '.partial' "$LEDGER_WITH_BREADCRUMB")"

  rm -f "$breadcrumb_path"
  run run_execute "$REPO" "exec-session-22" "$LEDGER_WITHOUT_BREADCRUMB"
  [ "$status" -eq 0 ]
  record="$(tail -n 1 "$LEDGER_WITHOUT_BREADCRUMB")"
  jq -e 'has("github")' >/dev/null 2>&1 <<<"$record" && return 1
  [ "$(jq -r '.partial' <<<"$record")" = "$partial_with" ]
}

# ---------- 23 ----------
@test "23: execute -- --cache-dir genuinely roots the read; a breadcrumb elsewhere is never seen" {
  . "$GH_ARTIFACT_LIBRARY"
  REPO="$BATS_TEST_TMPDIR/repo23"
  BRANCH="feature/telemetry-23"
  SESSION_ID="exec-session-23"
  make_execute_repo "$REPO" "$BRANCH"

  ELSEWHERE="$BATS_TEST_TMPDIR/elsewhere-cache-23"
  mkdir -p "$ELSEWHERE"
  gaia_gh_artifact_write "$(gaia_gh_artifact_path "$ELSEWHERE" "$BRANCH")" 712 "gaia-react/gaia" "$BRANCH" "$SESSION_ID"

  EMPTY="$BATS_TEST_TMPDIR/empty-cache-23"
  mkdir -p "$EMPTY"
  run bash -c "cd '$REPO' && bash '$SCRIPT' --action execute --plan-id PLAN-777 \
    --plan-slug telemetry-oracle --out-dir '$REPO/out' --session-id '$SESSION_ID' \
    --projects-root '$ANCHOR' --ledger '$LEDGER' --cache-dir '$EMPTY'"
  [ "$status" -eq 0 ]
  record="$(last_row)"
  jq -e 'has("github")' >/dev/null 2>&1 <<<"$record" && return 1
  return 0
}

# ---------- 24 ----------
@test "24: execute -- a row written before the breadcrumb exists is never back-filled (single-phase precondition)" {
  . "$GH_ARTIFACT_LIBRARY"
  REPO="$BATS_TEST_TMPDIR/repo24"
  BRANCH="feature/telemetry-24"
  SESSION_ID="exec-session-24"
  make_execute_repo "$REPO" "$BRANCH"

  # No breadcrumb yet: the run's only row is written with no github. This
  # models a single-commit-phase plan whose one commit precedes `gh pr
  # create` -- FC-6 precondition 1 -- which is correct behavior, not a bug.
  run run_execute "$REPO" "$SESSION_ID" "$LEDGER"
  [ "$status" -eq 0 ]
  record_before="$(last_row)"
  jq -e 'has("github")' >/dev/null 2>&1 <<<"$record_before" && return 1

  # gh pr create happens AFTER that row was already appended.
  gaia_gh_artifact_write "$(gaia_gh_artifact_path "$CACHE" "$BRANCH")" 712 "gaia-react/gaia" "$BRANCH" "$SESSION_ID"

  # The already-written row is a static ledger line: nothing re-reads or
  # rewrites it, so it is byte-identical and still carries no github.
  record_after="$(last_row)"
  [ "$record_after" = "$record_before" ]
  jq -e 'has("github")' >/dev/null 2>&1 <<<"$record_after" && return 1
  return 0
}

# ================= The readout (FC-7) =================

# ---------- 25 ----------
@test "25: --action command's stdout is exactly one Cost: line, no per-bucket breakdown" {
  run bash "$SCRIPT" --action command --command gaia-audit \
    --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
  grep -Eq '^Cost: ~[0-9]+\.[0-9]M tokens(, .*)?$' <<<"$output" || return 1
  grep -qF 'Fresh input:' <<<"$output" && return 1
  grep -qF 'Cache write:' <<<"$output" && return 1
  grep -qF 'Cache read:' <<<"$output" && return 1
  grep -qF 'Output:' <<<"$output" && return 1
  grep -qF 'Total:' <<<"$output" && return 1
  grep -qF 'Elapsed:' <<<"$output" && return 1
  return 0
}

# ---------- 26 ----------
@test "26: an unresolvable --rate-table renders 'cost unavailable' in place of the dollar figure" {
  MULTIMODEL="$FIXTURE_DIRECTORY/multimodel/projects"
  run bash "$SCRIPT" --action command --command gaia-audit \
    --rate-table "$BATS_TEST_TMPDIR/no-such-rate-table.json" \
    --session-id fixturemultimodel0001 --projects-root "$MULTIMODEL" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  grep -qF 'cost unavailable' <<<"$output" || return 1
}

# ---------- 27 ----------
@test "27: a partial command run ends the Cost: line with the partial marker" {
  run bash "$SCRIPT" --action command --command not-a-real-command \
    --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  case "$output" in
    *"(partial: lower bound)") ;;
    *) echo "stdout does not end with the partial marker: $output" >&2; return 1 ;;
  esac
}

# ---------- 28 ----------
@test "28: --action spec still prints the four-bucket block, byte-for-byte as before" {
  run bash "$SCRIPT" --action spec --spec-id SPEC-013 \
    --out-dir "$BATS_TEST_TMPDIR/out28" --session-id "$ANCHOR_SESSION" \
    --projects-root "$ANCHOR" --ledger "$LEDGER" --cache-dir "$CACHE"
  [ "$status" -eq 0 ]
  grep -qF 'Fresh input:' <<<"$output" || return 1
  grep -qF 'Cache write:' <<<"$output" || return 1
  grep -qF 'Cache read:' <<<"$output" || return 1
  grep -qF 'Output:' <<<"$output" || return 1
  grep -qF 'Total:' <<<"$output" || return 1
  grep -qF 'Elapsed:' <<<"$output" || return 1
}

# ================= The existing kinds and readers are untouched (SPEC UAT-009) =================

# ---------- 29 ----------
@test "29: spec/plan/execute/review rows carry no command, run_id, or github keys" {
  REPO="$BATS_TEST_TMPDIR/repo29"
  make_execute_repo "$REPO" "feature/telemetry-29"

  OWN_LEDGER="$BATS_TEST_TMPDIR/l29.jsonl"
  run bash "$SCRIPT" --action spec --spec-id SPEC-013 \
    --out-dir "$BATS_TEST_TMPDIR/out29-spec" --session-id "$ANCHOR_SESSION" \
    --projects-root "$ANCHOR" --ledger "$OWN_LEDGER" --cache-dir "$CACHE"
  [ "$status" -eq 0 ]

  run bash "$SCRIPT" --action plan --spec-id SPEC-013 --plan-slug telemetry-oracle \
    --out-dir "$BATS_TEST_TMPDIR/out29-plan" --session-id "$ANCHOR_SESSION" \
    --projects-root "$ANCHOR" --ledger "$OWN_LEDGER" --cache-dir "$CACHE"
  [ "$status" -eq 0 ]

  run bash -c "cd '$REPO' && bash '$SCRIPT' --action execute --spec-id SPEC-013 \
    --plan-slug telemetry-oracle --out-dir '$REPO/out' --session-id '$ANCHOR_SESSION' \
    --projects-root '$ANCHOR' --ledger '$OWN_LEDGER' --cache-dir '$CACHE'"
  [ "$status" -eq 0 ]

  run bash "$SCRIPT" --action review \
    --session-id fixtureauditreview0001 --projects-root "$FIXTURE_DIRECTORY/auditreview/projects" --ledger "$OWN_LEDGER"
  [ "$status" -eq 0 ]

  while IFS= read -r row; do
    kind="$(jq -r '.kind' <<<"$row")"
    if jq -e 'has("command")' >/dev/null 2>&1 <<<"$row"; then
      echo "kind=$kind unexpectedly carries command" >&2
      return 1
    fi
    if jq -e 'has("run_id")' >/dev/null 2>&1 <<<"$row"; then
      echo "kind=$kind unexpectedly carries run_id" >&2
      return 1
    fi
    if jq -e 'has("github")' >/dev/null 2>&1 <<<"$row"; then
      echo "kind=$kind unexpectedly carries github" >&2
      return 1
    fi
  done < "$OWN_LEDGER"

  [ "$(jq -r '.kind' "$OWN_LEDGER" | sort -u | tr '\n' ',')" = "execute,plan,review,spec," ]
}

# ---------- 30 ----------
@test "30: schema_version is 1 on every kind, including command" {
  OWN_LEDGER="$BATS_TEST_TMPDIR/l30.jsonl"
  run bash "$SCRIPT" --action command --command gaia-audit \
    --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$OWN_LEDGER"
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" --action spec --spec-id SPEC-013 \
    --out-dir "$BATS_TEST_TMPDIR/out30" --session-id "$ANCHOR_SESSION" \
    --projects-root "$ANCHOR" --ledger "$OWN_LEDGER" --cache-dir "$CACHE"
  [ "$status" -eq 0 ]

  versions="$(jq -r '.schema_version' "$OWN_LEDGER" | sort -u)"
  [ "$versions" = "1" ]
}

# ---------- 31 ----------
@test "31: token-rollup.sh is byte-identical whether or not a command row sits in the ledger" {
  LEDGER_WITHOUT_COMMAND_ROW="$BATS_TEST_TMPDIR/l31-without.jsonl"
  LEDGER_WITH_COMMAND_ROW="$BATS_TEST_TMPDIR/l31-with.jsonl"

  run bash "$SCRIPT" --action spec --spec-id SPEC-013 \
    --out-dir "$BATS_TEST_TMPDIR/out31" --session-id "$ANCHOR_SESSION" \
    --projects-root "$ANCHOR" --ledger "$LEDGER_WITHOUT_COMMAND_ROW" --cache-dir "$CACHE"
  [ "$status" -eq 0 ]
  cp "$LEDGER_WITHOUT_COMMAND_ROW" "$LEDGER_WITH_COMMAND_ROW"
  run bash "$SCRIPT" --action command --command gaia-audit \
    --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$LEDGER_WITH_COMMAND_ROW"
  [ "$status" -eq 0 ]

  ROLLUP="$SCRIPT_DIRECTORY/token-rollup.sh"
  run bash "$ROLLUP" --spec-id SPEC-013 --ledger "$LEDGER_WITHOUT_COMMAND_ROW"
  [ "$status" -eq 0 ]
  rollup_output_without_command="$output"

  run bash "$ROLLUP" --spec-id SPEC-013 --ledger "$LEDGER_WITH_COMMAND_ROW"
  [ "$status" -eq 0 ]
  rollup_output_with_command="$output"

  diff <(printf '%s\n' "$rollup_output_without_command") <(printf '%s\n' "$rollup_output_with_command")
}

# ---------- 32-34: --branch-name, the branch captured before cleanup ----------
# Every prescribed merge path cleans up before the tally runs, and both cleanups
# leave the session on main: feature-branch isolation checks main out, worktree
# isolation leaves the worktree for the main checkout. So each case below runs
# the tally from a checkout sitting on main, which is what the ambient lookup
# answers, and asserts the row names the branch the caller captured instead.

# run_command_in <repo_directory> [extra-args...]: drives --action command --command
# gaia-debt from inside <repo_directory>, so the ambient lookup answers for <repo_directory>.
run_command_in() {
  local repo_directory="$1"
  shift
  run bash -c 'repo_directory="$1"; shift; cd "$repo_directory" && bash "$@"' _ "$repo_directory" "$SCRIPT" \
    --action command --command gaia-debt "$@" \
    --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$LEDGER"
}

@test "32: feature-branch cleanup -- --branch-name attributes the row to the work branch, not the main the checkout returned to" {
  repo="$BATS_TEST_TMPDIR/fb32"
  make_execute_repo "$repo" "debt/42-some-fix"
  git -C "$repo" checkout -q -b main
  [ "$(git -C "$repo" branch --show-current)" = "main" ]

  run_command_in "$repo" --branch-name "debt/42-some-fix"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.git_branch' <<<"$(last_row)")" = "debt/42-some-fix" ]
}

@test "33: worktree cleanup -- --branch-name attributes the row to the removed worktree's branch, not main" {
  repo="$BATS_TEST_TMPDIR/wt33"
  worktree_directory="$BATS_TEST_TMPDIR/wt33-tree"
  make_execute_repo "$repo" "main"
  git -C "$repo" worktree add -q "$worktree_directory" -b "worktree-debt+42-some-fix"
  git -C "$repo" worktree remove --force "$worktree_directory"
  [ ! -d "$worktree_directory" ]
  [ "$(git -C "$repo" branch --show-current)" = "main" ]

  run_command_in "$repo" --branch-name "worktree-debt+42-some-fix"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.git_branch' <<<"$(last_row)")" = "worktree-debt+42-some-fix" ]
}

@test "34: without --branch-name the row keeps the ambient branch" {
  repo="$BATS_TEST_TMPDIR/amb34"
  make_execute_repo "$repo" "feature/ambient"

  run_command_in "$repo"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.git_branch' <<<"$(last_row)")" = "feature/ambient" ]
}
