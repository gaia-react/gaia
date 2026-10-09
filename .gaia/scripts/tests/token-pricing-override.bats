#!/usr/bin/env bats
#
# The local rate override: <main>/.gaia/local/telemetry/token-rates.override.json
# overlays the distributed rate table row by row, an unparseable override is
# ignored with one marker line, a seeded machine-local table is never read, and
# no readout opens a network connection.
#
# Fixture rates (per million tokens): the distributed table prices claude-aaa-1
# at input 1 / output 5. The valid override re-prices it at 3 / 15 and adds
# claude-ccc-1 at 4 / 20. claude-zzz-1 is in neither table. The ledger holds
# one segment per model:
#   aaa  1,000,000 input + 100,000 output
#   ccc    500,000 input +  50,000 output
#   zzz    100,000 input +  10,000 output
# Override valid:  aaa 3.00 + 1.50, ccc 2.00 + 1.00 = $7.50 (zzz unpriced).
# Override ignored: aaa 1.00 + 0.50 = $1.50 (ccc and zzz unpriced).
#
# The GAIA_RATES_* exports below keep the pricing-path hermeticity guard
# (token-rates-hermetic.bats) satisfied for a suite that names usage.sh.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/token-pricing-override.bats

bats_require_minimum_version 1.5.0

setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  USAGE="$SCRIPTS/usage.sh"
  FIXTURES_DIRECTORY="$BATS_TEST_DIRNAME/fixtures/pricing"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  MAIN="$TEMPORARY_DIRECTORY/main"
  TELEMETRY_DIRECTORY="$MAIN/.gaia/local/telemetry"
  OVERRIDE_PATH="$TELEMETRY_DIRECTORY/token-rates.override.json"
  mkdir -p "$MAIN/.claude" "$TELEMETRY_DIRECTORY" "$TEMPORARY_DIRECTORY/projects" "$TEMPORARY_DIRECTORY/bin"
  git -C "$MAIN" init -q -b main
  cat >"$MAIN/.claude/settings.json" <<'EOF'
{"hooks": {
  "Stop": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/usage-capture.sh"}]}],
  "SessionStart": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/usage-capture.sh"}]}]
}}
EOF
  cp "$FIXTURES_DIRECTORY/usage.jsonl" "$FIXTURES_DIRECTORY/links.jsonl" "$TELEMETRY_DIRECTORY/"
  SENTINEL="$TEMPORARY_DIRECTORY/network-sentinel"
  : >"$SENTINEL"
  local tool_name
  for tool_name in curl wget nc; do
    printf '#!/bin/sh\necho "%s $*" >>"%s"\nexit 1\n' "$tool_name" "$SENTINEL" >"$TEMPORARY_DIRECTORY/bin/$tool_name"
    chmod +x "$TEMPORARY_DIRECTORY/bin/$tool_name"
  done
  export PATH="$TEMPORARY_DIRECTORY/bin:$PATH"
  unset CLAUDE_CODE_SESSION_ID GAIA_TALLY_PROJECTS_ROOT
}

# run_pr [usage.sh script]: the PR readout over the fixture ledger, priced from
# the fixture distributed table.
run_pr() {
  bash "${1:-$USAGE}" pr 601 --main-root "$MAIN" --rate-table "$FIXTURES_DIRECTORY/rates-distributed.json" \
    --projects-root "$TEMPORARY_DIRECTORY/projects"
}

install_override() { cp "$FIXTURES_DIRECTORY/$1" "$OVERRIDE_PATH"; }

has_line() { grep -qxF -- "$1" <<<"$output" || { printf 'missing line: [%s]\nin:\n%s\n' "$1" "$output" >&2; return 1; }; }

line_count() { grep -cxF -- "$1" <<<"$output" || true; }

assert_no_network() {
  [ ! -s "$SENTINEL" ] || { printf 'a network tool was called:\n%s\n' "$(cat "$SENTINEL")" >&2; return 1; }
}

RATE_MARKER='  ! rate override ignored (unparseable): .gaia/local/telemetry/token-rates.override.json'

@test "override valid: both overridden models use the override prices and the third is a lower bound" {
  install_override override-valid.json
  run run_pr
  [ "$status" -eq 0 ]
  has_line "  est. cost (USD): \$7.50"
  has_line "  ! lower bound: unpriced model(s) claude-zzz-1"
  [ "$(line_count "$RATE_MARKER")" -eq 0 ]
  assert_no_network
}

