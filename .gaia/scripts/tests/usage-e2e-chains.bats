#!/usr/bin/env bats
#
# End-to-end chains for the usage ledger (SPEC-087): the SPEC-save-to-readout
# path, the lint/lib ref-grammar parity, coverage and markers on every readout,
# and flush-then-resolve chains driven from transcript lines through the real
# flusher, one flush per turn. Hook and concurrency cases live in
# usage-e2e.bats; both source fixtures/usage/e2e/helpers.sh.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/usage-e2e-chains.bats
#
# Golden literals are added up by hand from the write_assistant_message arguments: a message with
# factor k and output o is worth 1111k + o tokens (see helpers.sh).

bats_require_minimum_version 1.5.0

setup() {
  export GAIA_RATES_FEED_DISABLE=1 GAIA_RATES_STATE_DIRECTORY="$BATS_TEST_TMPDIR/rates-state"
  # shellcheck source=fixtures/usage/e2e/helpers.sh
  . "$BATS_TEST_DIRNAME/fixtures/usage/e2e/helpers.sh"
  build_repo
}

# close_row <sid> <ts> <ref> <workflow>: one close binding row, appended to
# usage.jsonl as `usage.sh record` writes it.
close_row() {
  mkdir -p "$TELEMETRY_DIRECTORY"
  jq -nc --arg session_id "$1" --arg timestamp "$2" --arg reference "$3" --arg workflow "$4" \
    '{schema_version:1,kind:"binding",type:"close",session_id:$session_id,ts:$timestamp,ref:$reference,workflow:$workflow,source:"record-command"}' \
    >>"$TELEMETRY_DIRECTORY/usage.jsonl"
}

# ---------- UAT-023 (full path) ----------

@test "UAT-023: a SPEC filled from the template lints, the verbatim step-9 block records its lineage, and the initiative readout includes the SPEC and its branch with no link command" {
  local id=SPEC-095 spec fence transcript_path
  spec="$REPO/.gaia/local/specs/$id/SPEC.md"
  mkdir -p "${spec%/*}"
  sed -e "s/SPEC-NNN/$id/g" -e 's/UAT-NNN/UAT-001/g' \
    -e 's/^lineage: \[\]$/lineage: [research:topic-a-2026-10-01]/' \
    "$REPO/.claude/skills/gaia/references/spec/spec-template.md" >"$spec"
  run bash "$REPO/.gaia/scripts/spec/lint.sh" "$spec"
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true,"findings":[]}' ]

  fence="$(awk '
    /^```bash$/ { buffer = ""; in_block = 1; next }
    /^```$/ && in_block { if (buffer ~ /usage\.sh lineage/) printf "%s", buffer; in_block = 0; next }
    in_block { buffer = buffer $0 "\n" }
  ' "$REPO/.claude/skills/gaia/references/spec.md" | sed "s/SPEC-NNN/$id/g")"
  [ -n "$fence" ]
  run env -u SPEC_PATH bash -c 'cd "$1" && bash -c "$2"' _ "$REPO" "$fence"
  [ "$status" -eq 0 ]
  [ "$(jq -s '[.[] | select(.kind == "edge" and .child == "spec:SPEC-095" and .parent == "research:topic-a-2026-10-01" and .source == "spec-frontmatter")] | length' "$TELEMETRY_DIRECTORY/links.jsonl")" -eq 1 ]
  rm -rf "${spec%/*}"

  transcript_path="$(transcript_path_for_session s-p)"
  write_assistant_message "$transcript_path" s-p "$REPO" plan/spec-095-foo p1 2026-10-01T09:00:01.000Z 1 1
  transcript_path="$(transcript_path_for_session s-sp)"
  write_assistant_message "$transcript_path" s-sp "$REPO" main q1 2026-10-01T10:00:01.000Z 2 2 "$(skill_tool gaia-spec)"
  write_assistant_message "$transcript_path" s-sp "$REPO" main q2 2026-10-01T10:00:05.000Z 3 3
  close_row s-sp 2026-10-01T10:00:10Z spec:SPEC-095 gaia-spec
  flush_session s-p
  flush_session s-sp
  run run_usage initiative research:topic-a-2026-10-01
  grep -Eq '^  spec:SPEC-095  tokens 5,560  est\. ' <<<"$output"
  grep -Eq '^  branch:plan/spec-095-foo  tokens 1,112  est\. ' <<<"$output"
  grep -Eq '^  total \(distinct segments\): tokens 6,672  est\. ' <<<"$output"
}

# ---------- grammar parity ----------

