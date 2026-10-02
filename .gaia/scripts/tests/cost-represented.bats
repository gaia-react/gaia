#!/usr/bin/env bats
#
# Bats suite for .gaia/scripts/cost-represented.sh (the value-aware, fail-closed
# representation gate `cost_folder_represented`).
#
# Each test runs inside an isolated `git init`'d temp sandbox with an isolated
# ledger, never the machine's real cost.jsonl. Ledger rows mirror the schema
# token-tally.sh appends (buckets{fresh_input,cache_write,cache_read,output} +
# total + session_id + kind + identity field).
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  LIBRARY_FILE="$THIS_DIRECTORY/../cost-represented.sh"
  [ -f "$LIBRARY_FILE" ] || skip "cost-represented.sh missing"
  # shellcheck source=/dev/null
  . "$LIBRARY_FILE"

  SANDBOX_RAW="$(mktemp -d "${BATS_TEST_TMPDIR}/sandbox.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX_RAW" && pwd -P)"
  git -C "$SANDBOX" init --quiet

  LEDGER="$SANDBOX/.gaia/local/telemetry/cost.jsonl"
  mkdir -p "$(dirname "$LEDGER")"
  : > "$LEDGER"
}

# add_row <kind> <attribute_field> <attribute_value> <session> <fresh_input> <cache_write> <cache_read> <output> [total]
# Appends one ledger row mirroring the token-tally schema. With no
# explicit <total>, total is the bucket sum (as the writers compute it); pass an
# explicit total to exercise the total-equality fallback. An empty <session>
# yields session_id:null.
add_row() {
  local kind="$1" field="$2" attribute_value="$3" session_id="$4"
  local fresh_input="$5" cache_write="$6" cache_read="$7" output="$8" total="${9:-}"
  jq -cn \
    --arg kind "$kind" --arg field "$field" --arg attribute_value "$attribute_value" --arg session_id "$session_id" \
    --argjson fresh_input "$fresh_input" --argjson cache_write "$cache_write" \
    --argjson cache_read "$cache_read" --argjson output "$output" --arg total "$total" '
    {
      schema_version: 1,
      kind: $kind,
      spec_id: null, plan_id: null, plan_slug: null,
      session_id: (if $session_id == "" then null else $session_id end),
      buckets: {fresh_input: $fresh_input, cache_write: $cache_write, cache_read: $cache_read, output: $output},
      total: (if $total == "" then ($fresh_input + $cache_write + $cache_read + $output) else ($total | tonumber) end),
      seq: 0, final: true, source: "test"
    } | .[$field] = $attribute_value
  ' >> "$LEDGER"
}

# seed_cost_json <rel_dir_under_sandbox> <kind> <attribute_field> <attribute_value> <session> \
#                 <fresh_input> <cache_write> <cache_read> <output>
# Writes (or merges into) <directory>/cost.json a single record keyed by <kind>,
# matching FC-1's shape: {"<kind>": {kind, <attribute_field>, session_id, buckets,
# total}}. A second call against the same dir merges in the new key and
# preserves the sibling already on disk, mirroring token-tally.sh's own
# replace-mine-preserve-sibling write.
seed_cost_json() {
  local directory="$SANDBOX/$1" kind="$2" field="$3" attribute_value="$4" session_id="$5"
  local fresh_input="$6" cache_write="$7" cache_read="$8" output="$9"
  mkdir -p "$directory"
  local record
  record="$(jq -cn \
    --arg kind "$kind" --arg field "$field" --arg attribute_value "$attribute_value" --arg session_id "$session_id" \
    --argjson fresh_input "$fresh_input" --argjson cache_write "$cache_write" \
    --argjson cache_read "$cache_read" --argjson output "$output" '
    {
      schema_version: 1,
      kind: $kind,
      session_id: (if $session_id == "" then null else $session_id end),
      buckets: {fresh_input: $fresh_input, cache_write: $cache_write, cache_read: $cache_read, output: $output},
      total: ($fresh_input + $cache_write + $cache_read + $output)
    } | .[$field] = $attribute_value
  ')"
  if [ -f "$directory/cost.json" ]; then
    jq -c --argjson record "$record" --arg phase_kind "$kind" '. + {($phase_kind): $record}' "$directory/cost.json" > "$directory/cost.json.tmp"
    mv "$directory/cost.json.tmp" "$directory/cost.json"
  else
    jq -cn --argjson record "$record" --arg phase_kind "$kind" '{($phase_kind): $record}' > "$directory/cost.json"
  fi
}

# --- No cost.json -> returns 0 ------------------------------------------------

