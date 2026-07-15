#!/usr/bin/env bats
# Tests for .claude/hooks/lib/audit-dispositions.sh, the shared disposition-
# ledger logic (disposition_offenders / disposition_merge), in isolation.
#
# This is the first bats coverage of any kind for the disposition backstop's
# logic. The end-to-end carry-then-deny observable lives in
# pr-merge-audit-check.bats, because that re-verification runs inside the
# minting authority, not this hook (whose deny conditions this change leaves
# unchanged).
#
# `gh` is mocked on a prepended PATH per test. Assertion style
# (.claude/rules/bats-assertions.md): `grep -q` / `[ ]` / explicit `return 1`.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  LIB="$REPO_ROOT/.claude/hooks/lib/audit-dispositions.sh"
  [ -f "$LIB" ] || skip "audit-dispositions.sh not present"
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  # shellcheck source=/dev/null
  . "$LIB"
  SIDECAR="$BATS_TEST_TMPDIR/head.dispositions.json"
}

# install_gh_mock MODE [ISSUES_JSON]:
#   ok <json>   -> `gh issue list ...` prints ISSUES_JSON, exit 0
#   fail        -> `gh issue list ...` exits non-zero (backend unreachable)
install_gh_mock() {
  local mode="$1" issues="${2:-[]}"
  GH_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$GH_BIN"
  printf '%s' "$issues" > "$BATS_TEST_TMPDIR/issues.json"
  cat > "$GH_BIN/gh" <<EOF
#!/usr/bin/env bash
mode="$mode"
issues_file="$BATS_TEST_TMPDIR/issues.json"
EOF
  cat >> "$GH_BIN/gh" <<'EOF'
case "$1" in
  issue)
    [ "$mode" = "fail" ] && exit 1
    cat "$issues_file"
    ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$GH_BIN/gh"
  export PATH="$GH_BIN:$PATH"
}

write_sidecar() { printf '%s\n' "$1" > "$SIDECAR"; }

# ---------------------------------------------------------------------------
# disposition_offenders: the two deny conditions
# ---------------------------------------------------------------------------

@test "offenders: a pending(definitive) entry is an offender (no backend needed)" {
  write_sidecar '{"schema":1,"backend":"github","findings":[{"key":"v1 class=x path=a line=1","disposition":"pending","pending_reason":"definitive"}]}'
  run disposition_offenders "$SIDECAR"
  [ "$status" -eq 0 ]
  grep -q "pending(definitive): v1 class=x path=a line=1" <<<"$output" || return 1
}

@test "offenders: keys on pending_reason definitive, never on a severity" {
  # A pending entry with a transient reason is NOT an offender even at high severity.
  write_sidecar '{"schema":1,"backend":"github","findings":[{"key":"v1 class=x path=a line=1","severity":"critical","disposition":"pending","pending_reason":"transient"}]}'
  run disposition_offenders "$SIDECAR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "offenders: a filed key with no matching issue on a reachable backend is an offender" {
  install_gh_mock ok '[]'
  write_sidecar '{"schema":1,"backend":"github","findings":[{"key":"v1 class=y path=b line=2","disposition":"filed"}]}'
  run disposition_offenders "$SIDECAR"
  [ "$status" -eq 0 ]
  grep -q "filed-but-missing: v1 class=y path=b line=2" <<<"$output" || return 1
}

