#!/usr/bin/env bats
#
# Self-test of the usage-memo harness (helpers/usage-memo-env.sh), the pinned
# e4b57e23 baseline, and the committed identity fixture (SPEC-089). The identity
# and robustness suites compare the working tree's readout with the pre-change
# one through this harness, so every guard here proves the harness can fail:
# a comparison over degenerate output, a missing baseline, or a fixture that
# lost a probe category would otherwise pass with nothing behind it.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/usage-memo-harness.bats

bats_require_minimum_version 1.5.0

setup() {
  # shellcheck source=.gaia/scripts/tests/helpers/usage-memo-env.sh
  . "$BATS_TEST_DIRNAME/helpers/usage-memo-env.sh"
  umemo_setup
  umemo_load_store identity
  PROBES="$UM_FIXTURES/identity/probes.json"
  read -ra PINNED <<<"$UMEMO_PINNED"
}

# scratch_probes <jq filter>: the committed probes.json passed through a filter,
# written under the test's own tmp dir; sets $SCRATCH to its path.
scratch_probes() {
  SCRATCH="$BATS_TEST_TMPDIR/scratch-probes.json"
  jq "$1" "$PROBES" >"$SCRATCH"
}

# probe_index <category>: the index of the first probe of that category.
probe_index() { jq -r --arg category "$1" '[.probes[].category] | index($category)' "$PROBES"; }

@test "the committed baseline names its rev and verifies" {
  [ "$(head -n 1 "$UM_BASELINE_DIRECTORY/SHA256SUMS")" = '# e4b57e23' ]
  umemo_verify_baseline "$UM_BASELINE_DIRECTORY"
  [ "${#PINNED[@]}" -eq "$(grep -vc '^#' "$UM_BASELINE_DIRECTORY/SHA256SUMS")" ]
}

@test "umemo_setup fails, never skips, when a pinned baseline file is missing" {
  local pinned_file seen=0
  for pinned_file in "${PINNED[@]}"; do
    rm -rf "$BATS_TEST_TMPDIR/base"
    cp -R "$UM_BASELINE_DIRECTORY" "$BATS_TEST_TMPDIR/base"
    rm "$BATS_TEST_TMPDIR/base/$pinned_file"
    UM_BASELINE_DIRECTORY="$BATS_TEST_TMPDIR/base" run umemo_setup
    [ "$status" -ne 0 ]
    case "$output" in *"baseline file missing: $pinned_file"*) ;; *) printf 'no missing-file message for %s: %s\n' "$pinned_file" "$output" >&2; return 1 ;; esac
    seen=$((seen + 1))
  done
  [ "$seen" -eq "${#PINNED[@]}" ]
}

@test "umemo_setup fails, never skips, when a pinned baseline file differs by one byte" {
  local pinned_file seen=0
  for pinned_file in "${PINNED[@]}"; do
    rm -rf "$BATS_TEST_TMPDIR/base"
    cp -R "$UM_BASELINE_DIRECTORY" "$BATS_TEST_TMPDIR/base"
    printf '#' >>"$BATS_TEST_TMPDIR/base/$pinned_file"
    UM_BASELINE_DIRECTORY="$BATS_TEST_TMPDIR/base" run umemo_setup
    [ "$status" -ne 0 ]
    case "$output" in *"baseline sha256 mismatch for $pinned_file"*) ;; *) printf 'no mismatch message for %s: %s\n' "$pinned_file" "$output" >&2; return 1 ;; esac
    seen=$((seen + 1))
  done
  [ "$seen" -eq "${#PINNED[@]}" ]
}

@test "umemo_setup fails when SHA256SUMS lacks a line for a pinned file" {
  cp -R "$UM_BASELINE_DIRECTORY" "$BATS_TEST_TMPDIR/base"
  grep -v ' usage-render-lib.sh$' "$UM_BASELINE_DIRECTORY/SHA256SUMS" >"$BATS_TEST_TMPDIR/base/SHA256SUMS"
  UM_BASELINE_DIRECTORY="$BATS_TEST_TMPDIR/base" run umemo_setup
  [ "$status" -ne 0 ]
  case "$output" in *"no line for usage-render-lib.sh"*) ;; *) printf '%s\n' "$output" >&2; return 1 ;; esac
}

