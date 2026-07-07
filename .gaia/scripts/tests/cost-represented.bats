#!/usr/bin/env bats
#
# Bats suite for .gaia/scripts/cost-represented.sh (the value-aware, fail-closed
# representation gate `cost_folder_represented`).
#
# Each test runs inside an isolated `git init`'d temp sandbox with an isolated
# ledger, never the machine's real cost.jsonl. Fixture cost.md bodies mirror the
# exact `## <heading>` + bucket-table + `Session `<id>`` shape token-tally.sh's
# render_tally_body writes; ledger rows mirror the schema token-tally.sh and
# cost-backfill.sh append (buckets{fresh_input,cache_write,cache_read,output} +
# total + session_id + kind + identity field).
#
# Assertion style note: per .claude/rules/bats-assertions.md, non-final
# assertions avoid bare `[[ ... ]]` (a false one is silently skipped on macOS's
# system bash 3.2). This suite uses `[ ... ]` and `grep -qF` for everything but
# the test's last statement.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  LIB="$THIS_DIR/../cost-represented.sh"
  [ -f "$LIB" ] || skip "cost-represented.sh missing"
  # shellcheck source=/dev/null
  . "$LIB"

  SANDBOX_RAW="$(mktemp -d "${BATS_TEST_TMPDIR}/sandbox.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX_RAW" && pwd -P)"
  git -C "$SANDBOX" init --quiet

  LEDGER="$SANDBOX/.gaia/local/telemetry/cost.jsonl"
  mkdir -p "$(dirname "$LEDGER")"
  : > "$LEDGER"
}

# seed_cost_md <rel_dir_under_sandbox>: writes stdin heredoc to <dir>/cost.md.
seed_cost_md() {
  local dir="$SANDBOX/$1"
  mkdir -p "$dir"
  cat > "$dir/cost.md"
}

# add_row <kind> <attr_field> <attr_val> <session> <fresh> <cwrite> <cread> <output> [total]
# Appends one ledger row mirroring the token-tally / backfill schema. With no
# explicit <total>, total is the bucket sum (as the writers compute it); pass an
# explicit total to exercise the total-equality fallback. An empty <session>
# yields session_id:null.
add_row() {
  local kind="$1" field="$2" val="$3" sid="$4"
  local fresh="$5" cwrite="$6" cread="$7" output="$8" total="${9:-}"
  jq -cn \
    --arg kind "$kind" --arg field "$field" --arg val "$val" --arg sid "$sid" \
    --argjson fresh "$fresh" --argjson cwrite "$cwrite" \
    --argjson cread "$cread" --argjson output "$output" --arg total "$total" '
    {
      schema_version: 1,
      kind: $kind,
      spec_id: null, plan_id: null, plan_slug: null,
      session_id: (if $sid == "" then null else $sid end),
      buckets: {fresh_input: $fresh, cache_write: $cwrite, cache_read: $cread, output: $output},
      total: (if $total == "" then ($fresh + $cwrite + $cread + $output) else ($total | tonumber) end),
      seq: 0, final: true, source: "test"
    } | .[$field] = $val
  ' >> "$LEDGER"
}

# seed_cost_json <rel_dir_under_sandbox> <kind> <attr_field> <attr_val> <session> \
#                 <fresh> <cwrite> <cread> <output>
# Writes (or merges into) <dir>/cost.json a single record keyed by <kind>,
# matching FC-1's shape: {"<kind>": {kind, <attr_field>, session_id, buckets,
# total}}. A second call against the same dir merges in the new key and
# preserves the sibling already on disk, mirroring token-tally.sh's own
# replace-mine-preserve-sibling write.
seed_cost_json() {
  local dir="$SANDBOX/$1" kind="$2" field="$3" val="$4" sid="$5"
  local fresh="$6" cwrite="$7" cread="$8" output="$9"
  mkdir -p "$dir"
  local rec
  rec="$(jq -cn \
    --arg kind "$kind" --arg field "$field" --arg val "$val" --arg sid "$sid" \
    --argjson fresh "$fresh" --argjson cwrite "$cwrite" \
    --argjson cread "$cread" --argjson output "$output" '
    {
      schema_version: 1,
      kind: $kind,
      session_id: (if $sid == "" then null else $sid end),
      buckets: {fresh_input: $fresh, cache_write: $cwrite, cache_read: $cread, output: $output},
      total: ($fresh + $cwrite + $cread + $output)
    } | .[$field] = $val
  ')"
  if [ -f "$dir/cost.json" ]; then
    jq -c --argjson rec "$rec" --arg k "$kind" '. + {($k): $rec}' "$dir/cost.json" > "$dir/cost.json.tmp"
    mv "$dir/cost.json.tmp" "$dir/cost.json"
  else
    jq -cn --argjson rec "$rec" --arg k "$kind" '{($k): $rec}' > "$dir/cost.json"
  fi
}