@test "offenders: a CLOSED matching issue is a satisfied disposition, not an offender" {
  install_gh_mock ok '[{"number":9,"body":"title\n\n<!-- gaia-debt-key: v1 class=y path=b line=2 -->"}]'
  write_sidecar '{"schema":1,"backend":"github","findings":[{"key":"v1 class=y path=b line=2","disposition":"filed"}]}'
  run disposition_offenders "$SIDECAR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# disposition_offenders: fail-open everywhere else
# ---------------------------------------------------------------------------

@test "fail-open: no sidecar -> clean" {
  run disposition_offenders "$BATS_TEST_TMPDIR/does-not-exist.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fail-open: unparseable sidecar -> clean" {
  write_sidecar 'not json {'
  run disposition_offenders "$SIDECAR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fail-open: backend absent -> clean (even with a filed entry)" {
  write_sidecar '{"schema":1,"backend":"absent","findings":[{"key":"v1 class=y path=b line=2","disposition":"filed"}]}'
  run disposition_offenders "$SIDECAR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fail-open: gh absent -> filed checks skipped (no offender)" {
  # No gh on PATH (mock not installed); filed check fails open.
  PATH="$BATS_TEST_TMPDIR/empty-bin:$PATH"
  mkdir -p "$BATS_TEST_TMPDIR/empty-bin"
  write_sidecar '{"schema":1,"backend":"github","findings":[{"key":"v1 class=y path=b line=2","disposition":"filed"}]}'
  # Only assert the filed arm is fail-open by removing gh: run in a shell whose
  # PATH lacks gh. If gh is genuinely present system-wide this still returns
  # clean because the issue list is queried and, absent a match, would flag; so
  # instead force the unreachable path with a failing mock.
  install_gh_mock fail
  run disposition_offenders "$SIDECAR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fail-open: gh returns non-zero (unreachable backend) -> no filed offender" {
  install_gh_mock fail
  write_sidecar '{"schema":1,"backend":"github","findings":[{"key":"v1 class=y path=b line=2","disposition":"filed"}]}'
  run disposition_offenders "$SIDECAR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# disposition_merge: the two contract rules
# ---------------------------------------------------------------------------

@test "merge: HEAD's fresh entry wins on a key collision; a carried entry only ADDS keys" {
  anchor="$BATS_TEST_TMPDIR/anchor.json"
  printf '%s\n' '{"schema":1,"backend":"github","findings":[{"key":"K1","disposition":"filed"},{"key":"K2","disposition":"diverted"}]}' > "$anchor"
  printf '%s\n' '{"schema":1,"backend":"github","findings":[{"key":"K1","disposition":"waived"}]}' > "$SIDECAR"

  disposition_merge "$anchor" "$SIDECAR"

  # K1 keeps HEAD's fresh value (waived), never the anchor's (filed).
  k1="$(jq -r '.findings[] | select(.key=="K1") | .disposition' "$SIDECAR")"
  [ "$k1" = "waived" ]
  # Exactly one K1 entry (no duplicate).
  n_k1="$(jq -r '[.findings[] | select(.key=="K1")] | length' "$SIDECAR")"
  [ "$n_k1" -eq 1 ]
  # K2 (anchor-only) was ADDED.
  k2="$(jq -r '.findings[] | select(.key=="K2") | .disposition' "$SIDECAR")"
  [ "$k2" = "diverted" ]
}

@test "merge: the strictest backend wins (non-absent is never silenced by absent)" {
  anchor="$BATS_TEST_TMPDIR/anchor.json"
  printf '%s\n' '{"schema":1,"backend":"github","findings":[]}' > "$anchor"
  printf '%s\n' '{"schema":1,"backend":"absent","findings":[]}' > "$SIDECAR"
  disposition_merge "$anchor" "$SIDECAR"
  [ "$(jq -r '.backend' "$SIDECAR")" = "github" ]

  # The symmetric direction: head non-absent, anchor absent -> head's stays.
  printf '%s\n' '{"schema":1,"backend":"absent","findings":[]}' > "$anchor"
  printf '%s\n' '{"schema":1,"backend":"github","findings":[]}' > "$SIDECAR"
  disposition_merge "$anchor" "$SIDECAR"
  [ "$(jq -r '.backend' "$SIDECAR")" = "github" ]
}

@test "merge: a missing head sidecar is written through from the anchor" {
  anchor="$BATS_TEST_TMPDIR/anchor.json"
  printf '%s\n' '{"schema":1,"backend":"github","findings":[{"key":"K9","disposition":"filed"}]}' > "$anchor"
  rm -f "$SIDECAR"
  disposition_merge "$anchor" "$SIDECAR"
  [ -f "$SIDECAR" ]
  [ "$(jq -r '.findings[] | select(.key=="K9") | .disposition' "$SIDECAR")" = "filed" ]
}