@test "override unparseable: invalid JSON prints one marker and prices from the distributed table" {
  install_override override-invalid-json.json
  run run_pr
  [ "$status" -eq 0 ]
  [ "$(line_count "$RATE_MARKER")" -eq 1 ]
  has_line "  est. cost (USD): \$1.50"
  has_line "  ! lower bound: unpriced model(s) claude-ccc-1, claude-zzz-1"
  assert_no_network
}

@test "override unparseable: a models value that is not an object prints one marker and prices from the distributed table" {
  install_override override-models-not-object.json
  run run_pr
  [ "$status" -eq 0 ]
  [ "$(line_count "$RATE_MARKER")" -eq 1 ]
  has_line "  est. cost (USD): \$1.50"
  assert_no_network
}

@test "override unparseable: the marker prints once on a multi-root initiative readout" {
  install_override override-invalid-json.json
  printf '%s\n' '{"schema_version":1,"kind":"edge","child":"branch:feat/price","parent":"research:one","source":"link-command","ts":"2026-10-01T00:00:00Z","session_id":null,"sidechain":false}' \
    '{"schema_version":1,"kind":"edge","child":"branch:feat/price","parent":"research:two","source":"link-command","ts":"2026-10-01T00:00:00Z","session_id":null,"sidechain":false}' \
    >>"$TELEMETRY_DIRECTORY/links.jsonl"
  run bash "$USAGE" initiative branch:feat/price --main-root "$MAIN" --rate-table "$FIXTURES_DIRECTORY/rates-distributed.json" \
    --projects-root "$TEMPORARY_DIRECTORY/projects"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^\[initiative ' <<<"$output")" -ge 2 ]
  [ "$(line_count "$RATE_MARKER")" -eq 1 ]
}

@test "no override file: no marker and the distributed table prices alone" {
  run run_pr
  [ "$status" -eq 0 ]
  [ "$(line_count "$RATE_MARKER")" -eq 0 ]
  has_line "  est. cost (USD): \$1.50"
}

@test "a seeded machine-local token-rates.json is never read" {
  run run_pr
  [ "$status" -eq 0 ]
  local before="$output"
  printf '%s\n' '{"cache_multipliers":{"read":0.1,"write_5m":1.25,"write_1h":2.0},"models":{"claude-aaa-1":[{"input":900,"output":900}],"claude-ccc-1":[{"input":900,"output":900}]}}' \
    >"$TELEMETRY_DIRECTORY/token-rates.json"
  rm -f "$TELEMETRY_DIRECTORY"/usage-branch-memo.json
  run run_pr
  [ "$status" -eq 0 ]
  [ "$output" = "$before" ]
}

@test "--rate-table still prices from the table it names" {
  printf '%s\n' '{"cache_multipliers":{"read":0.1,"write_5m":1.25,"write_1h":2.0},"models":{"claude-aaa-1":[{"input":2,"output":10}]}}' \
    >"$TEMPORARY_DIRECTORY/seam-rates.json"
  run bash "$USAGE" pr 601 --main-root "$MAIN" --rate-table "$TEMPORARY_DIRECTORY/seam-rates.json" \
    --projects-root "$TEMPORARY_DIRECTORY/projects"
  [ "$status" -eq 0 ]
  has_line "  est. cost (USD): \$3.00"
}

# mutant_scripts <name>: a scratch copy of the scripts directory (files only, no
# suites); sets $MUTANT_SCRIPTS.
mutant_scripts() {
  MUTANT_SCRIPTS="$TEMPORARY_DIRECTORY/mutant-$1"
  rm -rf "$MUTANT_SCRIPTS"
  mkdir -p "$MUTANT_SCRIPTS"
  find "$SCRIPTS" -maxdepth 1 -type f -exec cp {} "$MUTANT_SCRIPTS/" \;
}

@test "override valid, guard red: a pricing lib with the overlay step removed misses the override figure" {
  install_override override-valid.json
  mutant_scripts nooverlay
  local lib="$MUTANT_SCRIPTS/token-pricing-lib.sh" overlay='.models = (.models + $override[0].models)'
  [ "$(grep -cF -- "$overlay" "$lib")" -eq 1 ]
  local text
  text="$(cat "$lib")"
  printf '%s\n' "${text/"$overlay"/.}" >"$lib"
  [ "$(grep -cF -- "$overlay" "$lib")" -eq 0 ]
  run run_pr "$MUTANT_SCRIPTS/usage.sh"
  [ "$status" -eq 0 ]
  grep -qF -- '$7.50' <<<"$output" && return 1
  has_line "  est. cost (USD): \$1.50"
}
