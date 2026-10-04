#!/usr/bin/env bats

# The security fields check-updates.sh writes into the update-check cache,
# driven through a mock `gaia` binary that answers the advisories verb with a
# canned payload.
#
# Run via: bash .gaia/scripts/bats5.sh .gaia/scripts/tests/check-updates-security.bats < /dev/null

setup() {
  SCRIPTS_DIRECTORY="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  command -v jq >/dev/null 2>&1 || skip "jq required"

  REFRESH_ROOT="$(mktemp -d "$BATS_TEST_TMPDIR/root.XXXXXX")"
  REFRESH_ROOT="$(cd "$REFRESH_ROOT" && pwd -P)"
  mkdir -p "$REFRESH_ROOT/.gaia/scripts" "$REFRESH_ROOT/.gaia/cli" "$REFRESH_ROOT/.gaia/local/cache/shared" "$BATS_TEST_TMPDIR/bin"
  cp "$SCRIPTS_DIRECTORY/check-updates.sh" "$REFRESH_ROOT/.gaia/scripts/check-updates.sh"
  write_mock_gaia "$REFRESH_ROOT/.gaia/cli/gaia"
  write_stub_gh "$BATS_TEST_TMPDIR/bin/gh"

  CACHE_FILE="$REFRESH_ROOT/.gaia/local/cache/shared/update-check.json"
  export MOCK_LOG="$BATS_TEST_TMPDIR/advisories.log"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  unset MOCK_ADVISORIES_PAYLOAD MOCK_ADVISORIES_EXIT MOCK_ACTIONABLE
}

# A `gaia` stub: `update-deps run --emit-updates <file>` writes an
# actionable_count of $MOCK_ACTIONABLE (default 0); `update-deps advisories
# --emit <file>` logs one line, then writes $MOCK_ADVISORIES_PAYLOAD and exits
# $MOCK_ADVISORIES_EXIT (default 0). Everything else exits 1.
write_mock_gaia() {
  cat > "$1" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "update-deps" ] && [ "$2" = "run" ]; then
  output_path=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --emit-updates) output_path="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$output_path" ] && printf '{"actionable_count":%s}' "${MOCK_ACTIONABLE:-0}" > "$output_path"
  exit 0
fi
if [ "$1" = "update-deps" ] && [ "$2" = "advisories" ]; then
  printf 'advisories %s\n' "$*" >> "$MOCK_LOG"
  output_path=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --emit) output_path="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "${MOCK_ADVISORIES_PAYLOAD:-}" ] && [ -n "$output_path" ] && printf '%s' "$MOCK_ADVISORIES_PAYLOAD" > "$output_path"
  exit "${MOCK_ADVISORIES_EXIT:-0}"
fi
exit 1
EOF
  chmod +x "$1"
}

write_stub_gh() {
  cat > "$1" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  release) printf 'v0.0.0\n'; exit 0 ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$1"
}

run_refresher() {
  run bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh" < /dev/null
  [ "$status" -eq 0 ]
  [ -s "$CACHE_FILE" ]
}

assert_security() {
  [ "$(jq -c '.securityCount' "$CACHE_FILE")" = "$1" ]
  [ "$(jq -r '.securitySource' "$CACHE_FILE")" = "$2" ]
  [ "$(jq -r '.securityUnavailableReason' "$CACHE_FILE")" = "$3" ]
}

@test "dependabot payload caches its count and an empty reason" {
  export MOCK_ADVISORIES_PAYLOAD='{"version":1,"source":"dependabot","count":2,"reasons":[]}'
  run_refresher
  assert_security 2 dependabot ""
}

@test "pnpm-audit payload caches its count with the alerts reason" {
  export MOCK_ADVISORIES_PAYLOAD='{"version":1,"source":"pnpm-audit","count":2,"reasons":["forbidden"]}'
  run_refresher
  assert_security 2 pnpm-audit forbidden
}

@test "unavailable payload caches null with its joined reasons" {
  export MOCK_ADVISORIES_PAYLOAD='{"version":1,"source":"unavailable","count":null,"reasons":["forbidden","pnpm-audit-failed"]}'
  run_refresher
  assert_security null unavailable "forbidden,pnpm-audit-failed"
}

@test "the refresh asks for the count only" {
  export MOCK_ADVISORIES_PAYLOAD='{"version":1,"source":"dependabot","count":0,"reasons":[]}'
  run_refresher
  grep -qF -- "--count-only" "$MOCK_LOG"
}

@test "a failing advisories verb overwrites a prior count with null" {
  printf '{"checkedAt":1,"securityCount":3,"securitySource":"dependabot","securityUnavailableReason":""}' > "$CACHE_FILE"
  export MOCK_ADVISORIES_EXIT=1
  export MOCK_ADVISORIES_PAYLOAD='{"version":1,"source":"dependabot","count":3,"reasons":[]}'
  run_refresher
  assert_security null unavailable cli-failed
}

@test "an empty payload writes null and cli-failed" {
  unset MOCK_ADVISORIES_PAYLOAD
  run_refresher
  assert_security null unavailable cli-failed
}

