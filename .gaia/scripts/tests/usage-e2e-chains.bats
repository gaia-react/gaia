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
# Golden literals are added up by hand from the asst arguments: a message with
# factor k and output o is worth 1111k + o tokens (see helpers.sh).

bats_require_minimum_version 1.5.0

setup() {
  export GAIA_RATES_FEED_DISABLE=1 GAIA_RATES_STATE_DIR="$BATS_TEST_TMPDIR/rates-state"
  # shellcheck source=fixtures/usage/e2e/helpers.sh
  . "$BATS_TEST_DIRNAME/fixtures/usage/e2e/helpers.sh"
  build_repo
}

# cost_row <kind> <sid> <ts> <spec_id|null> <plan_id|null>: one cost.jsonl row.
cost_row() {
  mkdir -p "$TD"
  jq -nc --arg k "$1" --arg s "$2" --arg t "$3" --arg sp "$4" --arg pl "$5" \
    '{schema_version:1,kind:$k,session_id:$s,ts:$t,spec_id:(if $sp == "null" then null else $sp end),
      plan_id:(if $pl == "null" then null else $pl end),git_branch:"main"}' >>"$TD/cost.jsonl"
}

# ---------- UAT-023 (full path) ----------

@test "UAT-023: a SPEC filled from the template lints, the verbatim step-9 block records its lineage, and the initiative readout includes the SPEC and its branch with no link command" {
  local id=SPEC-095 spec fence tp
  spec="$REPO/.gaia/local/specs/$id/SPEC.md"
  mkdir -p "${spec%/*}"
  sed -e "s/SPEC-NNN/$id/g" -e 's/UAT-NNN/UAT-001/g' \
    -e 's/^lineage: \[\]$/lineage: [research:topic-a-2026-10-01]/' \
    "$REPO/.specify/extensions/gaia/templates/spec-template.md" >"$spec"
  run bash "$REPO/.specify/extensions/gaia/lib/lint.sh" "$spec"
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true,"findings":[]}' ]

  fence="$(awk '
    /^```bash$/ { buf = ""; inb = 1; next }
    /^```$/ && inb { if (buf ~ /usage\.sh lineage/) printf "%s", buf; inb = 0; next }
    inb { buf = buf $0 "\n" }
  ' "$REPO/.claude/skills/gaia/references/spec.md" | sed "s/SPEC-NNN/$id/g")"
  [ -n "$fence" ]
  run env -u SPEC_PATH bash -c 'cd "$1" && bash -c "$2"' _ "$REPO" "$fence"
  [ "$status" -eq 0 ]
  [ "$(jq -s '[.[] | select(.kind == "edge" and .child == "spec:SPEC-095" and .parent == "research:topic-a-2026-10-01" and .source == "spec-frontmatter")] | length' "$TD/links.jsonl")" -eq 1 ]
  rm -rf "${spec%/*}"

  tp="$(tpath s-p)"
  asst "$tp" s-p "$REPO" plan/spec-095-foo p1 2026-10-01T09:00:01.000Z 1 1
  tp="$(tpath s-sp)"
  asst "$tp" s-sp "$REPO" main q1 2026-10-01T10:00:01.000Z 2 2 "$(skill_tool gaia-spec)"
  asst "$tp" s-sp "$REPO" main q2 2026-10-01T10:00:05.000Z 3 3
  cost_row spec s-sp 2026-10-01T10:00:10Z SPEC-095 null
  flush1 s-p
  flush1 s-sp
  run u initiative research:topic-a-2026-10-01
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

# parity <lint.sh>: prints one line per ref the lint and gaia_usage_valid_ref
# disagree on; returns 1 when any.
parity() {
  local lint="$1" spec="$TMP/parity-spec.md" refs r lint_bad bad=0 lint_ok lib_ok
  refs="$TMP/refs.txt"
  corpus >"$refs"
  awk -v rf="$refs" '/^lineage: \[\]$/ { print "lineage:"; while ((getline l < rf) > 0) print "  - " l; next } { print }' \
    "$REPO/.specify/extensions/gaia/templates/spec-template.md" | sed -e 's/SPEC-NNN/SPEC-001/g' -e 's/UAT-NNN/UAT-001/g' >"$spec"
  lint_bad="$(bash "$lint" "$spec" | jq -r '.findings[] | select(.code == "invalid_lineage") | .message | capture("'"'"'(?<r>.*)'"'"'$").r')"
  # shellcheck source=/dev/null
  . "$REPO/.gaia/scripts/usage-lib.sh"
  while IFS= read -r r; do
    if grep -qxF -- "$r" <<<"$lint_bad"; then lint_ok=no; else lint_ok=yes; fi
    if gaia_usage_valid_ref "$r"; then lib_ok=yes; else lib_ok=no; fi
    [ "$lint_ok" = "$lib_ok" ] || { printf 'MISMATCH %s lint-accepts=%s lib-accepts=%s\n' "$r" "$lint_ok" "$lib_ok"; bad=1; }
  done <"$refs"
  return "$bad"
}