# A single `## <heading>` section in render_tally_body's shape.
section() {
  local heading="$1" fresh="$2" cwrite="$3" cread="$4" output="$5" session="$6"
  local total=$((fresh + cwrite + cread + output))
  printf '## %s\n\n' "$heading"
  printf '| Bucket | Tokens |\n| --- | --- |\n'
  printf '| Fresh input | %s |\n' "$fresh"
  printf '| Cache write | %s |\n' "$cwrite"
  printf '| Cache read | %s |\n' "$cread"
  printf '| Output | %s |\n' "$output"
  printf '| **Total** | %s |\n\n' "$total"
  printf '**Elapsed (first to last model turn):** 1h0m0s (2026-07-05 10:00:00 JST to 2026-07-05 11:00:00 JST)\n\n'
  printf '**Est. cost (USD):** $1.23\n\n'
  if [ -n "$session" ]; then
    printf 'Session `%s` · generated 2026-07-05T10:00:00Z\n' "$session"
  fi
}

# --- 1. Represented pass: every section matches a seeded row -----------------

@test "represented: SPEC/Planning/Execution each match a ledger row -> 0, all REPRESENTED" {
  {
    printf '# Cost: Feature\n\n'
    section SPEC 10 20 30 40 sess-1
    section Planning 11 22 33 44 sess-1
    section Execution 12 24 36 48 sess-1
  } | seed_cost_md specs/SPEC-100

  add_row spec spec_id SPEC-100 sess-1 10 20 30 40
  add_row plan spec_id SPEC-100 sess-1 11 22 33 44
  add_row execute spec_id SPEC-100 sess-1 12 24 36 48

  run cost_folder_represented "$SANDBOX/specs/SPEC-100" spec_id SPEC-100 "$LEDGER"
  [ "$status" -eq 0 ]
  grep -qF -- "$(printf 'spec\tREPRESENTED')" <<<"$output"
  grep -qF -- "$(printf 'plan\tREPRESENTED')" <<<"$output"
  grep -qF -- "$(printf 'execute\tREPRESENTED')" <<<"$output"
}

# --- 2. Value mismatch blocks (planted wrong numbers) ------------------------

@test "value mismatch: section buckets differ from the ledger row -> non-zero, BLOCKING" {
  {
    printf '# Cost: Feature\n\n'
    section Execution 999 1 1 1 sess-1
  } | seed_cost_md specs/SPEC-101

  add_row execute spec_id SPEC-101 sess-1 12 24 36 48

  run cost_folder_represented "$SANDBOX/specs/SPEC-101" spec_id SPEC-101 "$LEDGER"
  [ "$status" -ne 0 ]
  grep -qF -- "$(printf 'execute\tBLOCKING')" <<<"$output"
}

# --- 3. Unparseable section blocks (fail closed) -----------------------------

@test "unparseable: a non-numeric bucket cell -> non-zero, BLOCKING" {
  {
    printf '# Cost: Feature\n\n'
    printf '## Execution\n\n'
    printf '| Bucket | Tokens |\n| --- | --- |\n'
    printf '| Fresh input | n/a |\n'
    printf '| Cache write | 200 |\n'
    printf '| Cache read | 300 |\n'
    printf '| Output | 400 |\n'
    printf '| **Total** | 900 |\n\n'
    printf 'Session `sess-1` · generated 2026-07-05T10:00:00Z\n'
  } | seed_cost_md specs/SPEC-102

  # A well-formed matching row exists, but the section itself is unparseable.
  add_row execute spec_id SPEC-102 sess-1 100 200 300 400

  run cost_folder_represented "$SANDBOX/specs/SPEC-102" spec_id SPEC-102 "$LEDGER"
  [ "$status" -ne 0 ]
  grep -qF -- "$(printf 'execute\tBLOCKING\tincomplete or non-numeric buckets')" <<<"$output"
}