@test "no cost.json: a folder with only SUMMARY.md -> 0, empty manifest" {
  mkdir -p "$SANDBOX/plans/archived/legacy-slug"
  printf 'summary\n' > "$SANDBOX/plans/archived/legacy-slug/SUMMARY.md"

  run cost_folder_represented "$SANDBOX/plans/archived/legacy-slug" plan_slug legacy-slug "$LEDGER"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- 13. Sidecar represented: cost.json record matches a ledger row (UAT-003) -

@test "sidecar represented: cost.json record matches a ledger row -> 0, REPRESENTED" {
  seed_cost_json specs/SPEC-200 spec spec_id SPEC-200 sess-1 10 20 30 40
  add_row spec spec_id SPEC-200 sess-1 10 20 30 40

  run cost_folder_represented "$SANDBOX/specs/SPEC-200" spec_id SPEC-200 "$LEDGER"
  [ "$status" -eq 0 ]
  grep -qF -- "$(printf 'spec\tREPRESENTED')" <<<"$output"
}

# --- 14. Sidecar unrepresented: no matching row blocks (UAT-004a) ------------

@test "sidecar unrepresented: cost.json record with no matching ledger row -> non-zero, BLOCKING" {
  seed_cost_json specs/SPEC-201 spec spec_id SPEC-201 sess-1 10 20 30 40
  # Ledger left empty.

  run cost_folder_represented "$SANDBOX/specs/SPEC-201" spec_id SPEC-201 "$LEDGER"
  [ "$status" -ne 0 ]
  grep -qF -- "$(printf 'spec\tBLOCKING\tno matching ledger row')" <<<"$output"
}

# --- 15. Sidecar unparseable: invalid JSON blocks, never 0 (UAT-004b) --------

@test "sidecar unparseable: invalid JSON cost.json -> non-zero, BLOCKING, never 0" {
  mkdir -p "$SANDBOX/specs/SPEC-202"
  printf '{oops\n' > "$SANDBOX/specs/SPEC-202/cost.json"
  add_row spec spec_id SPEC-202 sess-1 10 20 30 40

  run cost_folder_represented "$SANDBOX/specs/SPEC-202" spec_id SPEC-202 "$LEDGER"
  [ "$status" -ne 0 ]
  grep -qF -- "$(printf 'unparseable\tBLOCKING\tunparseable cost.json')" <<<"$output"
}

# --- 16. Sidecar incomplete buckets: a missing bucket blocks (fail closed) ---

@test "sidecar incomplete buckets: a missing bucket field blocks (fail closed)" {
  mkdir -p "$SANDBOX/specs/SPEC-206"
  printf '{"spec":{"kind":"spec","spec_id":"SPEC-206","session_id":"sess-1","buckets":{"fresh_input":10,"cache_write":20,"cache_read":30},"total":60}}\n' \
    > "$SANDBOX/specs/SPEC-206/cost.json"
  add_row spec spec_id SPEC-206 sess-1 10 20 30 40

  run cost_folder_represented "$SANDBOX/specs/SPEC-206" spec_id SPEC-206 "$LEDGER"
  [ "$status" -ne 0 ]
  grep -qF -- "$(printf 'spec\tBLOCKING\tincomplete or non-numeric buckets')" <<<"$output"
}

# --- 18. Sidecar colocated nesting: root cost.json + plan/cost.json --------

@test "sidecar colocated: root cost.json (spec) + plan/cost.json (plan+execute), all keyed by spec_id -> 0" {
  seed_cost_json specs/SPEC-204 spec spec_id SPEC-204 sess-1 10 20 30 40
  seed_cost_json specs/SPEC-204/plan plan spec_id SPEC-204 sess-1 11 22 33 44
  seed_cost_json specs/SPEC-204/plan execute spec_id SPEC-204 sess-1 12 24 36 48

  add_row spec spec_id SPEC-204 sess-1 10 20 30 40
  add_row plan spec_id SPEC-204 sess-1 11 22 33 44
  add_row execute spec_id SPEC-204 sess-1 12 24 36 48

  run cost_folder_represented "$SANDBOX/specs/SPEC-204" spec_id SPEC-204 "$LEDGER"
  [ "$status" -eq 0 ]
  grep -qF -- "$(printf 'spec\tREPRESENTED')" <<<"$output"
  grep -qF -- "$(printf 'plan\tREPRESENTED')" <<<"$output"
  grep -qF -- "$(printf 'execute\tREPRESENTED')" <<<"$output"
}

# --- 19. Sidecar colocated: one non-matching record blocks the whole gate ---

@test "sidecar colocated: one non-matching record among three blocks the whole gate" {
  seed_cost_json specs/SPEC-205 spec spec_id SPEC-205 sess-1 10 20 30 40
  seed_cost_json specs/SPEC-205/plan plan spec_id SPEC-205 sess-1 11 22 33 44
  seed_cost_json specs/SPEC-205/plan execute spec_id SPEC-205 sess-1 12 24 36 48

  add_row spec spec_id SPEC-205 sess-1 10 20 30 40
  add_row plan spec_id SPEC-205 sess-1 11 22 33 44
  # No execute row -> that record blocks.

  run cost_folder_represented "$SANDBOX/specs/SPEC-205" spec_id SPEC-205 "$LEDGER"
  [ "$status" -ne 0 ]
  grep -qF -- "$(printf 'execute\tBLOCKING')" <<<"$output"
}
