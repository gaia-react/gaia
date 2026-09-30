#!/usr/bin/env bats
# lineage: frontmatter lint (invalid_lineage) plus the /gaia-spec step-9 fence.
#
# Fixtures are built in $BATS_TEST_TMPDIR from the real SPEC template, so the
# lint runs against the shipped shape. Hermetic: no real specs, no telemetry.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
LINT="$REPO_ROOT/.specify/extensions/gaia/lib/lint.sh"
TEMPLATE="$REPO_ROOT/.specify/extensions/gaia/templates/spec-template.md"
PRESET_TEMPLATE="$REPO_ROOT/.specify/presets/gaia/templates/spec-template.md"
SPEC_MD="$REPO_ROOT/.claude/skills/gaia/references/spec.md"

# Filled SPEC from the template with the given frontmatter line(s) in place of
# the template's "lineage: []" line. No argument drops the key entirely.
make_spec() {
  local out="$1" repl="${2-__DROP__}"
  if [ "$repl" = "__DROP__" ]; then
    sed 's/SPEC-NNN/SPEC-001/;s/UAT-NNN/UAT-001/;/^lineage: \[\]$/d' "$TEMPLATE" >"$out"
  else
    local tmp="$BATS_TEST_TMPDIR/repl.txt"
    printf '%s\n' "$repl" >"$tmp"
    sed 's/SPEC-NNN/SPEC-001/;s/UAT-NNN/UAT-001/' "$TEMPLATE" \
      | awk -v rf="$tmp" '/^lineage: \[\]$/ { while ((getline l < rf) > 0) print l; next } { print }' >"$out"
  fi
}

# Extract the fenced bash block of spec.md that contains "usage.sh lineage".
extract_lineage_fence() {
  awk '
    /^```bash$/ { buf = ""; inb = 1; next }
    /^```$/ && inb { if (buf ~ /usage\.sh lineage/) printf "%s", buf; inb = 0; next }
    inb { buf = buf $0 "\n" }
  ' "$1"
}

@test "both templates are byte-identical and carry the lineage line" {
  diff "$TEMPLATE" "$PRESET_TEMPLATE"
  grep -q '^lineage: \[\]$' "$TEMPLATE"
  grep -q '^lineage: \[\]$' "$PRESET_TEMPLATE"
}

@test "filled template with lineage: [] lints clean" {
  make_spec "$BATS_TEST_TMPDIR/s.md" 'lineage: []'
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true,"findings":[]}' ]
}

@test "absent lineage key passes and adds no missing_field finding" {
  make_spec "$BATS_TEST_TMPDIR/s.md"
  grep -q '^lineage:' "$BATS_TEST_TMPDIR/s.md" && return 1
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true,"findings":[]}' ]
}

@test "absent lineage key: missing_field findings equal those of a fixture with it" {
  make_spec "$BATS_TEST_TMPDIR/with.md" 'lineage: []'
  make_spec "$BATS_TEST_TMPDIR/without.md"
  # Drop a required key from both so missing_field findings exist to compare.
  sed -i.bak '/^research_summary: |$/,/^  Group by dispatch/d' "$BATS_TEST_TMPDIR/with.md"
  sed -i.bak '/^research_summary: |$/,/^  Group by dispatch/d' "$BATS_TEST_TMPDIR/without.md"
  run bash "$LINT" "$BATS_TEST_TMPDIR/with.md"
  a="$(printf '%s' "$output" | jq -c '[.findings[] | select(.code == "missing_field")]')"
  run bash "$LINT" "$BATS_TEST_TMPDIR/without.md"
  b="$(printf '%s' "$output" | jq -c '[.findings[] | select(.code == "missing_field")]')"
  [ "$a" = "$b" ]
  [ "$(printf '%s' "$a" | jq 'length')" -ge 1 ]
  printf '%s' "$a" | grep -q 'lineage' && return 1
  true
}

@test "positive: flow list of research, issue, init passes" {
  make_spec "$BATS_TEST_TMPDIR/s.md" 'lineage: [research:release-2.0.0-readiness, issue:200, init:cost-work]'
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true,"findings":[]}' ]
}

@test "positive: block list of the same entries passes" {
  make_spec "$BATS_TEST_TMPDIR/s.md" 'lineage:
  - research:release-2.0.0-readiness
  - issue:200
  - init:cost-work'
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true,"findings":[]}' ]
}

@test "positive: spec and plan parents pass" {
  make_spec "$BATS_TEST_TMPDIR/s.md" 'lineage: [spec:SPEC-086, plan:PLAN-091]'
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 0 ]
}

@test "guard: one bad entry yields exactly one invalid_lineage naming it" {
  make_spec "$BATS_TEST_TMPDIR/s.md" 'lineage: [research:topic-a, bogus]'
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq '[.findings[] | select(.code == "invalid_lineage")] | length')" -eq 1 ]
  [ "$(printf '%s' "$output" | jq '.findings | length')" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.findings[0].where')" = "frontmatter.lineage" ]
  printf '%s' "$output" | jq -r '.findings[0].message' | grep -q 'bogus'
}

@test "guard: branch is not an allowed parent kind" {
  make_spec "$BATS_TEST_TMPDIR/s.md" 'lineage: [branch:fix/foo]'
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '[.findings[] | select(.code == "invalid_lineage")] | length == 1' >/dev/null
}

@test "guard: pr, session, and command kinds are refused" {
  local kind
  for kind in pr:12 session:abc command:run-1; do
    make_spec "$BATS_TEST_TMPDIR/s.md" "lineage: [$kind]"
    run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
    [ "$status" -eq 1 ] || return 1
  done
}

@test "guard: lowercase spec id is refused" {
  make_spec "$BATS_TEST_TMPDIR/s.md" 'lineage: [spec:spec-001]'
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '[.findings[] | select(.code == "invalid_lineage")] | length == 1' >/dev/null
}

@test "guard: issue zero and leading-zero numbers are refused" {
  local bad
  for bad in issue:0 issue:007 issue:abc; do
    make_spec "$BATS_TEST_TMPDIR/s.md" "lineage: [$bad]"
    run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
    [ "$status" -eq 1 ] || return 1
  done
}

@test "guard: block list with one bad entry is refused, naming only it" {
  make_spec "$BATS_TEST_TMPDIR/s.md" 'lineage:
  - research:topic-a
  - bogus-entry
  - issue:200'
  run bash "$LINT" "$BATS_TEST_TMPDIR/s.md"
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq '[.findings[] | select(.code == "invalid_lineage")] | length')" -eq 1 ]
  printf '%s' "$output" | jq -r '.findings[0].message' | grep -q 'bogus-entry'
}

@test "spec.md lineage fence assigns SPEC_PATH within the same fence" {
  run extract_lineage_fence "$SPEC_MD"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$(printf '%s\n' "$output" | grep -c 'SPEC_PATH=')" -ge 1 ]
  [ "$(printf '%s\n' "$output" | grep -c 'main-root-lib.sh')" -ge 1 ]
}

@test "guard: fence extraction over a copy without the SPEC_PATH assignment counts 0" {
  local copy="$BATS_TEST_TMPDIR/spec-copy.md"
  # The assignment line lives in the lineage fence; drop it there only.
  awk '/^SPEC_PATH="\$\{MAIN_ROOT\}\/\.gaia\/local\/specs\/SPEC-NNN\/SPEC\.md"$/ { next } { print }' "$SPEC_MD" >"$copy"
  run extract_lineage_fence "$copy"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$(printf '%s\n' "$output" | grep -c 'SPEC_PATH=' || true)" -eq 0 ]
}