@test "the old tree runs the pinned files and the new tree runs the working tree's" {
  local pinned_file
  for pinned_file in "${PINNED[@]}"; do
    cmp -s "$UM_OLD/.gaia/scripts/$pinned_file" "$UM_BASELINE_DIRECTORY/$pinned_file"
    cmp -s "$UM_NEW/.gaia/scripts/$pinned_file" "$UM_SOURCE_ROOT/.gaia/scripts/$pinned_file"
  done
}

@test "probes.json passes the C8 schema validator" {
  run umemo_validate_probes "$PROBES"
  [ "$status" -eq 0 ]
  [ "$(umemo_probe_count "$PROBES")" -ge 20 ]
}

@test "the schema validator rejects each kind of malformed probes.json" {
  local seen=0 i
  local -a filters=(
    '.probes[0].expect.bogus = true'
    '.probes[0].category = "bogus"'
    'del(.probes[0].raw)'
    '. + {extra: 1}'
    '.probes |= map(select(.category != "lower_bound"))'
    '.probes |= .[0:19]'
  )
  local -a wants=(
    'unknown expect key bogus'
    'unknown category bogus'
    'keys are category,expect,key,pr'
    'top level: keys are'
    'no probe has category lower_bound'
    'want at least 20'
  )
  for i in "${!filters[@]}"; do
    scratch_probes "${filters[$i]}"
    run umemo_validate_probes "$SCRATCH"
    [ "$status" -ne 0 ] || { printf 'validator accepted: %s\n' "${filters[$i]}" >&2; return 1; }
    case "$output" in *"${wants[$i]}"*) ;; *) printf 'validator rejected "%s" for another reason:\n%s\n' "${filters[$i]}" "$output" >&2; return 1 ;; esac
    seen=$((seen + 1))
  done
  [ "$seen" -eq "${#filters[@]}" ]
  [ "${#wants[@]}" -eq "${#filters[@]}" ]
}

@test "every probe exhibits each of its expect keys" {
  local probe_count i fails=0 seen=0
  probe_count="$(umemo_probe_count "$PROBES")"
  [ "$probe_count" -ge 20 ]
  i=0
  while [ "$i" -lt "$probe_count" ]; do
    umemo_check_probe "$PROBES" "$i" || fails=$((fails + 1))
    seen=$((seen + 1))
    i=$((i + 1))
  done
  [ "$seen" -eq "$(jq -r '.probes | length' "$PROBES")" ]
  [ "$fails" -eq 0 ]
}

@test "the probe check fails, for the stated reason, when an expectation is wrong" {
  local seen=0 i category_index
  local -a categories=(lower_bound multi_root first_merge inherit interval no_spend unresolvable cursor_adversarial)
  local -a filters=(
    '.probes[$probe_position].expect.lower_bound = false'
    '.probes[$probe_position].expect.roots_min += 1'
    '.probes[$probe_position].expect.merges = 2'
    '.probes[$probe_position].key = "branch:fix/2302-beta"'
    '.probes[$probe_position].key = "branch:fix/2302-beta"'
    '.probes[$probe_position].pr = 2302'
    '.probes[$probe_position].pr = 2302'
    '.probes[$probe_position].pr = 2308'
  )
  local -a wants=(
    'lower_bound is true, expect false'
    'initiative line(s), expect at least'
    'merge row(s) for'
    'inherit is false'
    'interval is false'
    'no_spend is false'
    'unresolvable is false'
    'nonzero is false'
  )
  for category_index in "${!categories[@]}"; do
    i="$(probe_index "${categories[$category_index]}")"
    jq --argjson probe_position "$i" "${filters[$category_index]}" "$PROBES" >"$BATS_TEST_TMPDIR/scratch.json"
    run umemo_check_probe "$BATS_TEST_TMPDIR/scratch.json" "$i"
    [ "$status" -ne 0 ] || { printf 'probe check accepted a wrong %s expectation\n' "${categories[$category_index]}" >&2; return 1; }
    case "$output" in *"${wants[$category_index]}"*) ;; *) printf 'wrong reason for %s:\n%s\n' "${categories[$category_index]}" "$output" >&2; return 1 ;; esac
    seen=$((seen + 1))
  done
  [ "$seen" -eq "${#categories[@]}" ]
  [ "${#filters[@]}" -eq "${#categories[@]}" ]
  [ "${#wants[@]}" -eq "${#categories[@]}" ]
}

@test "every anchor precondition holds over the committed stores" {
  local anchor_name seen=0 want
  want="$(jq -r '.anchors | length' "$PROBES")"
  for anchor_name in $(jq -r '.anchors | keys[]' "$PROBES"); do
    umemo_check_anchor "$PROBES" "$anchor_name"
    seen=$((seen + 1))
  done
  [ "$seen" -eq "$want" ]
  [ "$want" -eq 5 ]
}

