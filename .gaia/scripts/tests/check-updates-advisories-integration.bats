#!/usr/bin/env bats

# The real committed `.gaia/cli/gaia` bundle driven end to end through
# `check-updates.sh`, with `gh` and `pnpm` stubbed on PATH. The mock-CLI suite
# (check-updates-security.bats) proves the shell maps a payload; this one proves
# the shipped binary's payload and the shell agree, and that a stale bundle or a
# payload-shape drift fails here.
#
# Only `gaia update-deps advisories` and `write-security-cache` reach the real
# bundle. The wrapper at the path check-updates.sh resolves answers every other
# subcommand with the canned output the mock-CLI suite uses, because the real
# `update-deps run` would need registry stubs for every package.
#
# Run via: bash .gaia/scripts/bats5.sh .gaia/scripts/tests/check-updates-advisories-integration.bats < /dev/null

setup() {
  SCRIPTS_DIRECTORY="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  REAL_BUNDLE="$(cd "$SCRIPTS_DIRECTORY/../cli" && pwd)/gaia"
  command -v jq >/dev/null 2>&1 || skip "jq required"
  command -v node >/dev/null 2>&1 || skip "node required"
  [ -x "$REAL_BUNDLE" ] || skip "committed CLI bundle missing"

  # A CI runner exports these, which would make the real verb skip alerts in
  # every test that does not mean to.
  unset CI GITHUB_ACTIONS

  SCRATCH_ROOT="$(mktemp -d "$BATS_TEST_TMPDIR/root.XXXXXX")"
  SCRATCH_ROOT="$(cd "$SCRATCH_ROOT" && pwd -P)"
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$SCRATCH_ROOT/.gaia/scripts" "$SCRATCH_ROOT/.gaia/cli" "$SCRATCH_ROOT/.gaia/local/cache/shared" "$STUB_BIN"
  cp "$SCRIPTS_DIRECTORY/check-updates.sh" "$SCRATCH_ROOT/.gaia/scripts/check-updates.sh"
  cp "$SCRIPTS_DIRECTORY/main-root-lib.sh" "$SCRATCH_ROOT/.gaia/scripts/main-root-lib.sh"
  cp "$REAL_BUNDLE" "$SCRATCH_ROOT/.gaia/cli/gaia-real"
  write_wrapper_gaia "$SCRATCH_ROOT/.gaia/cli/gaia"
  write_stub_gh "$STUB_BIN/gh"
  write_stub_pnpm "$STUB_BIN/pnpm"

  git -C "$SCRATCH_ROOT" init --quiet --initial-branch=main
  git -C "$SCRATCH_ROOT" config user.email t@t.t
  git -C "$SCRATCH_ROOT" config user.name t
  git -C "$SCRATCH_ROOT" config commit.gpgsign false
  git -C "$SCRATCH_ROOT" remote add origin git@github.com:acme/widgets.git
  printf '{"name":"widgets","private":true}\n' > "$SCRATCH_ROOT/package.json"
  printf 'packages: []\n' > "$SCRATCH_ROOT/pnpm-workspace.yaml"
  write_lockfile "$SCRATCH_ROOT/pnpm-lock.yaml"
  git -C "$SCRATCH_ROOT" add package.json pnpm-workspace.yaml pnpm-lock.yaml
  git -C "$SCRATCH_ROOT" commit --quiet -m init

  CACHE_FILE="$SCRATCH_ROOT/.gaia/local/cache/shared/update-check.json"
  export STUB_GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  export STUB_PNPM_LOG="$BATS_TEST_TMPDIR/pnpm.log"
  export STUB_OPEN_ALERTS_FILE="$BATS_TEST_TMPDIR/open-alerts.json"
  export STUB_DISMISSED_ALERTS_FILE="$BATS_TEST_TMPDIR/dismissed-alerts.json"
  export STUB_PNPM_AUDIT_FILE="$BATS_TEST_TMPDIR/audit.json"
  export MOCK_ACTIONABLE=0
  unset STUB_GH_FAIL STUB_PNPM_AUDIT_STATUS
  export PATH="$STUB_BIN:$PATH"
  printf '[]\n' > "$STUB_OPEN_ALERTS_FILE"
  printf '[]\n' > "$STUB_DISMISSED_ALERTS_FILE"
  : > "$STUB_GH_LOG"
}

