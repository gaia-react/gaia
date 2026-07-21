#!/usr/bin/env bats
# Tests for the disposition backstop: the shared lib
# (.claude/hooks/lib/audit-dispositions.sh: disposition_offenders,
# disposition_seed_forward) and the standalone deterministic gate hook
# (.claude/hooks/audit-disposition-check.sh) that re-keys the sidecar to the
# frontend content digest.
#
# The lib-level tests source the lib directly and call its functions in
# isolation. The hook-level tests drive the REAL hook by absolute path
# ($HOOK_ABS) with cwd set to a fixture git repo, exactly as the harness runs
# it: a PreToolUse JSON payload on stdin, allow vs deny carried in stdout (the
# hook always exits 0; a deny emits `"permissionDecision": "deny"`). Because
# the hook resolves its own libs relative to `${BASH_SOURCE[0]}`, it always
# loads the REAL classifier/digest/clearance libs against the FIXTURE repo's
# tree, never a stale copy.
#
# `gh` is mocked on a prepended PATH per test. Assertion style
# (.claude/rules/bats-assertions.md): `grep -q` / `[ ]` / explicit `return 1`.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  LIB="$REPO_ROOT/.claude/hooks/lib/audit-dispositions.sh"
  HOOK_ABS="$REPO_ROOT/.claude/hooks/audit-disposition-check.sh"
  DIGEST_CLI="$REPO_ROOT/.gaia/scripts/audit-member-digest.sh"
  [ -f "$LIB" ] || skip "audit-dispositions.sh not present"
  [ -f "$HOOK_ABS" ] || skip "audit-disposition-check.sh not present"
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    skip "no sha256 tool"
  fi
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
# disposition_offenders: the two deny conditions (unchanged signature/behavior)
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

@test "offenders: a filed line=4 key is NOT satisfied by a sibling line=42 issue (the -->boundary guard)" {
  install_gh_mock ok '[{"number":9,"body":"title\n\n<!-- gaia-debt-key: v1 class=y path=b line=42 -->"}]'
  write_sidecar '{"schema":1,"backend":"github","findings":[{"key":"v1 class=y path=b line=4","disposition":"filed"}]}'
  run disposition_offenders "$SIDECAR"
  [ "$status" -eq 0 ]
  grep -q "filed-but-missing: v1 class=y path=b line=4" <<<"$output" || return 1
}

@test "offenders: a filed line=4 key IS satisfied by an exact line=4 issue" {
  install_gh_mock ok '[{"number":9,"body":"title\n\n<!-- gaia-debt-key: v1 class=y path=b line=4 -->"}]'
  write_sidecar '{"schema":1,"backend":"github","findings":[{"key":"v1 class=y path=b line=4","disposition":"filed"}]}'
  run disposition_offenders "$SIDECAR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# disposition_offenders: the machinery_waived abuse-check
#
# audit_path_is_machinery is resolved lazily by the lib from its own on-disk
# dir (setup() sources only audit-dispositions.sh), so these call the function
# in isolation and it self-loads the real machinery set. No backend query.
# ---------------------------------------------------------------------------

@test "offenders: a machinery_waived entry whose path IS machinery is NOT an offender" {
  write_sidecar '{"schema":1,"backend":"github","findings":[{"key":"v1 class=holistic/x path=.claude/hooks/lib/audit-machinery.sh line=5","disposition":"machinery_waived"}]}'
  run disposition_offenders "$SIDECAR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "offenders: a machinery_waived entry whose path is NOT machinery IS an offender" {
  write_sidecar '{"schema":1,"backend":"github","findings":[{"key":"v1 class=holistic/x path=app/x.ts line=5","disposition":"machinery_waived"}]}'
  run disposition_offenders "$SIDECAR"
  [ "$status" -eq 0 ]
  grep -q "machinery-waived-not-machinery: v1 class=holistic/x path=app/x.ts line=5" <<<"$output" || return 1
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
# disposition_seed_forward: deterministic still-open union (replaces the
# deleted disposition_merge; no anchor selection, no ancestry, no backend
# precedence).
# ---------------------------------------------------------------------------

@test "seed-forward: a filed entry from prev is written through into a missing new sidecar" {
  PREV="$BATS_TEST_TMPDIR/prev.json"
  printf '%s\n' '{"schema":1,"backend":"github","findings":[{"key":"K1","disposition":"filed"}]}' > "$PREV"
  rm -f "$SIDECAR"
  disposition_seed_forward "$PREV" "$SIDECAR"
  [ -f "$SIDECAR" ]
  [ "$(jq -r '.findings[] | select(.key=="K1") | .disposition' "$SIDECAR")" = "filed" ]
}

@test "seed-forward: a pending(definitive) entry is still-open and is seeded" {
  PREV="$BATS_TEST_TMPDIR/prev.json"
  printf '%s\n' '{"schema":1,"backend":"github","findings":[{"key":"K2","disposition":"pending","pending_reason":"definitive"}]}' > "$PREV"
  rm -f "$SIDECAR"
  disposition_seed_forward "$PREV" "$SIDECAR"
  [ "$(jq -r '.findings[] | select(.key=="K2") | .disposition' "$SIDECAR")" = "pending" ]
}

@test "seed-forward: waived / diverted / machinery_waived / pending(transient) are NOT still-open and are not seeded" {
  PREV="$BATS_TEST_TMPDIR/prev.json"
  printf '%s\n' '{"schema":1,"backend":"github","findings":[
    {"key":"W1","disposition":"waived"},
    {"key":"D1","disposition":"diverted"},
    {"key":"M1","disposition":"machinery_waived"},
    {"key":"P1","disposition":"pending","pending_reason":"transient"}
  ]}' > "$PREV"
  printf '%s\n' '{"schema":1,"backend":"github","findings":[]}' > "$SIDECAR"
  disposition_seed_forward "$PREV" "$SIDECAR"
  n="$(jq -r '.findings | length' "$SIDECAR")"
  [ "$n" -eq 0 ]
}

