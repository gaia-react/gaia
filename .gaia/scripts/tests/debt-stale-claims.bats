#!/usr/bin/env bats
#
# Suite for .gaia/scripts/debt-stale-claims.sh, the /gaia-debt stale-claim
# verdict. Each liveness arm is driven on its own, so a claim is stale in the
# fixture unless exactly the arm under test keeps it; then every unreadable
# input is shown to print nothing and exit 3, because a caller strips each
# number it sees.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   source .gaia/scripts/bats5.sh && bats5 .gaia/scripts/tests/debt-stale-claims.bats

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/debt-stale-claims.sh"
  D="$BATS_TEST_TMPDIR"
  # 2026-09-20T00:00:00Z; every updatedAt below is an hour older unless a
  # test says otherwise, so only the arm under test can keep a claim alive.
  NOW=1789862400
  OLD="2026-09-19T23:00:00Z"
  printf '[]' >"$D/prs.json"
  : >"$D/branches"
}

# claims <number>...: an in-progress claims list, every claim an hour old.
claims() {
  local n out="["
  for n in "$@"; do
    out="${out}{\"number\":$n,\"updatedAt\":\"$OLD\"},"
  done
  printf '%s]' "${out%,}" >"$D/claims.json"
}

verdict() {
  run --separate-stderr bash "$SCRIPT" --claims-json "$D/claims.json" \
    --prs-json "$D/prs.json" --branches "$D/branches" --now "$NOW" "$@"
}

# ========== the arms ==========

@test "no arm holds: every old claim is stale, one number per line" {
  claims 11 12
  verdict
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '11\n12')" ]
}

@test "branch arm: a plain debt branch keeps its issue" {
  claims 11 12
  printf 'main\ndebt/11-some-fix\n' >"$D/branches"
  verdict
  [ "$status" -eq 0 ]
  [ "$output" = "12" ]
}

@test "branch arm: the worktree spelling keeps its issue, which a debt/* glob cannot see" {
  claims 2155 2158 2159
  printf 'worktree-debt+2155-funsub-qualifier-segments\nworktree-debt+2158-quoted-opener-arming\n' >"$D/branches"
  verdict
  [ "$status" -eq 0 ]
  [ "$output" = "2159" ]
}

@test "branch arm: every member of a batch branch is kept, not only the lowest" {
  claims 41 42 47 50
  printf 'worktree-debt+41-42-47-batch\n' >"$D/branches"
  verdict
  [ "$status" -eq 0 ]
  [ "$output" = "50" ]
}

@test "branch arm: a non-debt branch naming a number keeps nothing" {
  claims 11
  printf 'fix/11-thing\nplan/spec-011-x\nchore/11-x-2026-09-20-0000\n' >"$D/branches"
  verdict
  [ "$status" -eq 0 ]
  [ "$output" = "11" ]
}

@test "pr arm: an open pull request's head branch keeps its issue" {
  claims 11 12
  printf '[{"headRefName":"debt/12-remote-only","body":""}]' >"$D/prs.json"
  verdict
  [ "$status" -eq 0 ]
  [ "$output" = "11" ]
}

@test "pr arm: every closing keyword in a body keeps its issue, in any case" {
  claims 1 2 3 4 5 6 7
  printf '%s' '[{"headRefName":"feat/x","body":"Closes #1\nfixes #2\nRESOLVED: #3\nclose #4 and fixed #5\nsee #6"}]' >"$D/prs.json"
  verdict
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '6\n7')" ]
}

@test "pr arm: the owner/repo# and issue-URL forms GitHub accepts keep their issues" {
  claims 11 12 13
  printf '%s' '[{"headRefName":"fix/x","body":"Closes https://github.com/o/r/issues/11\nFixes o/r#12"}]' >"$D/prs.json"
  verdict
  [ "$status" -eq 0 ]
  [ "$output" = "13" ]
}

@test "pr arm: a keyword against a longer number does not keep a prefix of it" {
  claims 21
  printf '%s' '[{"headRefName":"feat/x","body":"Closes #210"}]' >"$D/prs.json"
  verdict
  [ "$status" -eq 0 ]
  [ "$output" = "21" ]
}