# Answers `update-deps advisories` and `write-security-cache` with the real
# bundle and every other subcommand with the canned output the mock-CLI suite
# uses.
write_wrapper_gaia() {
  cat > "$1" <<'EOF'
#!/usr/bin/env bash
real="$(dirname "$0")/gaia-real"
if [ "$1" = "update-deps" ] && { [ "$2" = "advisories" ] || [ "$2" = "write-security-cache" ]; }; then
  exec "$real" "$@"
fi
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
exit 1
EOF
  chmod +x "$1"
}

# Answers the two alert listings from fixture files, or fails with the status
# in STUB_GH_FAIL and an HTTP 403 line. `release` is the version lookup
# check-updates.sh makes; any other call fails loudly. Every argv is logged.
write_stub_gh() {
  cat > "$1" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_GH_LOG"
if [ "$1" = "release" ]; then
  printf 'v0.0.0\n'
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "--paginate" ]; then
  if [ -n "${STUB_GH_FAIL:-}" ]; then
    printf 'gh: HTTP 403: Forbidden\n' >&2
    exit "$STUB_GH_FAIL"
  fi
  case "$3" in
    "repos/acme/widgets/dependabot/alerts?state=open&"*) cat "$STUB_OPEN_ALERTS_FILE"; exit 0 ;;
    "repos/acme/widgets/dependabot/alerts?state=dismissed,auto_dismissed&"*) cat "$STUB_DISMISSED_ALERTS_FILE"; exit 0 ;;
  esac
fi
printf 'gh stub: unexpected call: %s\n' "$*" >&2
exit 99
EOF
  chmod +x "$1"
}

# `pnpm audit --json` prints the audit fixture and exits with
# STUB_PNPM_AUDIT_STATUS (default 0); with no fixture it prints nothing and
# exits 1. Every other call exits 1.
write_stub_pnpm() {
  cat > "$1" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_PNPM_LOG"
if [ "$1" = "audit" ]; then
  if [ -s "$STUB_PNPM_AUDIT_FILE" ]; then
    cat "$STUB_PNPM_AUDIT_FILE"
    exit "${STUB_PNPM_AUDIT_STATUS:-0}"
  fi
  exit 1
fi
exit 1
EOF
  chmod +x "$1"
}

# The real root lockfile's two-document shape: pnpm's own self-lockfile first,
# carrying a same-named decoy of the advisory package, then the project graph
# holding the installed versions. A reader that takes the first `packages:`
# block reports the decoy.
write_lockfile() {
  cat > "$1" <<'EOF'
---
lockfileVersion: '9.0'

importers:

  .:
    configDependencies: {}
    packageManagerDependencies:
      pnpm:
        specifier: 12.7.0
        version: 12.7.0

packages:

  '@pnpm/exe.darwin-arm64@12.7.0':
    resolution: {integrity: sha512-fixture}
    cpu: [arm64]
    os: [darwin]

  'widgetlib@0.0.1':
    resolution: {integrity: sha512-fixture}

---
lockfileVersion: '9.0'

settings:
  autoInstallPeers: true

importers:

  .:
    dependencies:
      widgetlib:
        specifier: 1.0.0
        version: 1.0.0
      gadgetlib:
        specifier: 1.0.0
        version: 1.0.0

packages:

  'widgetlib@1.0.0':
    resolution: {integrity: sha512-fixture}

  'gadgetlib@1.0.0':
    resolution: {integrity: sha512-fixture}
EOF
}

GHSA_A="GHSA-2222-2222-2222"
GHSA_B="GHSA-3333-3333-3333"
GHSA_C="GHSA-4444-4444-4444"

