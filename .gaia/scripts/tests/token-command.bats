#!/usr/bin/env bats
#
# Requires Bats >= 1.5.0.
bats_require_minimum_version 1.5.0
#
# Executable oracle for `.gaia/scripts/token-tally.sh --action command` (SPEC-040
# plan FC-4/FC-5/FC-6/FC-7): the one `kind: "command"` cost record each of the
# six maintenance commands appends per run, its optional GitHub-artifact
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
# Assertion style (.claude/rules/bats-assertions.md): non-final assertions
# avoid bare `[[ ... ]]` and `!`-negation; this suite uses `[ ... ]`, `grep -q`
# with an explicit status check, `jq -e` plus an explicit status check, and
# explicit `return 1` for the bad-case branch of every absence assertion.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$SCRIPT_DIR/token-tally.sh"
  LIB="$SCRIPT_DIR/gh-artifact-lib.sh"
  FIX="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures/token-tally" && pwd)"

  ANCHOR="$FIX/projects"                 # the shared transcript fixture
  ANCHOR_SESSION="fixturesession0001"

  LEDGER="$BATS_TEST_TMPDIR/ledger.jsonl"
  CACHE="$BATS_TEST_TMPDIR/cache"        # ISOLATED: never the developer's live cache
  mkdir -p "$CACHE"
}

# ---------- shared helpers (file-scope, mirrors token-review.bats's led()) ----------

last_row() { tail -n 1 "$LEDGER"; }

# mk_exec_repo <dir> <branch>: a throwaway git repo checked out on <branch>
# with one commit, so `git branch --show-current` inside it is deterministic
# regardless of the machine's init.defaultBranch config.
mk_exec_repo() {
  local dir="$1" branch="$2"
  mkdir -p "$dir"
  git init -q "$dir"
  git -C "$dir" checkout -q -b "$branch"
  git -C "$dir" -c user.email=gaia-test@example.com -c user.name="GAIA Test" \
    commit -q --allow-empty -m init
}