@test "seed-forward: HEAD's fresh entry wins on a key collision; a seeded entry only ADDS keys" {
  PREV="$BATS_TEST_TMPDIR/prev.json"
  printf '%s\n' '{"schema":1,"backend":"github","findings":[{"key":"K1","disposition":"filed"},{"key":"K2","disposition":"filed"}]}' > "$PREV"
  printf '%s\n' '{"schema":1,"backend":"github","findings":[{"key":"K1","disposition":"waived"}]}' > "$SIDECAR"

  disposition_seed_forward "$PREV" "$SIDECAR"

  # K1 keeps HEAD's fresh value (waived), never the seeded one (filed).
  k1="$(jq -r '.findings[] | select(.key=="K1") | .disposition' "$SIDECAR")"
  [ "$k1" = "waived" ]
  # Exactly one K1 entry (no duplicate).
  n_k1="$(jq -r '[.findings[] | select(.key=="K1")] | length' "$SIDECAR")"
  [ "$n_k1" -eq 1 ]
  # K2 (prev-only, still-open) was ADDED.
  k2="$(jq -r '.findings[] | select(.key=="K2") | .disposition' "$SIDECAR")"
  [ "$k2" = "filed" ]
}

@test "seed-forward: fail-safe no-op on a missing prev sidecar" {
  printf '%s\n' '{"schema":1,"backend":"github","findings":[{"key":"K9","disposition":"filed"}]}' > "$SIDECAR"
  before="$(cat "$SIDECAR")"
  disposition_seed_forward "$BATS_TEST_TMPDIR/does-not-exist.json" "$SIDECAR"
  after="$(cat "$SIDECAR")"
  [ "$before" = "$after" ]
}

@test "seed-forward: fail-safe no-op on an unparseable prev sidecar" {
  PREV="$BATS_TEST_TMPDIR/prev.json"
  printf 'not json {' > "$PREV"
  rm -f "$SIDECAR"
  disposition_seed_forward "$PREV" "$SIDECAR"
  [ ! -f "$SIDECAR" ]
}

@test "seed-forward: fail-safe no-op when jq is unavailable" {
  PREV="$BATS_TEST_TMPDIR/prev.json"
  printf '%s\n' '{"schema":1,"backend":"github","findings":[{"key":"K1","disposition":"filed"}]}' > "$PREV"
  rm -f "$SIDECAR"
  mkdir -p "$BATS_TEST_TMPDIR/empty-bin"
  # PATH is scoped to the child bash -c subshell only: replacing it in the
  # test's own process would also strip PATH from bats-core's own post-test
  # cleanup step, which runs coreutils in this same process.
  run bash -c '
    PATH="$1"
    . "$2"
    disposition_seed_forward "$3" "$4"
  ' _ "$BATS_TEST_TMPDIR/empty-bin" "$LIB" "$PREV" "$SIDECAR"
  [ ! -f "$SIDECAR" ]
}