# A corpus of lineage-kind refs, valid and invalid per kind. The long slugs are
# exactly at and one past the 128-character limit.
corpus() {
  local s127 s128
  s127="$(printf 'a%.0s' $(seq 1 127))"
  s128="$(printf 'a%.0s' $(seq 1 128))"
  printf '%s\n' research:topic-a research:a research:A1._-x research:a..b "research:a$s127" "research:a$s128" \
    research: research:.hidden research:-lead 'research:has space' research:a/b research:a:b Research:topic \
    init:cost-work init:x.y init: init:_x \
    issue:1 issue:200 issue:1234567890 issue:0 issue:007 issue:12345678901 issue: issue:1a \
    spec:SPEC-001 spec:SPEC-0001 spec:SPEC-01 spec:spec-001 spec:SPEC-001x spec:SPEC- \
    plan:PLAN-022 plan:PLAN-1000 plan:PLAN-12 plan:plan-022 plan:PLAN-00a specs:SPEC-001
}

# parity <lint.sh>: prints one line per ref the lint and gaia_usage_valid_reference
# disagree on; returns 1 when any.
parity() {
  local lint="$1" spec="$TEMPORARY_DIRECTORY/parity-spec.md" references_file reference lint_bad bad=0 lint_ok library_ok
  references_file="$TEMPORARY_DIRECTORY/refs.txt"
  corpus >"$references_file"
  awk -v references_file="$references_file" '/^lineage: \[\]$/ { print "lineage:"; while ((getline reference_line < references_file) > 0) print "  - " reference_line; next } { print }' \
    "$REPO/.claude/skills/gaia/references/spec/spec-template.md" | sed -e 's/SPEC-NNN/SPEC-001/g' -e 's/UAT-NNN/UAT-001/g' >"$spec"
  lint_bad="$(bash "$lint" "$spec" | jq -r '.findings[] | select(.code == "invalid_lineage") | .message | capture("'"'"'(?<reference>.*)'"'"'$").reference')"
  # shellcheck source=/dev/null
  . "$REPO/.gaia/scripts/usage-lib.sh"
  while IFS= read -r reference; do
    if grep -qxF -- "$reference" <<<"$lint_bad"; then lint_ok=no; else lint_ok=yes; fi
    if gaia_usage_valid_reference "$reference"; then library_ok=yes; else library_ok=no; fi
    [ "$lint_ok" = "$library_ok" ] || { printf 'MISMATCH %s lint-accepts=%s lib-accepts=%s\n' "$reference" "$lint_ok" "$library_ok"; bad=1; }
  done <"$references_file"
  return "$bad"
}