@test "each anchor check fails, for the stated reason, against a probes.json that breaks its precondition" {
  local anchor_index seen=0
  local -a names=(open_start unbound_session spare_root new_branch cycle)
  local -a filters=(
    '.anchors.open_start.session_id = "s09"'
    '.anchors.unbound_session.session_id = "s70"'
    '.anchors.spare_root.ref = "research:multi-topic"'
    '.anchors.new_branch.raw = "fix/cwd-spelling"'
    '.anchors.cycle = {child: "issue:2340", parent: "research:cycle-demo"}'
  )
  local -a wants=(
    'is not an open-start session'
    'do not all resolve to session:s70'
    'a probe key reaches research:multi-topic'
    'already occurs in'
    'exited 0, expect 1'
  )
  for anchor_index in "${!names[@]}"; do
    umemo_load_store identity
    scratch_probes "${filters[$anchor_index]}"
    run umemo_check_anchor "$SCRATCH" "${names[$anchor_index]}"
    [ "$status" -ne 0 ] || { printf 'anchor %s accepted a broken precondition\n' "${names[$anchor_index]}" >&2; return 1; }
    case "$output" in *"${wants[$anchor_index]}"*) ;; *) printf 'wrong reason for %s:\n%s\n' "${names[$anchor_index]}" "$output" >&2; return 1 ;; esac
    seen=$((seen + 1))
  done
  [ "$seen" -eq "$(jq -r '.anchors | length' "$PROBES")" ]
  [ "${#wants[@]}" -eq "${#names[@]}" ]
}

@test "assert_priced passes a priced pr output and fails each degenerate one" {
  u_old pr 2305
  assert_priced "$UM_OUTPUT_FILE"
  assert_priced "$UM_OUTPUT_FILE" --roots
  # The tokens line removed.
  grep -v '^  tokens: ' "$UM_OUTPUT_FILE" >"$BATS_TEST_TMPDIR/no-tokens"
  run assert_priced "$BATS_TEST_TMPDIR/no-tokens"
  [ "$status" -ne 0 ]
  case "$output" in *'no "  tokens: " line'*) ;; *) return 1 ;; esac
  # The initiative lines removed.
  grep -v '^\[initiative \|^  tokens: [0-9,]*  est' "$UM_OUTPUT_FILE" >"$BATS_TEST_TMPDIR/no-roots"
  run assert_priced "$BATS_TEST_TMPDIR/no-roots" --roots
  [ "$status" -ne 0 ]
  case "$output" in *'no "[initiative " line'*) ;; *) return 1 ;; esac
}

@test "assert_priced fails the header-only block of an unregistered install" {
  printf '{}\n' >"$UM_MAIN/.claude/settings.json"
  u_old pr 2305
  grep -qF '! capture hooks not registered' "$UM_OUTPUT_FILE"
  run assert_priced "$UM_OUTPUT_FILE"
  [ "$status" -ne 0 ]
  case "$output" in *'no "  tokens: " line'*) ;; *) return 1 ;; esac
}

@test "assert_priced fails an unavailable-cost output" {
  # shellcheck disable=SC2034  # u_old reads it
  UM_RATES="$BATS_TEST_TMPDIR/absent-rates.json"
  u_old pr 2305
  grep -qxF '  est. cost (USD): unavailable (rate table unreadable)' "$UM_OUTPUT_FILE"
  grep -q '^  tokens: ' "$UM_OUTPUT_FILE"
  run assert_priced "$UM_OUTPUT_FILE"
  [ "$status" -ne 0 ]
  case "$output" in *'no "est. cost (USD): $" figure'*) ;; *) return 1 ;; esac
}

@test "assert_same passes identical files and fails a one-byte difference" {
  u_old pr 2305
  cp "$UM_OUTPUT_FILE" "$BATS_TEST_TMPDIR/copy"
  assert_same "$UM_OUTPUT_FILE" "$BATS_TEST_TMPDIR/copy"
  printf '.' >>"$BATS_TEST_TMPDIR/copy"
  run assert_same "$UM_OUTPUT_FILE" "$BATS_TEST_TMPDIR/copy"
  [ "$status" -ne 0 ]
  sed 's/tokens: /tokenz: /' "$UM_OUTPUT_FILE" >"$BATS_TEST_TMPDIR/copy"
  run assert_same "$UM_OUTPUT_FILE" "$BATS_TEST_TMPDIR/copy"
  [ "$status" -ne 0 ]
}