# ---------------------------------------------------------------------------
# Hook-level fixtures: a real git repo the digest engine's builtin classifier
# recognizes (app/ = frontend auditable base), no .gaia/audit-ci.yml (so the
# builtin roster applies, mirroring audit-digest-lib.bats).
# ---------------------------------------------------------------------------

git_init() {
  local d="$1"
  git -C "$d" init --quiet --initial-branch=main
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name "Test"
  git -C "$d" config commit.gpgsign false
}

seed_repo() {
  local d="$1"
  mkdir -p "$d/app" "$d/.gaia"
  git_init "$d"
  echo "export const x = 1;" > "$d/app/x.ts"
  printf '1.6.1\n' > "$d/.gaia/VERSION"
  git -C "$d" add -A
  git -C "$d" commit --quiet -m "seed"
}

frontend_digest_of() {
  local root="$1" ref="${2:-HEAD}"
  bash "$DIGEST_CLI" --root "$root" --member code-audit-frontend --ref "$ref"
}

# Write a schema-3 frontend earned clearance marker (C2) for <root> keyed to
# <digest>, dated from <root>'s current HEAD.
write_frontend_marker() {
  local root="$1" digest="$2" tree sha
  tree=$(git -C "$root" rev-parse "HEAD^{tree}")
  sha=$(git -C "$root" rev-parse HEAD)
  mkdir -p "$root/.gaia/local/audit"
  printf '{"version":"1.6.1","schema":3,"member":"code-audit-frontend","provenance":"earned","digest":"%s","tree":"%s","sha":"%s","audited_at":"2026-01-01T00:00:00Z","sidecar":true}\n' \
    "$digest" "$tree" "$sha" \
    > "$root/.gaia/local/audit/${digest}.ok"
}

# Run the REAL hook (by absolute path, so it resolves its own libs) with a
# `gh pr merge` command, cwd = <root>.
run_disposition_hook() {
  local root="$1" cmd="${2:-gh pr merge 30 --squash --delete-branch}" json
  json=$(jq -n --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}')
  run bash -c "cd '$root' && printf '%s' '$json' | bash '$HOOK_ABS'"
}

assert_allowed() {
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" && return 1
  return 0
}