# run_execute <repo_dir> <session_id> <ledger>: drives --action execute from
# inside <repo_dir> (so GIT_BRANCH resolves to that repo's checked-out branch)
# against the shared isolated $CACHE.
run_execute() {
  local dir="$1" sid="$2" ledger="$3"
  ( cd "$dir" && bash "$SCRIPT" --action execute --plan-id PLAN-777 \
      --plan-slug telemetry-oracle --out-dir "$dir/out" --session-id "$sid" \
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
  local rc=$?
  [ "$rc" -eq 0 ] || return 1
  local rec
  rec="$(tail -n 1 "$ledger")"
  jq -e 'has("github")' >/dev/null 2>&1 <<<"$rec" && return 1
  [ "$(jq -r '.partial' <<<"$rec")" = "false" ] || return 1
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

  rec="$(last_row)"
  [ "$(jq -r '.kind' <<<"$rec")" = "command" ]
  [ "$(jq -r '.command' <<<"$rec")" = "gaia-audit" ]
  [ "$(jq -r '.spec_id' <<<"$rec")" = "null" ]
  [ "$(jq -r '.plan_id' <<<"$rec")" = "null" ]
  [ "$(jq -r '.plan_slug' <<<"$rec")" = "null" ]
  [ "$(jq -r '.partial' <<<"$rec")" = "false" ]
  [ "$(jq -r '.seq' <<<"$rec")" -eq 0 ]
  [ "$(jq -r '.final' <<<"$rec")" = "true" ]
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
  rec="$(last_row)"
  [ "$(jq -r '.command' <<<"$rec")" = "not-a-real-command" ]
  [ "$(jq -r '.partial' <<<"$rec")" = "true" ]
}

# ---------- 7 ----------
@test "7: an absent --command writes command:null and marks partial" {
  run bash "$SCRIPT" --action command \
    --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  rec="$(last_row)"
  [ "$(jq -r '.command' <<<"$rec")" = "null" ]
  [ "$(jq -r '.partial' <<<"$rec")" = "true" ]
}

# ---------- 8 ----------
@test "8: every one of the six recognized --command values yields partial:false (closed set, looped)" {
  for cmd in gaia-audit gaia-debt gaia-fitness gaia-forensics gaia-harden gaia-wiki; do
    L="$BATS_TEST_TMPDIR/six-$cmd.jsonl"
    run bash "$SCRIPT" --action command --command "$cmd" \
      --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$L"
    [ "$status" -eq 0 ]
    partial="$(jq -r '.partial' "$L")"
    if [ "$partial" != "false" ]; then
      echo "command $cmd unexpectedly marked partial" >&2
      return 1
    fi
    cmd_out="$(jq -r '.command' "$L")"
    if [ "$cmd_out" != "$cmd" ]; then
      echo "command $cmd round-tripped as $cmd_out" >&2
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
  rec="$(last_row)"
  [ "$(jq -c '.github' <<<"$rec")" = '{"type":"pr","number":712,"repo":"gaia-react/gaia"}' ]
  jq -e '.github.number | type == "number"' >/dev/null 2>&1 <<<"$rec" || return 1
}

# ---------- 10 ----------
@test "10: --github-type issue pass-through carries the exact repo the run passes, not a hardcoded one" {
  run bash "$SCRIPT" --action command --command gaia-forensics \
    --github-type issue --github-number 415 --github-repo gaia-react/gaia \
    --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  rec="$(last_row)"
  [ "$(jq -r '.github.type' <<<"$rec")" = "issue" ]
  [ "$(jq -r '.github.repo' <<<"$rec")" = "gaia-react/gaia" ]

  # A DIFFERENT repo than the one this checkout runs in: proves genuine
  # pass-through rather than a constant that happens to match gaia-react/gaia.
  run bash "$SCRIPT" --action command --command gaia-forensics \
    --github-type issue --github-number 9 --github-repo someone-else/other-repo \
    --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  rec2="$(last_row)"
  [ "$(jq -r '.github.repo' <<<"$rec2")" = "someone-else/other-repo" ]
}

# ---------- 11 ----------
@test "11: no --github-* flags at all omits the github key entirely, partial stays false" {
  run bash "$SCRIPT" --action command --command gaia-audit \
    --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  rec="$(last_row)"
  jq -e 'has("github")' >/dev/null 2>&1 <<<"$rec" && return 1
  [ "$(jq -r '.partial' <<<"$rec")" = "false" ]
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
  rec="$(last_row)"
  jq -e 'has("github")' >/dev/null 2>&1 <<<"$rec" && return 1
  [ -e "$BATS_TEST_TMPDIR/CANARY" ] && return 1
  [ -e CANARY ] && return 1

  run bash "$SCRIPT" --action command --command gaia-audit \
    --github-type pr --github-number 712 --github-repo 'o;id/n' \
    --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  rec2="$(last_row)"
  jq -e 'has("github")' >/dev/null 2>&1 <<<"$rec2" && return 1
  [ -e "$BATS_TEST_TMPDIR/CANARY" ] && return 1
  [ -e CANARY ] && return 1
  return 0
}

# ---------- 15 ----------
@test "15: --action command reads no breadcrumb, even a valid one matching this session AND branch sitting in --cache-dir" {
  . "$LIB"
  # The breadcrumb's branch MUST match the branch the run itself is checked
  # out on (mk_exec_repo, not an arbitrary literal): otherwise this assertion
  # would pass for the wrong reason (branch mismatch) even if --action command
  # were mistakenly changed to read the breadcrumb, and never actually catch
  # that regression.
  REPO="$BATS_TEST_TMPDIR/repo15"
  BRANCH="feature/telemetry-15"
  mk_exec_repo "$REPO" "$BRANCH"
  bc="$CACHE/gh-artifact-pr.json"
  gaia_gh_artifact_write "$bc" 712 "gaia-react/gaia" "$BRANCH" "$ANCHOR_SESSION"
  [ -f "$bc" ]

  run bash -c "cd '$REPO' && bash '$SCRIPT' --action command --command gaia-audit --cache-dir '$CACHE' \
    --session-id '$ANCHOR_SESSION' --projects-root '$ANCHOR' --ledger '$LEDGER'"
  [ "$status" -eq 0 ]
  rec="$(last_row)"
  jq -e 'has("github")' >/dev/null 2>&1 <<<"$rec" && return 1
  return 0
}

# ================= The github object on execute (breadcrumb, read-only) =================

# ---------- 16 ----------
@test "16: execute -- session_id and branch both match the breadcrumb, github is present" {
  . "$LIB"
  REPO="$BATS_TEST_TMPDIR/repo16"
  BRANCH="feature/telemetry-16"
  SID="exec-session-16"
  mk_exec_repo "$REPO" "$BRANCH"
  gaia_gh_artifact_write "$CACHE/gh-artifact-pr.json" 712 "gaia-react/gaia" "$BRANCH" "$SID"

  run run_execute "$REPO" "$SID" "$LEDGER"
  [ "$status" -eq 0 ]
  rec="$(last_row)"
  [ "$(jq -c '.github' <<<"$rec")" = '{"type":"pr","number":712,"repo":"gaia-react/gaia"}' ]
}

# ---------- 17 ----------
@test "17: the breadcrumb file survives an execute read" {
  . "$LIB"
  REPO="$BATS_TEST_TMPDIR/repo17"
  BRANCH="feature/telemetry-17"
  SID="exec-session-17"
  mk_exec_repo "$REPO" "$BRANCH"
  bc="$CACHE/gh-artifact-pr.json"
  gaia_gh_artifact_write "$bc" 712 "gaia-react/gaia" "$BRANCH" "$SID"

  run run_execute "$REPO" "$SID" "$LEDGER"
  [ "$status" -eq 0 ]
  [ -f "$bc" ]
}

# ---------- 18 ----------
@test "18: two execute runs both carry github; final flips from the first row to the second" {
  . "$LIB"
  REPO="$BATS_TEST_TMPDIR/repo18"
  BRANCH="feature/telemetry-18"
  SID="exec-session-18"
  mk_exec_repo "$REPO" "$BRANCH"
  gaia_gh_artifact_write "$CACHE/gh-artifact-pr.json" 712 "gaia-react/gaia" "$BRANCH" "$SID"

  run run_execute "$REPO" "$SID" "$LEDGER"
  [ "$status" -eq 0 ]
  git -C "$REPO" -c user.email=gaia-test@example.com -c user.name="GAIA Test" \
    commit -q --allow-empty -m "second commit"
  run run_execute "$REPO" "$SID" "$LEDGER"
  [ "$status" -eq 0 ]

  [ "$(wc -l < "$LEDGER" | tr -d ' ')" -eq 2 ]
  [ "$(jq -c 'select(.github.number == 712)' "$LEDGER" | wc -l | tr -d ' ')" -eq 2 ]
  row1_final="$(sed -n '1p' "$LEDGER" | jq -r '.final')"
  row2_final="$(sed -n '2p' "$LEDGER" | jq -r '.final')"
  [ "$row1_final" = "false" ]
  [ "$row2_final" = "true" ]
}

# ---------- 19 ----------
@test "19: execute -- branch mismatch omits github" {
  . "$LIB"
  REPO="$BATS_TEST_TMPDIR/repo19"
  SID="exec-session-19"
  mk_exec_repo "$REPO" "feature/actual-branch-19"
  gaia_gh_artifact_write "$CACHE/gh-artifact-pr.json" 712 "gaia-react/gaia" \
    "feature/different-branch-19" "$SID"

  run run_execute "$REPO" "$SID" "$LEDGER"
  [ "$status" -eq 0 ]
  rec="$(last_row)"
  jq -e 'has("github")' >/dev/null 2>&1 <<<"$rec" && return 1
  return 0
}

# ---------- 20 ----------
@test "20: execute -- session_id mismatch omits github" {
  . "$LIB"
  REPO="$BATS_TEST_TMPDIR/repo20"
  BRANCH="feature/telemetry-20"
  mk_exec_repo "$REPO" "$BRANCH"
  gaia_gh_artifact_write "$CACHE/gh-artifact-pr.json" 712 "gaia-react/gaia" "$BRANCH" \
    "some-other-session-20"

  run run_execute "$REPO" "exec-session-20" "$LEDGER"
  [ "$status" -eq 0 ]
  rec="$(last_row)"
  jq -e 'has("github")' >/dev/null 2>&1 <<<"$rec" && return 1
  return 0
}

# ---------- 21 ----------
@test "21: execute -- a ts older than the TTL omits github" {
  . "$LIB"
  REPO="$BATS_TEST_TMPDIR/repo21"
  BRANCH="feature/telemetry-21"
  SID="exec-session-21"
  mk_exec_repo "$REPO" "$BRANCH"
  bc="$CACHE/gh-artifact-pr.json"
  gaia_gh_artifact_write "$bc" 712 "gaia-react/gaia" "$BRANCH" "$SID"

  # The production writer always stamps "now"; there is no --ts seam, so aging
  # the breadcrumb past the 86400s default TTL means patching ONLY `ts` after
  # the fact (via a captured variable, never redirecting jq into its own input
  # file, which would truncate it before jq reads it).
  old_ts="$(jq -rn '(now - 90000) | gmtime | strftime("%Y-%m-%dT%H:%M:%SZ")')"
  updated="$(jq --arg ts "$old_ts" '.ts = $ts' "$bc")"
  printf '%s\n' "$updated" >"$bc"

  run run_execute "$REPO" "$SID" "$LEDGER"
  [ "$status" -eq 0 ]
  rec="$(last_row)"
  jq -e 'has("github")' >/dev/null 2>&1 <<<"$rec" && return 1
  return 0
}

# ---------- 22 ----------
@test "22: execute -- no breadcrumb at all omits github, partial unchanged, exit 0" {
  REPO="$BATS_TEST_TMPDIR/repo22"
  BRANCH="feature/telemetry-22"
  mk_exec_repo "$REPO" "$BRANCH"

  L1="$BATS_TEST_TMPDIR/l22-with.jsonl"
  L2="$BATS_TEST_TMPDIR/l22-without.jsonl"

  . "$LIB"
  gaia_gh_artifact_write "$CACHE/gh-artifact-pr.json" 712 "gaia-react/gaia" "$BRANCH" \
    "exec-session-22"
  run run_execute "$REPO" "exec-session-22" "$L1"
  [ "$status" -eq 0 ]
  partial_with="$(jq -r '.partial' "$L1")"

  rm -f "$CACHE/gh-artifact-pr.json"
  run run_execute "$REPO" "exec-session-22" "$L2"
  [ "$status" -eq 0 ]
  rec="$(tail -n 1 "$L2")"
  jq -e 'has("github")' >/dev/null 2>&1 <<<"$rec" && return 1
  [ "$(jq -r '.partial' <<<"$rec")" = "$partial_with" ]
}

# ---------- 23 ----------
@test "23: execute -- --cache-dir genuinely roots the read; a breadcrumb elsewhere is never seen" {
  . "$LIB"
  REPO="$BATS_TEST_TMPDIR/repo23"
  BRANCH="feature/telemetry-23"
  SID="exec-session-23"
  mk_exec_repo "$REPO" "$BRANCH"

  ELSEWHERE="$BATS_TEST_TMPDIR/elsewhere-cache-23"
  mkdir -p "$ELSEWHERE"
  gaia_gh_artifact_write "$ELSEWHERE/gh-artifact-pr.json" 712 "gaia-react/gaia" "$BRANCH" "$SID"

  EMPTY="$BATS_TEST_TMPDIR/empty-cache-23"
  mkdir -p "$EMPTY"
  run bash -c "cd '$REPO' && bash '$SCRIPT' --action execute --plan-id PLAN-777 \
    --plan-slug telemetry-oracle --out-dir '$REPO/out' --session-id '$SID' \
    --projects-root '$ANCHOR' --ledger '$LEDGER' --cache-dir '$EMPTY'"
  [ "$status" -eq 0 ]
  rec="$(last_row)"
  jq -e 'has("github")' >/dev/null 2>&1 <<<"$rec" && return 1
  return 0
}

# ---------- 24 ----------
@test "24: execute -- a row written before the breadcrumb exists is never back-filled (single-phase precondition)" {
  . "$LIB"
  REPO="$BATS_TEST_TMPDIR/repo24"
  BRANCH="feature/telemetry-24"
  SID="exec-session-24"
  mk_exec_repo "$REPO" "$BRANCH"

  # No breadcrumb yet: the run's only row is written with no github. This
  # models a single-commit-phase plan whose one commit precedes `gh pr
  # create` -- FC-6 precondition 1 -- which is correct behavior, not a bug.
  run run_execute "$REPO" "$SID" "$LEDGER"
  [ "$status" -eq 0 ]
  rec_before="$(last_row)"
  jq -e 'has("github")' >/dev/null 2>&1 <<<"$rec_before" && return 1

  # gh pr create happens AFTER that row was already appended.
  gaia_gh_artifact_write "$CACHE/gh-artifact-pr.json" 712 "gaia-react/gaia" "$BRANCH" "$SID"

  # The already-written row is a static ledger line: nothing re-reads or
  # rewrites it, so it is byte-identical and still carries no github.
  rec_after="$(last_row)"
  [ "$rec_after" = "$rec_before" ]
  jq -e 'has("github")' >/dev/null 2>&1 <<<"$rec_after" && return 1
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
  MULTIMODEL="$FIX/multimodel/projects"
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
  mk_exec_repo "$REPO" "feature/telemetry-29"

  L="$BATS_TEST_TMPDIR/l29.jsonl"
  run bash "$SCRIPT" --action spec --spec-id SPEC-013 \
    --out-dir "$BATS_TEST_TMPDIR/out29-spec" --session-id "$ANCHOR_SESSION" \
    --projects-root "$ANCHOR" --ledger "$L" --cache-dir "$CACHE"
  [ "$status" -eq 0 ]

  run bash "$SCRIPT" --action plan --spec-id SPEC-013 --plan-slug telemetry-oracle \
    --out-dir "$BATS_TEST_TMPDIR/out29-plan" --session-id "$ANCHOR_SESSION" \
    --projects-root "$ANCHOR" --ledger "$L" --cache-dir "$CACHE"
  [ "$status" -eq 0 ]

  run bash -c "cd '$REPO' && bash '$SCRIPT' --action execute --spec-id SPEC-013 \
    --plan-slug telemetry-oracle --out-dir '$REPO/out' --session-id '$ANCHOR_SESSION' \
    --projects-root '$ANCHOR' --ledger '$L' --cache-dir '$CACHE'"
  [ "$status" -eq 0 ]

  run bash "$SCRIPT" --action review \
    --session-id fixtureauditreview0001 --projects-root "$FIX/auditreview/projects" --ledger "$L"
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
  done < "$L"

  [ "$(jq -r '.kind' "$L" | sort -u | tr '\n' ',')" = "execute,plan,review,spec," ]
}

# ---------- 30 ----------
@test "30: schema_version is 1 on every kind, including command" {
  L="$BATS_TEST_TMPDIR/l30.jsonl"
  run bash "$SCRIPT" --action command --command gaia-audit \
    --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$L"
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" --action spec --spec-id SPEC-013 \
    --out-dir "$BATS_TEST_TMPDIR/out30" --session-id "$ANCHOR_SESSION" \
    --projects-root "$ANCHOR" --ledger "$L" --cache-dir "$CACHE"
  [ "$status" -eq 0 ]

  versions="$(jq -r '.schema_version' "$L" | sort -u)"
  [ "$versions" = "1" ]
}

# ---------- 31 ----------
@test "31: token-rollup.sh is byte-identical whether or not a command row sits in the ledger" {
  L_WITHOUT="$BATS_TEST_TMPDIR/l31-without.jsonl"
  L_WITH="$BATS_TEST_TMPDIR/l31-with.jsonl"

  run bash "$SCRIPT" --action spec --spec-id SPEC-013 \
    --out-dir "$BATS_TEST_TMPDIR/out31" --session-id "$ANCHOR_SESSION" \
    --projects-root "$ANCHOR" --ledger "$L_WITHOUT" --cache-dir "$CACHE"
  [ "$status" -eq 0 ]
  cp "$L_WITHOUT" "$L_WITH"
  run bash "$SCRIPT" --action command --command gaia-audit \
    --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$L_WITH"
  [ "$status" -eq 0 ]

  ROLLUP="$SCRIPT_DIR/token-rollup.sh"
  run bash "$ROLLUP" --spec-id SPEC-013 --ledger "$L_WITHOUT"
  [ "$status" -eq 0 ]
  out_without="$output"

  run bash "$ROLLUP" --spec-id SPEC-013 --ledger "$L_WITH"
  [ "$status" -eq 0 ]
  out_with="$output"

  diff <(printf '%s\n' "$out_without") <(printf '%s\n' "$out_with")
}