@test "grammar parity: lint.sh and gaia_usage_valid_reference accept and reject the same refs over a corpus of at least 20 per-kind refs" {
  local corpus_count key_prefix
  corpus_count="$(corpus | wc -l | tr -d ' ')"
  [ "$corpus_count" -ge 20 ]
  for key_prefix in research init issue spec plan; do
    [ "$(corpus | grep -c "^$key_prefix:")" -ge 4 ]
  done
  run parity "$REPO/.gaia/scripts/spec/lint.sh"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "guards-must-fail (grammar parity): a lint.sh copy that loosens the SPEC digits is reported with the offending ref" {
  local mutant_script="$TEMPORARY_DIRECTORY/lint-mutant.sh"
  sed 's/\^spec:SPEC-\[0-9\]{3,}\$/^spec:SPEC-[0-9]{2,}$/' "$REPO/.gaia/scripts/spec/lint.sh" >"$mutant_script"
  if cmp -s "$mutant_script" "$REPO/.gaia/scripts/spec/lint.sh"; then echo "mutation did not apply" >&2; return 1; fi
  run parity "$mutant_script"
  [ "$status" -eq 1 ]
  grep -qF 'MISMATCH spec:SPEC-01 lint-accepts=yes lib-accepts=no' <<<"$output"
}

# ---------- coverage and markers on every readout ----------

@test "every readout prints the earliest first_ts date as coverage start, and capture hooks not registered replaces its figures when the registrations are gone" {
  local usage_arguments
  seed_debt
  seed_early
  flush_session s-m
  flush_session s-w
  flush_session s-early
  run_usage link --merge 88 --branch debt/123-slug --merged-at 2026-10-02T00:00:00Z
  for usage_arguments in "pr 88" "initiative issue:123" "reconcile"; do
    # shellcheck disable=SC2086  # the argument list is split on purpose
    run run_usage $usage_arguments
    grep -qF 'coverage start: 2026-09-28' <<<"$output" || { printf '%s: %s\n' "$usage_arguments" "$output" >&2; return 1; }
    lacks "capture hooks not registered"
  done
  printf '{}\n' >"$REPO/.claude/settings.json"
  for usage_arguments in "pr 88" "initiative issue:123" "reconcile"; do
    # shellcheck disable=SC2086  # the argument list is split on purpose
    run run_usage $usage_arguments
    grep -qF 'coverage start: 2026-09-28' <<<"$output" || { printf '%s: %s\n' "$usage_arguments" "$output" >&2; return 1; }
    has_line "  ! capture hooks not registered"
    lacks "tokens"
  done
}

# ---------- flush-then-resolve chains ----------

@test "UAT-005: a discussion-only main session, flushed per turn, is all unattributed and the totals add up" {
  local transcript_path
  transcript_path="$(transcript_path_for_session s05)"
  write_assistant_message "$transcript_path" s05 "$REPO" main d1 2026-10-01T09:00:01.000Z 1 1
  flush_session s05
  write_assistant_message "$transcript_path" s05 "$REPO" main d2 2026-10-01T09:00:02.000Z 2 2
  flush_session s05
  write_assistant_message "$transcript_path" s05 "$REPO" main d3 2026-10-01T09:00:03.000Z 3 3
  flush_session s05
  run run_usage reconcile
  grep -Eq '^  all segments: tokens 6,672  est\. ' <<<"$output"
  grep -Eq '^  unattributed: tokens 6,672  est\. ' <<<"$output"
  grep -Eq '^  attributed:   tokens 0  est\. ' <<<"$output"
}

@test "UAT-006: a /gaia-spec Skill line at T0 stays unattributed until the close row lands, then [T0,T1) resolves to the spec, later spend splits off at the close, and a readout leaves the usage ledger bytes unchanged" {
  local transcript_path before after
  transcript_path="$(transcript_path_for_session s06)"
  write_assistant_message "$transcript_path" s06 "$REPO" main g1 2026-10-01T10:00:01.000Z 1 1 "$(skill_tool gaia-spec)"
  flush_session s06
  write_assistant_message "$transcript_path" s06 "$REPO" main g2 2026-10-01T10:00:05.000Z 2 2
  flush_session s06
  write_assistant_message "$transcript_path" s06 "$REPO" main g3 2026-10-01T10:00:09.000Z 3 3
  flush_session s06
  run run_usage reconcile
  grep -Eq '^  unattributed: tokens 6,672  est\. ' <<<"$output"
  grep -Eq '^  attributed:   tokens 0  est\. ' <<<"$output"

  close_row s06 2026-10-01T10:00:10Z spec:SPEC-096 gaia-spec
  before="$(cksum <"$TELEMETRY_DIRECTORY/usage.jsonl")"
  run run_usage reconcile
  grep -Eq '^  attributed:   tokens 6,672  est\. ' <<<"$output"
  grep -Eq '^  unattributed: tokens 0  est\. ' <<<"$output"
  run run_usage initiative spec:SPEC-096
  grep -Eq '^  spec:SPEC-096  tokens 6,672  est\. ' <<<"$output"
  after="$(cksum <"$TELEMETRY_DIRECTORY/usage.jsonl")"
  [ "$before" = "$after" ]

  write_assistant_message "$transcript_path" s06 "$REPO" main g4 2026-10-01T10:00:11.000Z 4 4
  flush_session s06
  run run_usage reconcile
  grep -Eq '^  attributed:   tokens 6,672  est\. ' <<<"$output"
  grep -Eq '^  unattributed: tokens 4,448  est\. ' <<<"$output"
  grep -Eq '^  all segments: tokens 11,120  est\. ' <<<"$output"
}

@test "UAT-018 (reduced): declare, research writes, and a closed gaia-plan interval each resolve their own span, and spend after the interval returns to the latest research" {
  local transcript_path research_root="$REPO/.gaia/local/research"
  transcript_path="$(transcript_path_for_session s18)"
  run run_usage declare research:x --session s18 --at 2026-10-01T11:00:00Z
  [ "$status" -eq 0 ]
  write_assistant_message "$transcript_path" s18 "$REPO" main r1 2026-10-01T11:00:00.000Z 1 1 "$(write_tool "$research_root/topic-y/README.md")"
  flush_session s18
  write_assistant_message "$transcript_path" s18 "$REPO" main r2 2026-10-01T11:00:30.000Z 2 2
  flush_session s18
  write_assistant_message "$transcript_path" s18 "$REPO" main r3 2026-10-01T11:01:00.000Z 3 3 "$(write_tool "$research_root/topic-z/README.md")"
  flush_session s18
  write_assistant_message "$transcript_path" s18 "$REPO" main r4 2026-10-01T11:01:30.000Z 4 4
  flush_session s18
  write_assistant_message "$transcript_path" s18 "$REPO" main r5 2026-10-01T11:02:00.000Z 5 5 "$(skill_tool gaia-plan)"
  flush_session s18
  write_assistant_message "$transcript_path" s18 "$REPO" main r6 2026-10-01T11:02:30.000Z 6 6
  flush_session s18
  close_row s18 2026-10-01T11:03:00Z plan:PLAN-022 gaia-plan
  write_assistant_message "$transcript_path" s18 "$REPO" main r7 2026-10-01T11:04:00.000Z 7 7
  flush_session s18
  run run_usage initiative research:x
  grep -Eq '^  research:x  tokens 3,336  est\. ' <<<"$output"
  run run_usage initiative research:topic-z
  grep -Eq '^  research:topic-z  tokens 15,568  est\. ' <<<"$output"
  run run_usage initiative plan:PLAN-022
  grep -Eq '^  plan:PLAN-022  tokens 12,232  est\. ' <<<"$output"
}

# ---------- unflushed marker against real flusher output ----------

@test "a sweep over a live file holds its last message: reconcile names the held bytes, and the marker is gone after the next flush" {
  local transcript_path held
  transcript_path="$(transcript_path_for_session s-live)"
  write_assistant_message "$transcript_path" s-live "$REPO" fix/live l1 2026-10-01T09:00:01.000Z 1 1
  write_assistant_message "$transcript_path" s-live "$REPO" fix/live l2 2026-10-01T09:00:02.000Z 2 2
  held="$(tail -n 1 "$transcript_path" | wc -c | tr -d ' ')"
  run bash "$REPO/.gaia/scripts/usage-flush.sh" --sweep --projects-root "$PROJECTS_DIRECTORY" --main-root "$REPO"
  [ "$status" -eq 0 ]
  run run_usage reconcile
  has_line "  ! unflushed: 1 file(s), $held bytes not yet recorded"
  flush_session s-live
  run run_usage reconcile
  lacks "unflushed:"
  grep -Eq '^  all segments: tokens 3,336  est\. ' <<<"$output"
}

# ---------- interleaved runs paired on close rows ----------

@test "interleaved runs: two gaia-spec runs and a gaia-plan run in one session each pair with their own start, and a close from another session claims nothing" {
  local transcript_path other_transcript_path
  transcript_path="$(transcript_path_for_session s-mix)"
  other_transcript_path="$(transcript_path_for_session s-other)"
  write_assistant_message "$transcript_path" s-mix "$REPO" main m1 2026-10-01T10:00:01.000Z 1 1 "$(skill_tool gaia-spec)"
  flush_session s-mix
  write_assistant_message "$transcript_path" s-mix "$REPO" main m2 2026-10-01T10:00:05.000Z 2 2
  flush_session s-mix
  close_row s-mix 2026-10-01T10:00:10Z spec:SPEC-201 gaia-spec
  write_assistant_message "$transcript_path" s-mix "$REPO" main m3 2026-10-01T10:00:20.000Z 3 3 "$(skill_tool gaia-plan)"
  flush_session s-mix
  write_assistant_message "$transcript_path" s-mix "$REPO" main m4 2026-10-01T10:00:25.000Z 4 4 "$(skill_tool gaia-spec)"
  flush_session s-mix
  write_assistant_message "$transcript_path" s-mix "$REPO" main m5 2026-10-01T10:00:30.000Z 5 5
  flush_session s-mix
  write_assistant_message "$other_transcript_path" s-other "$REPO" main o1 2026-10-01T10:00:30.000Z 8 8
  flush_session s-other
  # A close for the second spec from a session that never started a run.
  close_row s-other 2026-10-01T10:00:35Z spec:SPEC-202 gaia-spec
  close_row s-mix 2026-10-01T10:00:40Z spec:SPEC-202 gaia-spec
  write_assistant_message "$transcript_path" s-mix "$REPO" main m6 2026-10-01T10:00:45.000Z 7 7
  flush_session s-mix
  close_row s-mix 2026-10-01T10:00:50Z plan:PLAN-030 gaia-plan
  # m1+m2 = 1112+2224; m4+m5 = 4448+5560 (the plan run is open beneath them and
  # the later spec start wins); m3+m6 = 3336+7784; the other session's 8896
  # has no start, so its close pairs with nothing.
  run run_usage initiative spec:SPEC-201
  grep -Eq '^  spec:SPEC-201  tokens 3,336  est\. ' <<<"$output"
  run run_usage initiative spec:SPEC-202
  grep -Eq '^  spec:SPEC-202  tokens 10,008  est\. ' <<<"$output"
  run run_usage initiative plan:PLAN-030
  grep -Eq '^  plan:PLAN-030  tokens 11,120  est\. ' <<<"$output"
  run run_usage reconcile
  grep -Eq '^  attributed:   tokens 24,464  est\. ' <<<"$output"
  grep -Eq '^  unattributed: tokens 8,896  est\. ' <<<"$output"
}