# alert_record <number> <ghsa> <package> <manifest path> [extra advisory key]
alert_record() {
  jq -cn --argjson number "$1" --arg ghsa "$2" --arg package "$3" --arg manifest "$4" '{
    number: $number,
    state: "open",
    dependency: {package: {ecosystem: "npm", name: $package}, manifest_path: $manifest, scope: "runtime", relationship: "direct"},
    security_advisory: {ghsa_id: $ghsa, severity: "high", epss: [{percentage: 0.5}]},
    security_vulnerability: {vulnerable_version_range: "< 2.0.0", first_patched_version: {identifier: "2.0.0"}}
  }'
}

# audit_advisory <pnpm id> <ghsa> <package>
audit_advisory() {
  jq -cn --argjson id "$1" --arg ghsa "$2" --arg package "$3" '{
    id: $id, github_advisory_id: $ghsa, module_name: $package, severity: "high",
    vulnerable_versions: "<2.0.0", patched_versions: ">=2.0.0",
    findings: [{version: "1.0.0", paths: [(".>" + $package)]}]
  }'
}

# write_alerts <file> <alert record>...
write_alerts() {
  local file="$1"
  shift
  printf '%s\n' "$@" | jq -s '.' > "$file"
}

# write_audit <file> <audit advisory object>...  (keyed by each record's id)
write_audit() {
  local file="$1"
  shift
  printf '%s\n' "$@" | jq -s '{advisories: (map({key: (.id | tostring), value: .}) | from_entries)}' > "$file"
}

# Three open alerts naming two GHSA ids, all on owned manifests.
seed_three_alerts_two_ids() {
  write_alerts "$STUB_OPEN_ALERTS_FILE" \
    "$(alert_record 1 "$GHSA_A" widgetlib pnpm-lock.yaml)" \
    "$(alert_record 2 "$GHSA_A" widgetlib package.json)" \
    "$(alert_record 3 "$GHSA_B" gadgetlib pnpm-lock.yaml)"
}

# Three pnpm advisories, one acknowledged in the baseline by its pnpm id.
seed_fallback_three_one_acknowledged() {
  export STUB_GH_FAIL=1
  export STUB_PNPM_AUDIT_STATUS=1
  write_audit "$STUB_PNPM_AUDIT_FILE" \
    "$(audit_advisory 1000001 "$GHSA_A" widgetlib)" \
    "$(audit_advisory 1000002 "$GHSA_B" gadgetlib)" \
    "$(audit_advisory 1000003 "$GHSA_C" gadgetlib)"
  mkdir -p "$SCRATCH_ROOT/.gaia/local"
  printf '{"acknowledged":[{"id":1000002}]}\n' > "$SCRATCH_ROOT/.gaia/local/dep-audit-baseline.json"
}

write_old_cache() {
  printf '{"checkedAt":1,"outdatedCount":0,"securityCount":3,"securitySource":"dependabot","securityUnavailableReason":""}' > "$CACHE_FILE"
}

run_refresher() {
  run bash "$SCRATCH_ROOT/.gaia/scripts/check-updates.sh" < /dev/null
  [ "$status" -eq 0 ]
  [ -s "$CACHE_FILE" ]
}

assert_security() {
  [ "$(jq -c '.securityCount' "$CACHE_FILE")" = "$1" ]
  [ "$(jq -r '.securitySource' "$CACHE_FILE")" = "$2" ]
  [ "$(jq -r '.securityUnavailableReason' "$CACHE_FILE")" = "$3" ]
}

# The real verb in the scratch tree. Extra arguments follow --emit.
run_verb() {
  local output_path="$1"
  shift
  (cd "$SCRATCH_ROOT" && "$SCRATCH_ROOT/.gaia/cli/gaia-real" update-deps advisories --emit "$output_path" "$@")
}

security_fields() {
  jq -c '[.securityCount, .securitySource, .securityUnavailableReason]' "$CACHE_FILE"
}