# --- 4. Missing row blocks ---------------------------------------------------

@test "missing row: a well-formed section with no matching ledger row -> BLOCKING, non-zero" {
  {
    printf '# Cost: Feature\n\n'
    section SPEC 10 20 30 40 sess-1
  } | seed_cost_md specs/SPEC-103
  # Ledger left empty.

  run cost_folder_represented "$SANDBOX/specs/SPEC-103" spec_id SPEC-103 "$LEDGER"
  [ "$status" -ne 0 ]
  grep -qF -- "$(printf 'spec\tBLOCKING\tno matching ledger row')" <<<"$output"
}

# --- 5. Total-equality fallback ----------------------------------------------

@test "total fallback: buckets differ field-by-field but sum equals row.total -> REPRESENTED" {
  {
    printf '# Cost: Feature\n\n'
    section SPEC 10 20 30 40 sess-1
  } | seed_cost_md specs/SPEC-104

  # Different per-bucket split, same total (25*4 = 100 = 10+20+30+40).
  add_row spec spec_id SPEC-104 sess-1 25 25 25 25

  run cost_folder_represented "$SANDBOX/specs/SPEC-104" spec_id SPEC-104 "$LEDGER"
  [ "$status" -eq 0 ]
  grep -qF -- "$(printf 'spec\tREPRESENTED')" <<<"$output"
}

# --- 6. Colocated nesting: root cost.md + plan/cost.md, all keyed by spec_id --

@test "colocated: root SPEC + plan/{Planning,Execution} all keyed by spec_id -> 0" {
  {
    printf '# Cost: Feature\n\n'
    section SPEC 10 20 30 40 sess-1
  } | seed_cost_md specs/SPEC-105
  {
    printf '# Cost: Feature / slug\n\n'
    section Planning 11 22 33 44 sess-1
    section Execution 12 24 36 48 sess-1
  } | seed_cost_md specs/SPEC-105/plan

  add_row spec spec_id SPEC-105 sess-1 10 20 30 40
  add_row plan spec_id SPEC-105 sess-1 11 22 33 44
  add_row execute spec_id SPEC-105 sess-1 12 24 36 48

  run cost_folder_represented "$SANDBOX/specs/SPEC-105" spec_id SPEC-105 "$LEDGER"
  [ "$status" -eq 0 ]
  grep -qF -- "$(printf 'spec\tREPRESENTED')" <<<"$output"
  grep -qF -- "$(printf 'plan\tREPRESENTED')" <<<"$output"
  grep -qF -- "$(printf 'execute\tREPRESENTED')" <<<"$output"
}

# --- 7. Session-null match ---------------------------------------------------

@test "session-null: a section with no Session line matches a row whose session_id is null" {
  {
    printf '# Cost: Feature\n\n'
    section SPEC 10 20 30 40 ""
  } | seed_cost_md specs/SPEC-106

  add_row spec spec_id SPEC-106 "" 10 20 30 40

  run cost_folder_represented "$SANDBOX/specs/SPEC-106" spec_id SPEC-106 "$LEDGER"
  [ "$status" -eq 0 ]
  grep -qF -- "$(printf 'spec\tREPRESENTED')" <<<"$output"
}

# --- 8. No cost.md -> returns 0 ----------------------------------------------