@test "the harness registers both capture hooks and sets the hermetic environment" {
  jq -e '[.hooks.Stop[].hooks[].command, .hooks.SessionStart[].hooks[].command]
    | all(contains("/.claude/hooks/usage-capture.sh"))' "$UM_MAIN/.claude/settings.json" >/dev/null
  [ "$GAIA_RATES_FEED_DISABLE" = 1 ]
  case "$GAIA_RATES_STATE_DIRECTORY" in "$UM_TELEMETRY_DIRECTORY"*) return 1 ;; esac
  # A second setup clears what a polluted environment carries in.
  export CLAUDE_CODE_SESSION_ID=x GAIA_TALLY_PROJECTS_ROOT=/x GITHUB_ACTIONS=true GAIA_USAGE_MEMO_TRACE=/x GAIA_USAGE_MEMO_SEAM=/x
  umemo_setup
  [ -z "${CLAUDE_CODE_SESSION_ID+x}" ]
  [ -z "${GAIA_TALLY_PROJECTS_ROOT+x}" ]
  [ -z "${GITHUB_ACTIONS+x}" ]
  [ -z "${GAIA_USAGE_MEMO_TRACE+x}" ]
  [ -z "${GAIA_USAGE_MEMO_SEAM+x}" ]
  [ -z "$(ls -A "$UM_PROJECTS_DIRECTORY")" ]
}

@test "a u_old readout is priced and leaves only the loaded stores in the telemetry dir" {
  local before
  before="$(ls -A "$UM_TELEMETRY_DIRECTORY" | tr '\n' ' ')"
  [ "$before" = 'cost.jsonl links.jsonl usage.jsonl ' ]
  u_old pr 2305
  assert_priced "$UM_OUTPUT_FILE" --roots
  [ ! -s "$UM_ERROR_FILE" ]
  [ "$(ls -A "$UM_TELEMETRY_DIRECTORY" | tr '\n' ' ')" = "$before" ]
}

@test "the identity stores are small enough for a CI scripts shard" {
  local total
  total="$(cat "$UM_TELEMETRY_DIRECTORY/usage.jsonl" "$UM_TELEMETRY_DIRECTORY/links.jsonl" "$UM_TELEMETRY_DIRECTORY/cost.jsonl" | wc -c | tr -d ' ')"
  [ "$total" -lt 200000 ]
  [ "$(grep -c 'schema_version' "$UM_TELEMETRY_DIRECTORY/usage.jsonl")" -gt 0 ]
}

@test "no git_branch in the identity stores is spelled with a JSON escape" {
  grep -F '"git_branch":"' "$UM_TELEMETRY_DIRECTORY/cost.jsonl" >"$BATS_TEST_TMPDIR/branches"
  [ -s "$BATS_TEST_TMPDIR/branches" ]
  grep -qE '"git_branch":"[^"]*\\' "$BATS_TEST_TMPDIR/branches" && return 1
  true
}

@test "the identity fixture holds the adversarial cursor rows" {
  grep -qF '"key":"branch:fix/cursor-drift"' "$UM_TELEMETRY_DIRECTORY/usage.jsonl"
  grep -qF '\"kind\":\"cursor\"' "$UM_TELEMETRY_DIRECTORY/cost.jsonl"
  grep -q '^{"kind":"cursor","schema_version":1,' "$UM_TELEMETRY_DIRECTORY/usage.jsonl"
  grep -q '^{"schema_version":1,"kind":"cursor",' "$UM_TELEMETRY_DIRECTORY/usage.jsonl"
}

@test "u_old and u_new print the same pr readout for every probe" {
  local probe_count i pr seen=0
  probe_count="$(umemo_probe_count "$PROBES")"
  [ "$probe_count" -ge 20 ]
  i=0
  while [ "$i" -lt "$probe_count" ]; do
    pr="$(jq -r --argjson probe_position "$i" '.probes[$probe_position].pr' "$PROBES")"
    u_old pr "$pr"
    cp "$UM_OUTPUT_FILE" "$BATS_TEST_TMPDIR/old.out"
    u_new pr "$pr"
    assert_same "$BATS_TEST_TMPDIR/old.out" "$UM_OUTPUT_FILE"
    seen=$((seen + 1))
    i=$((i + 1))
  done
  [ "$seen" -eq "$probe_count" ]
}