# The skill's cache rewrite after its report: the count, source, and reasons of
# a count-only run, handed to write-security-cache.
run_final_sequence() {
  local payload="$BATS_TEST_TMPDIR/final.json" count source reasons
  local -a arguments
  run_verb "$payload" --count-only
  count="$(jq -r '.count' "$payload")"
  source="$(jq -r '.source' "$payload")"
  reasons="$(jq -r '.reasons | join(",")' "$payload")"
  arguments=(--count "$count" --source "$source")
  [ -n "$reasons" ] && arguments+=(--reason "$reasons")
  (cd "$SCRATCH_ROOT" && "$SCRATCH_ROOT/.gaia/cli/gaia-real" update-deps write-security-cache "${arguments[@]}") > /dev/null
}

# The twin of run_final_sequence that hands write-security-cache the report's
# raw final-tree advisory count, ignoring the baseline.
run_final_sequence_with_raw_count() {
  local payload="$BATS_TEST_TMPDIR/raw.json" count source reasons
  local -a arguments
  run_verb "$payload"
  count="$(jq -r '.advisories | length' "$payload")"
  source="$(jq -r '.source' "$payload")"
  reasons="$(jq -r '.reasons | join(",")' "$payload")"
  arguments=(--count "$count" --source "$source")
  [ -n "$reasons" ] && arguments+=(--reason "$reasons")
  (cd "$SCRATCH_ROOT" && "$SCRATCH_ROOT/.gaia/cli/gaia-real" update-deps write-security-cache "${arguments[@]}") > /dev/null
}

# Fails when the refresh's fields differ from the sequence's.
fields_agree() {
  [ "$1" = "$2" ] || {
    echo "refresh wrote $1 but the final sequence wrote $2" >&2
    return 1
  }
}

# Refreshes from a seeded stale cache and returns the fields it wrote.
refresh_fields() {
  write_old_cache
  run_refresher
  security_fields
}

@test "two GHSA ids across three open alerts cache a count of 2 from dependabot" {
  seed_three_alerts_two_ids
  run_refresher
  assert_security 2 dependabot ""
}

@test "a forbidden alerts call falls back to pnpm audit minus the baseline-acknowledged advisory" {
  seed_fallback_three_one_acknowledged
  run_refresher
  [ "$(jq -c '.securityCount' "$CACHE_FILE")" = "2" ]
  [ "$(jq -r '.securitySource' "$CACHE_FILE")" = "pnpm-audit" ]
  jq -r '.securityUnavailableReason' "$CACHE_FILE" | grep -qF -- "forbidden"
}

@test "with no source answering a prior count becomes null, never the old count and never 0" {
  write_old_cache
  export STUB_GH_FAIL=1
  run_refresher
  [ "$(jq -c '.securityCount' "$CACHE_FILE")" = "null" ]
  [ "$(jq -r '.securitySource' "$CACHE_FILE")" = "unavailable" ]
  [ -n "$(jq -r '.securityUnavailableReason' "$CACHE_FILE")" ]
  [ "$(jq -c '.securityCount' "$CACHE_FILE")" != "3" ]
  [ "$(jq -c '.securityCount' "$CACHE_FILE")" != "0" ]
  # The prior cache is what made the null a change: the stub saw the attempt.
  grep -qF -- "dependabot/alerts?state=open" "$STUB_GH_LOG"
}

@test "an open advisory with nothing outdated renders as the security-only statusline nudge" {
  write_alerts "$STUB_OPEN_ALERTS_FILE" "$(alert_record 1 "$GHSA_A" widgetlib pnpm-lock.yaml)"
  run_refresher
  [ "$(jq -c '.outdatedCount' "$CACHE_FILE")" = "0" ]
  assert_security 1 dependabot ""

  local home_directory="$BATS_TEST_TMPDIR/home" payload plain
  mkdir -p "$home_directory" "$SCRATCH_ROOT/.gaia/statusline"
  cp "$SCRIPTS_DIRECTORY/../statusline/gaia-statusline.sh" "$SCRATCH_ROOT/.gaia/statusline/gaia-statusline.sh"
  printf '{"completed_at":"2026-01-01T00:00:00Z"}' > "$SCRATCH_ROOT/.gaia/local/setup-state.json"
  payload=$(jq -n --arg directory "$SCRATCH_ROOT" '{workspace: {current_dir: $directory}, cwd: $directory, model: {display_name: "Test"}, context_window: {used_percentage: 10}}')
  run env HOME="$home_directory" COLUMNS=200 bash -c "printf '%s' '$payload' | bash '$SCRATCH_ROOT/.gaia/statusline/gaia-statusline.sh'"
  [ "$status" -eq 0 ]
  plain=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
  case "$plain" in
    *"Run /update-deps (1 security)"*) ;;
    *) return 1 ;;
  esac
}