@test "no cost.md: a folder with only SUMMARY.md -> 0, empty manifest" {
  mkdir -p "$SANDBOX/plans/archived/legacy-slug"
  printf 'summary\n' > "$SANDBOX/plans/archived/legacy-slug/SUMMARY.md"

  run cost_folder_represented "$SANDBOX/plans/archived/legacy-slug" plan_slug legacy-slug "$LEDGER"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- 9. Corrupt ledger line tolerated ----------------------------------------

@test "corrupt ledger: a garbage line does not abort the check; a good row still matches" {
  {
    printf '# Cost: Feature\n\n'
    section SPEC 10 20 30 40 sess-1
  } | seed_cost_md specs/SPEC-107

  printf 'this is not json {{{\n' >> "$LEDGER"
  add_row spec spec_id SPEC-107 sess-1 10 20 30 40

  run cost_folder_represented "$SANDBOX/specs/SPEC-107" spec_id SPEC-107 "$LEDGER"
  [ "$status" -eq 0 ]
  grep -qF -- "$(printf 'spec\tREPRESENTED')" <<<"$output"
}

# --- 10. Read-only: the ledger and the folder are unchanged ------------------

@test "read-only: running the gate mutates neither cost.jsonl nor the folder" {
  {
    printf '# Cost: Feature\n\n'
    section SPEC 10 20 30 40 sess-1
  } | seed_cost_md specs/SPEC-108
  add_row spec spec_id SPEC-108 sess-1 10 20 30 40

  local ledger_before cost_before ledger_after cost_after
  ledger_before="$(cksum < "$LEDGER")"
  cost_before="$(cksum < "$SANDBOX/specs/SPEC-108/cost.md")"

  run cost_folder_represented "$SANDBOX/specs/SPEC-108" spec_id SPEC-108 "$LEDGER"
  [ "$status" -eq 0 ]

  ledger_after="$(cksum < "$LEDGER")"
  cost_after="$(cksum < "$SANDBOX/specs/SPEC-108/cost.md")"
  [ "$ledger_before" = "$ledger_after" ]
  [ "$cost_before" = "$cost_after" ]
}

# --- 11. Mixed: one BLOCKING among REPRESENTED still fails --------------------

@test "mixed: one blocking section among represented ones -> non-zero" {
  {
    printf '# Cost: Feature\n\n'
    section SPEC 10 20 30 40 sess-1
    section Planning 11 22 33 44 sess-1
  } | seed_cost_md specs/SPEC-109

  add_row spec spec_id SPEC-109 sess-1 10 20 30 40
  # No Planning row -> that section blocks.

  run cost_folder_represented "$SANDBOX/specs/SPEC-109" spec_id SPEC-109 "$LEDGER"
  [ "$status" -ne 0 ]
  grep -qF -- "$(printf 'spec\tREPRESENTED')" <<<"$output"
  grep -qF -- "$(printf 'plan\tBLOCKING')" <<<"$output"
}

# --- 12. Total is never treated as a phase -----------------------------------

@test "total: the derived '## Total' grand-sum is never emitted as a section" {
  {
    printf '# Cost: Feature\n\n'
    section SPEC 10 20 30 40 sess-1
    printf '## Total\n\n'
    printf '| Bucket | Tokens |\n| --- | --- |\n'
    printf '| Fresh input | 10 |\n'
    printf '| Cache write | 20 |\n'
    printf '| Cache read | 30 |\n'
    printf '| Output | 40 |\n'
    printf '| **Total** | 100 |\n\n'
  } | seed_cost_md specs/SPEC-110

  add_row spec spec_id SPEC-110 sess-1 10 20 30 40

  run cost_folder_represented "$SANDBOX/specs/SPEC-110" spec_id SPEC-110 "$LEDGER"
  [ "$status" -eq 0 ]
  # Exactly one manifest line (the SPEC section); Total contributes nothing.
  [ "$(grep -c . <<<"$output")" -eq 1 ]
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

# --- 17. Sidecar precedence: cost.json wins over a mismatched cost.md -------

@test "sidecar precedence: cost.json (represented) wins over a mismatched cost.md" {
  seed_cost_json specs/SPEC-203 spec spec_id SPEC-203 sess-1 10 20 30 40
  {
    printf '# Cost: Feature\n\n'
    section SPEC 999 1 1 1 sess-1
  } | seed_cost_md specs/SPEC-203

  add_row spec spec_id SPEC-203 sess-1 10 20 30 40

  run cost_folder_represented "$SANDBOX/specs/SPEC-203" spec_id SPEC-203 "$LEDGER"
  [ "$status" -eq 0 ]
  grep -qF -- "$(printf 'spec\tREPRESENTED')" <<<"$output"
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