assert_denied() {
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# Hook: fail-open cases preserved under digest keying
# ---------------------------------------------------------------------------

@test "hook: no frontend marker and no sidecar -> fail open (allow)" {
  ROOT="$BATS_TEST_TMPDIR/nomarker"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  run_disposition_hook "$ROOT"
  assert_allowed
}

@test "hook: no marker at all, but sidecar has a confirmed offender -> DENY (offender check is independent of marker state)" {
  ROOT="$BATS_TEST_TMPDIR/nomarkeroffender"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  digest="$(frontend_digest_of "$ROOT")"
  [ -n "$digest" ] || skip "could not derive digest"
  mkdir -p "$ROOT/.gaia/local/audit"
  printf '{"schema":1,"backend":"github","findings":[{"key":"v1 class=y path=b line=2","disposition":"filed"}]}\n' \
    > "$ROOT/.gaia/local/audit/${digest}.dispositions.json"
  install_gh_mock ok '[]'
  run_disposition_hook "$ROOT"
  assert_denied
  grep -qF -- "filed-but-missing: v1 class=y path=b line=2" <<<"$output" || return 1
}

@test "hook: a machinery_waived entry whose path IS machinery -> allow (no offender)" {
  ROOT="$BATS_TEST_TMPDIR/mwmachinery"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  digest="$(frontend_digest_of "$ROOT")"
  [ -n "$digest" ] || skip "could not derive digest"
  mkdir -p "$ROOT/.gaia/local/audit"
  printf '{"schema":1,"backend":"github","findings":[{"key":"v1 class=holistic/x path=.claude/hooks/lib/audit-machinery.sh line=1","disposition":"machinery_waived"}]}\n' \
    > "$ROOT/.gaia/local/audit/${digest}.dispositions.json"
  run_disposition_hook "$ROOT"
  assert_allowed
}

@test "hook: a machinery_waived entry whose path is NOT machinery -> DENY (abuse-check offender)" {
  ROOT="$BATS_TEST_TMPDIR/mwnotmachinery"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  digest="$(frontend_digest_of "$ROOT")"
  [ -n "$digest" ] || skip "could not derive digest"
  mkdir -p "$ROOT/.gaia/local/audit"
  printf '{"schema":1,"backend":"github","findings":[{"key":"v1 class=holistic/x path=app/x.ts line=1","disposition":"machinery_waived"}]}\n' \
    > "$ROOT/.gaia/local/audit/${digest}.dispositions.json"
  run_disposition_hook "$ROOT"
  assert_denied
  grep -qF -- "machinery-waived-not-machinery: v1 class=holistic/x path=app/x.ts line=1" <<<"$output" || return 1
}

@test "hook: sidecar present but unparseable -> fail open (allow)" {
  ROOT="$BATS_TEST_TMPDIR/badsidecar"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  digest="$(frontend_digest_of "$ROOT")"
  [ -n "$digest" ] || skip "could not derive digest"
  mkdir -p "$ROOT/.gaia/local/audit"
  printf 'not json {' > "$ROOT/.gaia/local/audit/${digest}.dispositions.json"
  run_disposition_hook "$ROOT"
  assert_allowed
}

@test "hook: sidecar backend absent -> fail open (allow) even with a filed entry" {
  ROOT="$BATS_TEST_TMPDIR/backendabsent"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  digest="$(frontend_digest_of "$ROOT")"
  [ -n "$digest" ] || skip "could not derive digest"
  mkdir -p "$ROOT/.gaia/local/audit"
  printf '{"schema":1,"backend":"absent","findings":[{"key":"K","disposition":"filed"}]}\n' \
    > "$ROOT/.gaia/local/audit/${digest}.dispositions.json"
  run_disposition_hook "$ROOT"
  assert_allowed
}

@test "hook: gh unreachable -> fail open (allow), no filed offender" {
  ROOT="$BATS_TEST_TMPDIR/ghfail"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  digest="$(frontend_digest_of "$ROOT")"
  [ -n "$digest" ] || skip "could not derive digest"
  mkdir -p "$ROOT/.gaia/local/audit"
  printf '{"schema":1,"backend":"github","findings":[{"key":"K","disposition":"filed"}]}\n' \
    > "$ROOT/.gaia/local/audit/${digest}.dispositions.json"
  install_gh_mock fail
  run_disposition_hook "$ROOT"
  assert_allowed
}

@test "hook: a marker valid for a rotated-away (stale) digest does not trigger the absent-sidecar arm -> allow" {
  ROOT="$BATS_TEST_TMPDIR/stalemarker"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  old_digest="$(frontend_digest_of "$ROOT")"
  [ -n "$old_digest" ] || skip "could not derive digest"
  write_frontend_marker "$ROOT" "$old_digest"
  # Rotate frontend-owned content: the marker above no longer matches HEAD's
  # current frontend digest, and no sidecar exists for either digest.
  printf 'export const y = 2;\n' >> "$ROOT/app/x.ts"
  git -C "$ROOT" commit -aqm "rotate"
  run_disposition_hook "$ROOT"
  assert_allowed
}

# ---------------------------------------------------------------------------
# Hook: the new fail-closed arms (C4)
# ---------------------------------------------------------------------------

@test "hook: valid frontend marker, sidecar absent -> DENY (new fail-closed arm)" {
  ROOT="$BATS_TEST_TMPDIR/markernosidecar"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  digest="$(frontend_digest_of "$ROOT")"
  [ -n "$digest" ] || skip "could not derive digest"
  write_frontend_marker "$ROOT" "$digest"
  run_disposition_hook "$ROOT"
  assert_denied
  grep -qF -- "sidecar" <<<"$output" || return 1
}

@test "hook: valid frontend marker, sidecar present and clean -> allow" {
  ROOT="$BATS_TEST_TMPDIR/markerclean"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  digest="$(frontend_digest_of "$ROOT")"
  [ -n "$digest" ] || skip "could not derive digest"
  write_frontend_marker "$ROOT" "$digest"
  mkdir -p "$ROOT/.gaia/local/audit"
  printf '{"schema":1,"backend":"github","findings":[]}\n' \
    > "$ROOT/.gaia/local/audit/${digest}.dispositions.json"
  run_disposition_hook "$ROOT"
  assert_allowed
}

@test "hook: digest cannot be derived (non-git root) -> DENY (fail closed)" {
  ROOT="$BATS_TEST_TMPDIR/nogit"
  mkdir -p "$ROOT"
  run_disposition_hook "$ROOT"
  assert_denied
  grep -qF -- "could not be derived" <<<"$output" || return 1
}

# ---------------------------------------------------------------------------
# COV-003 (own it here): the FULL production path -- rotate -> seed-forward ->
# gate-deny -- deriving both digests the SAME way the frontend agent does (the
# CLI entrypoint, not an isolated lib call). A wrong BASE_SHA or a wrong
# prev-digest derivation leaves the receipt un-seeded, so the gate would clear
# instead of deny; this test fails on that mistake rather than only in
# production. gh is stubbed per directive TST-007 to report the filed issue
# closed-as-declined: no OPEN-or-CLOSED tech-debt issue on the reachable
# backend still carries the key, exactly how a declined-and-delabeled issue
# reads to the substring dedup check.
#
# COV-002 (cross-reference, not proved here): this test proves seed-forward
# correctly propagates the open entry from a predecessor sidecar into the new
# one, and that the standalone gate then denies. The complementary half of the
# durability invariant -- that the janitor does NOT reap the predecessor
# sidecar once it is past the retention window because it still holds an open
# receipt -- is a time-controlled janitor test owned by task-janitor-noop.
# ---------------------------------------------------------------------------

@test "COV-003/COV-002: a still-open receipt survives a frontend-digest rotation through the full production path" {
  ROOT="$BATS_TEST_TMPDIR/cov003"
  mkdir -p "$ROOT"
  seed_repo "$ROOT"
  BASE_SHA="$(git -C "$ROOT" rev-parse HEAD)"

  # 1. At BASE_SHA the frontend files a still-open (filed) receipt into the
  #    sidecar keyed to the digest AT BASE_SHA, derived exactly the way the
  #    agent derives it: the CLI entrypoint, --ref BASE_SHA.
  prev_digest="$(bash "$DIGEST_CLI" --root "$ROOT" --member code-audit-frontend --ref "$BASE_SHA")"
  [ -n "$prev_digest" ] || return 1
  mkdir -p "$ROOT/.gaia/local/audit"
  prev_sidecar="$ROOT/.gaia/local/audit/${prev_digest}.dispositions.json"
  printf '%s\n' '{"schema":1,"backend":"github","findings":[{"key":"v1 class=y path=app/x.ts line=1","disposition":"filed"}]}' \
    > "$prev_sidecar"

  # 2. Rotate frontend-owned content to a new HEAD: a fresh incremental audit
  #    at this HEAD would not re-encounter the original finding.
  printf 'export const rotated = true;\n' >> "$ROOT/app/x.ts"
  git -C "$ROOT" commit -aqm "rotate frontend content"

  # 3. Derive the new frontend digest the same way, then seed-forward.
  new_digest="$(bash "$DIGEST_CLI" --root "$ROOT" --member code-audit-frontend --ref HEAD)"
  [ -n "$new_digest" ] || return 1
  [ "$new_digest" != "$prev_digest" ] || return 1
  new_sidecar="$ROOT/.gaia/local/audit/${new_digest}.dispositions.json"
  disposition_seed_forward "$prev_sidecar" "$new_sidecar"
  [ -f "$new_sidecar" ]
  grep -qF -- "v1 class=y path=app/x.ts line=1" "$new_sidecar" || return 1

  # A valid marker for the NEW digest, so the sidecar-absent arm cannot itself
  # explain the deny below: the sidecar is present, the deny must come from
  # the seeded-forward offender.
  write_frontend_marker "$ROOT" "$new_digest"

  # 4. Run the standalone gate at the new HEAD with gh stubbed per TST-007.
  install_gh_mock ok '[]'
  run_disposition_hook "$ROOT"
  assert_denied
  grep -qF -- "filed-but-missing: v1 class=y path=app/x.ts line=1" <<<"$output" || return 1
}