@test "grammar parity: lint.sh and gaia_usage_valid_ref accept and reject the same refs over a corpus of at least 20 per-kind refs" {
  local n k
  n="$(corpus | wc -l | tr -d ' ')"
  [ "$n" -ge 20 ]
  for k in research init issue spec plan; do
    [ "$(corpus | grep -c "^$k:")" -ge 4 ]
  done
  run parity "$REPO/.specify/extensions/gaia/lib/lint.sh"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "guards-must-fail (grammar parity): a lint.sh copy that loosens the SPEC digits is reported with the offending ref" {
  local m="$TMP/lint-mutant.sh"
  sed 's/\^spec:SPEC-\[0-9\]{3,}\$/^spec:SPEC-[0-9]{2,}$/' "$REPO/.specify/extensions/gaia/lib/lint.sh" >"$m"
  if cmp -s "$m" "$REPO/.specify/extensions/gaia/lib/lint.sh"; then echo "mutation did not apply" >&2; return 1; fi
  run parity "$m"
  [ "$status" -eq 1 ]
  grep -qF 'MISMATCH spec:SPEC-01 lint-accepts=yes lib-accepts=no' <<<"$output"
}

# ---------- coverage and markers on every readout ----------

@test "every readout prints the earliest first_ts date as coverage start, and capture hooks not registered replaces its figures when the registrations are gone" {
  local cmd
  seed_debt
  seed_early
  flush1 s-m
  flush1 s-w
  flush1 s-early
  u link --merge 88 --branch debt/123-slug --merged-at 2026-10-02T00:00:00Z
  for cmd in "pr 88" "initiative issue:123" "reconcile"; do
    # shellcheck disable=SC2086  # the argument list is split on purpose
    run u $cmd
    grep -qF 'coverage start: 2026-09-28' <<<"$output" || { printf '%s: %s\n' "$cmd" "$output" >&2; return 1; }
    lacks "capture hooks not registered"
  done
  printf '{}\n' >"$REPO/.claude/settings.json"
  for cmd in "pr 88" "initiative issue:123" "reconcile"; do
    # shellcheck disable=SC2086  # the argument list is split on purpose
    run u $cmd
    grep -qF 'coverage start: 2026-09-28' <<<"$output" || { printf '%s: %s\n' "$cmd" "$output" >&2; return 1; }
    has_line "  ! capture hooks not registered"
    lacks "tokens"
  done
}

# ---------- flush-then-resolve chains ----------

@test "UAT-005: a discussion-only main session, flushed per turn, is all unattributed and the totals add up" {
  local tp
  tp="$(tpath s05)"
  asst "$tp" s05 "$REPO" main d1 2026-10-01T09:00:01.000Z 1 1
  flush1 s05
  asst "$tp" s05 "$REPO" main d2 2026-10-01T09:00:02.000Z 2 2
  flush1 s05
  asst "$tp" s05 "$REPO" main d3 2026-10-01T09:00:03.000Z 3 3
  flush1 s05
  run u reconcile
  grep -Eq '^  all segments: tokens 6,672  est\. ' <<<"$output"
  grep -Eq '^  unattributed: tokens 6,672  est\. ' <<<"$output"
  grep -Eq '^  attributed:   tokens 0  est\. ' <<<"$output"
}

@test "UAT-006: a /gaia-spec Skill line at T0 stays unattributed until the spec row lands, then [T0,T1] resolves to the spec with the split at the row's timestamp and the usage ledger bytes unchanged" {
  local tp before after
  tp="$(tpath s06)"
  asst "$tp" s06 "$REPO" main g1 2026-10-01T10:00:01.000Z 1 1 "$(skill_tool gaia-spec)"
  flush1 s06
  asst "$tp" s06 "$REPO" main g2 2026-10-01T10:00:05.000Z 2 2
  flush1 s06
  asst "$tp" s06 "$REPO" main g3 2026-10-01T10:00:10.000Z 3 3
  flush1 s06
  run u reconcile
  grep -Eq '^  unattributed: tokens 6,672  est\. ' <<<"$output"
  grep -Eq '^  attributed:   tokens 0  est\. ' <<<"$output"
  before="$(cksum <"$TD/usage.jsonl")"

  cost_row spec s06 2026-10-01T10:00:10Z SPEC-096 null
  run u reconcile
  grep -Eq '^  attributed:   tokens 6,672  est\. ' <<<"$output"
  grep -Eq '^  unattributed: tokens 0  est\. ' <<<"$output"
  run u initiative spec:SPEC-096
  grep -Eq '^  spec:SPEC-096  tokens 6,672  est\. ' <<<"$output"
  after="$(cksum <"$TD/usage.jsonl")"
  [ "$before" = "$after" ]

  asst "$tp" s06 "$REPO" main g4 2026-10-01T10:00:11.000Z 4 4
  flush1 s06
  run u reconcile
  grep -Eq '^  attributed:   tokens 6,672  est\. ' <<<"$output"
  grep -Eq '^  unattributed: tokens 4,448  est\. ' <<<"$output"
  grep -Eq '^  all segments: tokens 11,120  est\. ' <<<"$output"
}

@test "UAT-018 (reduced): declare, research writes, and a closed gaia-plan interval each resolve their own span, and spend after the interval returns to the latest research" {
  local tp rz="$REPO/.gaia/local/research"
  tp="$(tpath s18)"
  run u declare research:x --session s18 --at 2026-10-01T11:00:00Z
  [ "$status" -eq 0 ]
  asst "$tp" s18 "$REPO" main r1 2026-10-01T11:00:00.000Z 1 1 "$(write_tool "$rz/topic-y/README.md")"
  flush1 s18
  asst "$tp" s18 "$REPO" main r2 2026-10-01T11:00:30.000Z 2 2
  flush1 s18
  asst "$tp" s18 "$REPO" main r3 2026-10-01T11:01:00.000Z 3 3 "$(write_tool "$rz/topic-z/README.md")"
  flush1 s18
  asst "$tp" s18 "$REPO" main r4 2026-10-01T11:01:30.000Z 4 4
  flush1 s18
  asst "$tp" s18 "$REPO" main r5 2026-10-01T11:02:00.000Z 5 5 "$(skill_tool gaia-plan)"
  flush1 s18
  asst "$tp" s18 "$REPO" main r6 2026-10-01T11:02:30.000Z 6 6
  flush1 s18
  cost_row plan s18 2026-10-01T11:03:00Z null PLAN-022
  asst "$tp" s18 "$REPO" main r7 2026-10-01T11:04:00.000Z 7 7
  flush1 s18
  run u initiative research:x
  grep -Eq '^  research:x  tokens 3,336  est\. ' <<<"$output"
  run u initiative research:topic-z
  grep -Eq '^  research:topic-z  tokens 15,568  est\. ' <<<"$output"
  run u initiative plan:PLAN-022
  grep -Eq '^  plan:PLAN-022  tokens 12,232  est\. ' <<<"$output"
}

# ---------- unflushed marker against real flusher output ----------

@test "a sweep over a live file holds its last message: reconcile names the held bytes, and the marker is gone after the next flush" {
  local tp held
  tp="$(tpath s-live)"
  asst "$tp" s-live "$REPO" fix/live l1 2026-10-01T09:00:01.000Z 1 1
  asst "$tp" s-live "$REPO" fix/live l2 2026-10-01T09:00:02.000Z 2 2
  held="$(tail -n 1 "$tp" | wc -c | tr -d ' ')"
  run bash "$REPO/.gaia/scripts/usage-flush.sh" --sweep --projects-root "$PROJ" --main-root "$REPO"
  [ "$status" -eq 0 ]
  run u reconcile
  has_line "  ! unflushed: 1 file(s), $held bytes not yet recorded"
  flush1 s-live
  run u reconcile
  lacks "unflushed:"
  grep -Eq '^  all segments: tokens 3,336  est\. ' <<<"$output"
}