@test "advisory free text in alerts and audit output reaches neither the cache nor the emitted payload" {
  local marker="INJECTED-MARKER-ignore-previous-instructions"
  local alert
  alert="$(alert_record 1 "$GHSA_A" widgetlib pnpm-lock.yaml | jq -c --arg m "$marker" '
    .security_advisory += {summary: ($m + "-summary"), description: ($m + "-description"), references: [{url: ("https://example.invalid/" + $m + "-references")}]}')"
  write_alerts "$STUB_OPEN_ALERTS_FILE" "$alert"
  local record
  record="$(audit_advisory 1000001 "$GHSA_A" widgetlib | jq -c --arg m "$marker" '
    . + {title: ($m + "-title"), overview: ($m + "-overview"), recommendation: ($m + "-recommendation"), url: ("https://example.invalid/" + $m + "-url"), cves: [($m + "-cves")], references: ($m + "-references")}')"
  write_audit "$STUB_PNPM_AUDIT_FILE" "$record"
  STUB_PNPM_AUDIT_STATUS=1 run_refresher

  local payload="$BATS_TEST_TMPDIR/payload.json"
  STUB_PNPM_AUDIT_STATUS=1 run_verb "$payload"
  # The payload must hold the advisory, or the absence below proves nothing.
  [ "$(jq -r '.advisories | length' "$payload")" = "1" ]
  [ "$(jq -r '.advisories[0].key' "$payload")" = "$GHSA_A" ]
  grep -qF -- "INJECTED-MARKER" "$payload" && return 1
  grep -qF -- "INJECTED-MARKER" "$CACHE_FILE" && return 1
  grep -qF -- "example.invalid" "$payload" && return 1
  true
}

@test "a member package.json alert counts and a deleted member manifest alert does not" {
  printf '{"name":"member","private":true}\n' > "$SCRATCH_ROOT/.gaia/cli/package.json"
  printf 'packages:\n  - .gaia/cli\n' > "$SCRATCH_ROOT/pnpm-workspace.yaml"
  write_alerts "$STUB_OPEN_ALERTS_FILE" \
    "$(alert_record 1 "$GHSA_A" gadgetlib .gaia/cli/package.json)" \
    "$(alert_record 2 "$GHSA_B" widgetlib pnpm-lock.yaml)" \
    "$(alert_record 3 "$GHSA_C" gadgetlib .gaia/cli/pnpm-lock.yaml)"
  run_refresher
  assert_security 2 dependabot ""
}

@test "a CI run skips alerts without spawning gh" {
  write_alerts "$STUB_OPEN_ALERTS_FILE" "$(alert_record 1 "$GHSA_A" widgetlib pnpm-lock.yaml)"
  write_audit "$STUB_PNPM_AUDIT_FILE" "$(audit_advisory 1000001 "$GHSA_A" widgetlib)"
  local payload="$BATS_TEST_TMPDIR/ci.json"
  CI=true STUB_PNPM_AUDIT_STATUS=1 run_verb "$payload" --count-only
  [ "$(jq -r '.reasons[0]' "$payload")" = "ci" ]
  [ ! -s "$STUB_GH_LOG" ]
}