@test "fresh arm: a claim updated inside the grace window is kept, one at the boundary is not" {
  printf '[{"number":1,"updatedAt":"2026-09-19T23:59:10Z"},{"number":2,"updatedAt":"2026-09-19T23:30:00Z"}]' >"$D/claims.json"
  verdict
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "fresh arm: a 50-second-old claim is kept whatever the local timezone" {
  printf '[{"number":2155,"updatedAt":"2026-09-19T23:59:10Z"}]' >"$D/claims.json"
  run --separate-stderr env TZ=Asia/Tokyo bash "$SCRIPT" --claims-json "$D/claims.json" \
    --prs-json "$D/prs.json" --branches "$D/branches" --now "$NOW"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "--grace changes the window" {
  printf '[{"number":1,"updatedAt":"2026-09-19T23:59:10Z"}]' >"$D/claims.json"
  verdict --grace 10
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "no claims at all is a complete answer that needs no other input" {
  printf '[]' >"$D/claims.json"
  run --separate-stderr bash "$SCRIPT" --claims-json "$D/claims.json" \
    --prs-json "$D/missing.json" --branches "$D/missing" --now "$NOW"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ========== fail-closed ==========

@test "fail-closed: an unreadable input prints nothing and exits 3 with its reason" {
  claims 11
  local row flag path reason
  for row in \
    "--prs-json|$D/missing.json|cannot read" \
    "--branches|$D/missing|cannot read"; do
    IFS='|' read -r flag path reason <<<"$row"
    run --separate-stderr bash "$SCRIPT" --claims-json "$D/claims.json" \
      --prs-json "$D/prs.json" --branches "$D/branches" --now "$NOW" "$flag" "$path"
    [ "$status" -eq 3 ] || { echo "$flag: status $status" >&2; return 1; }
    [ -z "$output" ] || { echo "$flag: stdout '$output'" >&2; return 1; }
    grep -qF "$reason" <<<"$stderr"
  done
}

@test "fail-closed: a malformed claims list, pull-request list, or timestamp prints nothing and exits 3" {
  printf 'not json' >"$D/claims.json"
  verdict
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  grep -qF 'claims list is not a JSON array' <<<"$stderr"

  claims 11
  printf '{"not":"an array"}' >"$D/prs.json"
  verdict
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  grep -qF 'pull-request list is not a JSON array' <<<"$stderr"

  printf '[]' >"$D/prs.json"
  printf '[{"number":11,"updatedAt":"%s"},{"number":12,"updatedAt":"yesterday"}]' "$OLD" >"$D/claims.json"
  verdict
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  grep -qF 'unreadable number or updatedAt' <<<"$stderr"
}

@test "fail-closed: a failing gh prints nothing and exits 3" {
  mkdir -p "$D/bin"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$D/bin/gh"
  chmod +x "$D/bin/gh"
  run --separate-stderr env PATH="$D/bin:$PATH" bash "$SCRIPT" --now "$NOW"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  grep -qF 'gh issue list failed' <<<"$stderr"
}

@test "fail-closed: a missing branch library prints nothing and exits 3" {
  mkdir -p "$D/lonely"
  cp "$SCRIPT" "$D/lonely/debt-stale-claims.sh"
  claims 11
  run --separate-stderr bash "$D/lonely/debt-stale-claims.sh" --claims-json "$D/claims.json" \
    --prs-json "$D/prs.json" --branches "$D/branches" --now "$NOW"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  grep -qF 'branch library' <<<"$stderr"
}

@test "usage: an unknown flag or a non-numeric window exits 2" {
  run --separate-stderr bash "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" --grace soon
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" --now
  [ "$status" -eq 2 ]
}

# ========== live wiring ==========

@test "live reads: branches come from the repository through the library" {
  local repo="$D/repo"
  git init -q --initial-branch=main "$repo"
  git -C "$repo" -c user.email=t@example.com -c user.name=T commit -q --allow-empty -m init
  git -C "$repo" branch "worktree-debt+11-x"
  claims 11 12
  run --separate-stderr bash "$SCRIPT" --dir "$repo" --claims-json "$D/claims.json" \
    --prs-json "$D/prs.json" --now "$NOW"
  [ "$status" -eq 0 ]
  [ "$output" = "12" ]
}

@test "structural: shellcheck is clean" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not available"
  shellcheck "$SCRIPT"
}
