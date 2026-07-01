#!/usr/bin/env bats
# UAT-011: 'other' class is treated as a probable bug (offers gh issue),
#          does NOT print user-config remediation.
#
# DETECTOR/SURROGATE TEST (not the shipped skill): exercises an inline surrogate
# of the runbook branch and, where used, the `lib/*.sh` mirrors, never the shipped
# skill body. Real end-to-end guard: integration.md "Local skill end-to-end" diff.

HERE="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
LIB="$HERE/lib"
FIXTURES="$HERE/fixtures"

setup() {
  source "$LIB/classify.sh"
  WORKDIR="$(mktemp -d)"
  CAPTURE_FILE="$WORKDIR/gh-argv.txt"
}

teardown() {
  rm -rf "$WORKDIR"
}

# ---------------------------------------------------------------------------
# Other-class surrogate
#
# Simulates the runbook's probable-bug branch for the 'other' class:
#   - Classifies as 'other' with evidence "no taxonomy class matched"
#   - Saves the report locally
#   - Offers gh issue (the surrogate auto-accepts to test the gh path)
#   - Does NOT print user-config remediation
# ---------------------------------------------------------------------------

other_class_surrogate() {
  local workdir="$1"
  local class="other"
  local timestamp="20260508T143022Z"

  mkdir -p "$workdir/.gaia/local/forensics"
  local report_path="$workdir/.gaia/local/forensics/${timestamp}-${class}.md"
  printf '%s\n' "$(cat "$FIXTURES/golden-other-class.md")" > "$report_path"

  # Print the classification decision (no user-config remediation)
  printf 'class: other\n'
  printf 'evidence: no taxonomy class matched\n'
  printf 'Report saved: .gaia/local/forensics/%s-%s.md\n' "$timestamp" "$class"
  printf 'Offering GH issue creation (probable bug).\n'
  # No "Remediation:" line
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "UAT-011: unknown description classifies as 'other'" {
  local class
  class="$(classify_description "something went wrong that fits no class")"
  [[ "$class" == "other" ]]
}

@test "UAT-011: 'other' evidence is 'no taxonomy class matched'" {
  local evidence
  evidence="$(classify_evidence "other" "something went wrong")"
  [[ "$evidence" == "no taxonomy class matched" ]]
}

@test "UAT-011: other class golden file has evidence = no taxonomy class matched" {
  local golden="$FIXTURES/golden-other-class.md"
  [[ -f "$golden" ]] || skip "golden-other-class.md not found"
  grep -q 'evidence: no taxonomy class matched' "$golden"
}

@test "UAT-011: other class golden file has class: other in Classification section" {
  local golden="$FIXTURES/golden-other-class.md"
  [[ -f "$golden" ]] || skip "golden-other-class.md not found"
  grep -q '^class: other' "$golden"
}

@test "UAT-011: other-class surrogate saves report locally" {
  other_class_surrogate "$WORKDIR"
  local report="$WORKDIR/.gaia/local/forensics/20260508T143022Z-other.md"
  [[ -f "$report" ]]
}

@test "UAT-011: other-class surrogate does NOT print user-config remediation" {
  local output
  output="$(other_class_surrogate "$WORKDIR")"
  # Must not contain remediation language
  ! printf '%s' "$output" | grep -qi 'remediation'
}

@test "UAT-011: other-class surrogate offers GH issue (probable bug path)" {
  local output
  output="$(other_class_surrogate "$WORKDIR")"
  printf '%s' "$output" | grep -qi 'probable bug\|offering gh\|github issue'
}

@test "UAT-011: gh invoked with class=other in title when user confirms" {
  local stub_dir
  stub_dir="$(mktemp -d)"
  cp "$LIB/stub-gh.sh" "$stub_dir/gh"
  chmod +x "$stub_dir/gh"
  export STUB_GH_CAPTURE_FILE="$CAPTURE_FILE"

  local body_file="$WORKDIR/body.md"
  printf '## Symptom\nTest.\n' > "$body_file"

  # Simulate the 'other' gh invocation
  PATH="$stub_dir:$PATH" gh issue create \
    --repo "gaia-react/gaia" \
    --label "gaia-forensics" \
    --title "forensics: other, unknown failure outside taxonomy" \
    --body-file "$body_file"

  rm -rf "$stub_dir"

  grep -xF -- 'gaia-react/gaia' "$CAPTURE_FILE"
  grep -xF -- 'gaia-forensics' "$CAPTURE_FILE"
  grep -qF 'forensics: other,' "$CAPTURE_FILE"
}

@test "UAT-011: other-class report body matches golden file schema" {
  local golden="$FIXTURES/golden-other-class.md"
  [[ -f "$golden" ]] || skip "golden-other-class.md not found"

  local body
  body="$(cat "$golden")"

  # Four required sections
  printf '%s' "$body" | grep -q '^## Symptom'
  printf '%s' "$body" | grep -q '^## Classification'
  printf '%s' "$body" | grep -q '^## Capture'
  printf '%s' "$body" | grep -q '^## Reproduction context'
}