@test "the same run outside CI does call gh, so the empty CI log means something" {
  write_alerts "$STUB_OPEN_ALERTS_FILE" "$(alert_record 1 "$GHSA_A" widgetlib pnpm-lock.yaml)"
  local payload="$BATS_TEST_TMPDIR/not-ci.json"
  run_verb "$payload" --count-only
  [ "$(jq -r '.source' "$payload")" = "dependabot" ]
  [ -s "$STUB_GH_LOG" ]
  grep -qF -- "dependabot/alerts?state=open" "$STUB_GH_LOG"
}

@test "a previously dismissed alert is listed as dismissed and never reported open" {
  write_alerts "$STUB_OPEN_ALERTS_FILE" "$(alert_record 1 "$GHSA_A" widgetlib pnpm-lock.yaml)"
  write_alerts "$STUB_DISMISSED_ALERTS_FILE" "$(alert_record 2 "$GHSA_B" gadgetlib pnpm-lock.yaml | jq -c '.state = "dismissed"')"
  write_audit "$STUB_PNPM_AUDIT_FILE" \
    "$(audit_advisory 1000001 "$GHSA_A" widgetlib)" \
    "$(audit_advisory 1000002 "$GHSA_B" gadgetlib)"
  export STUB_PNPM_AUDIT_STATUS=1

  local payload="$BATS_TEST_TMPDIR/dismissed.json"
  run_verb "$payload"
  [ "$(jq -c '.dismissedGhsas' "$payload")" = "[\"$GHSA_B\"]" ]
  [ "$(jq -r '.count' "$payload")" = "1" ]
  [ "$(jq -r --arg key "$GHSA_B" '[.advisories[] | select(.key == $key)] | length' "$payload")" = "0" ]
  [ "$(jq -r --arg key "$GHSA_A" '[.advisories[] | select(.key == $key)] | length' "$payload")" = "1" ]
  # Installed versions come from the project document, never the decoy.
  [ "$(jq -c --arg key "$GHSA_A" '.advisories[] | select(.key == $key) | .installedVersions' "$payload")" = '["1.0.0"]' ]

  run_refresher
  assert_security 1 dependabot ""
}

@test "with no dismissed alerts the dismissed list is empty, so the exclusion was the dismissed data" {
  write_alerts "$STUB_OPEN_ALERTS_FILE" "$(alert_record 1 "$GHSA_A" widgetlib pnpm-lock.yaml)"
  write_audit "$STUB_PNPM_AUDIT_FILE" \
    "$(audit_advisory 1000001 "$GHSA_A" widgetlib)" \
    "$(audit_advisory 1000002 "$GHSA_B" gadgetlib)"
  export STUB_PNPM_AUDIT_STATUS=1

  local payload="$BATS_TEST_TMPDIR/not-dismissed.json"
  run_verb "$payload"
  [ "$(jq -c '.dismissedGhsas' "$payload")" = "[]" ]
  [ "$(jq -r '.source' "$payload")" = "dependabot" ]
}

@test "the refresh and the skill's final cache rewrite agree on the alerts count" {
  seed_three_alerts_two_ids
  local refreshed rewritten
  refreshed="$(refresh_fields)"
  [ "$refreshed" = '[2,"dependabot",""]' ]

  write_old_cache
  run_final_sequence
  rewritten="$(security_fields)"
  fields_agree "$refreshed" "$rewritten"
}

@test "the refresh and the skill's final cache rewrite agree on the pnpm audit fallback" {
  seed_fallback_three_one_acknowledged
  local refreshed rewritten
  refreshed="$(refresh_fields)"
  [ "$refreshed" = '[2,"pnpm-audit","forbidden"]' ]

  write_old_cache
  run_final_sequence
  rewritten="$(security_fields)"
  fields_agree "$refreshed" "$rewritten"
}

@test "passing the raw advisory count to the cache rewrite disagrees with the refresh" {
  seed_fallback_three_one_acknowledged
  local refreshed rewritten
  refreshed="$(refresh_fields)"

  write_old_cache
  run_final_sequence_with_raw_count
  rewritten="$(security_fields)"
  [ "$rewritten" = '[3,"pnpm-audit","forbidden"]' ]

  run fields_agree "$refreshed" "$rewritten"
  [ "$status" -eq 1 ]
}