@test "an invalid payload writes null and cli-failed" {
  export MOCK_ADVISORIES_PAYLOAD='not json'
  run_refresher
  assert_security null unavailable cli-failed
}

@test "a source outside the known set maps to unavailable and cli-failed" {
  export MOCK_ADVISORIES_PAYLOAD='{"version":1,"source":"evil","count":5,"reasons":[]}'
  run_refresher
  assert_security null unavailable cli-failed
  grep -qF -- "evil" "$CACHE_FILE" && return 1
  true
}

@test "a non-integer count maps to unavailable and cli-failed" {
  export MOCK_ADVISORIES_PAYLOAD='{"version":1,"source":"dependabot","count":1.5,"reasons":[]}'
  run_refresher
  assert_security null unavailable cli-failed
}

@test "a reason token outside the closed set is dropped and never executed" {
  export MOCK_ADVISORIES_PAYLOAD='{"version":1,"source":"pnpm-audit","count":1,"reasons":["$(touch pwned)","forbidden"]}'
  cd "$BATS_TEST_TMPDIR"
  run_refresher
  assert_security 1 pnpm-audit forbidden
  grep -qF -- 'touch' "$CACHE_FILE" && return 1
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
  [ ! -e "$REFRESH_ROOT/pwned" ]
}

@test "the cache parses and records jq-missing when jq is not on PATH" {
  local hidden_bin="$BATS_TEST_TMPDIR/nojq"
  local tool tool_path
  mkdir -p "$hidden_bin"
  for tool in bash env date mktemp mkdir cat find rm mv tr dirname sort tail head grep sed git wc cp ls pwd printf sleep curl; do
    tool_path="$(command -v "$tool" 2>/dev/null)" || continue
    case "$tool_path" in
      /*) ln -sf "$tool_path" "$hidden_bin/$tool" ;;
    esac
  done
  [ ! -e "$hidden_bin/jq" ]
  run env PATH="$hidden_bin" "$BASH" "$REFRESH_ROOT/.gaia/scripts/check-updates.sh" < /dev/null
  [ "$status" -eq 0 ]
  [ -s "$CACHE_FILE" ]
  assert_security null unavailable jq-missing
}

@test "a fresh cache with no securitySource is refreshed once" {
  export MOCK_ADVISORIES_PAYLOAD='{"version":1,"source":"dependabot","count":4,"reasons":[]}'
  printf '{"checkedAt":%s,"outdatedCount":0}' "$(date +%s)" > "$CACHE_FILE"
  run_refresher
  [ -s "$MOCK_LOG" ]
  assert_security 4 dependabot ""
}

@test "a fresh cache that has securitySource is not refreshed" {
  export MOCK_ADVISORIES_PAYLOAD='{"version":1,"source":"dependabot","count":4,"reasons":[]}'
  printf '{"checkedAt":%s,"outdatedCount":0,"securityCount":1,"securitySource":"dependabot","securityUnavailableReason":""}' "$(date +%s)" > "$CACHE_FILE"
  run bash "$REFRESH_ROOT/.gaia/scripts/check-updates.sh" < /dev/null
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_LOG" ]
  [ "$(jq -c '.securityCount' "$CACHE_FILE")" = "1" ]
}

@test "a security-only advisory still caches its count when nothing is outdated" {
  export MOCK_ACTIONABLE=0
  export MOCK_ADVISORIES_PAYLOAD='{"version":1,"source":"dependabot","count":1,"reasons":[]}'
  run_refresher
  [ "$(jq -c '.outdatedCount' "$CACHE_FILE")" = "0" ]
  assert_security 1 dependabot ""

  local home_directory="$BATS_TEST_TMPDIR/home"
  mkdir -p "$home_directory" "$REFRESH_ROOT/.gaia/statusline"
  cp "$SCRIPTS_DIRECTORY/../statusline/gaia-statusline.sh" "$REFRESH_ROOT/.gaia/statusline/gaia-statusline.sh"
  git -C "$REFRESH_ROOT" init --quiet --initial-branch=main
  git -C "$REFRESH_ROOT" config user.email t@t.t
  git -C "$REFRESH_ROOT" config user.name t
  git -C "$REFRESH_ROOT" config commit.gpgsign false
  printf 'x\n' > "$REFRESH_ROOT/README.md"
  git -C "$REFRESH_ROOT" add README.md
  git -C "$REFRESH_ROOT" commit --quiet -m init
  printf '{"completed_at":"2026-01-01T00:00:00Z"}' > "$REFRESH_ROOT/.gaia/local/setup-state.json"
  local payload
  payload=$(jq -n --arg directory "$REFRESH_ROOT" '{workspace: {current_dir: $directory}, cwd: $directory, model: {display_name: "Test"}, context_window: {used_percentage: 10}}')
  run env HOME="$home_directory" COLUMNS=200 bash -c "printf '%s' '$payload' | bash '$REFRESH_ROOT/.gaia/statusline/gaia-statusline.sh'"
  [ "$status" -eq 0 ]
  plain=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
  case "$plain" in
    *"Run /update-deps (1 security)"*) ;;
    *) return 1 ;;
  esac
}
