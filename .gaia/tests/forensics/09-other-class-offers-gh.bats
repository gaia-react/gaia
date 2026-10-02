#!/usr/bin/env bats
# UAT-011: 'other' class is treated as a probable bug (offers gh issue),
#          does NOT print user-config remediation.
#
# DETECTOR/SURROGATE TEST (not the shipped skill): exercises an inline surrogate
# of the runbook branch and, where used, the `lib/*.sh` mirrors, never the shipped
# skill body. Real end-to-end guard: integration.md "Local skill end-to-end" diff.

HERE="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
LIBRARY_DIRECTORY="$HERE/lib"
FIXTURES="$HERE/fixtures"

setup() {
  source "$LIBRARY_DIRECTORY/classify.sh"
  WORK_DIRECTORY="$(mktemp -d)"
  CAPTURE_FILE="$WORK_DIRECTORY/gh-argv.txt"
}

teardown() {
  rm -rf "$WORK_DIRECTORY"
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

# Synthetic stand-in for `bash .gaia/scripts/main-root-lib.sh --tree-key`'s
# stdout (16 lowercase hex characters); this surrogate never invokes the real
# resolver, same as the fixed synthetic $timestamp below.
TREE_KEY_FIXTURE="deadbeefcafe1234"

other_class_surrogate() {
  local work_directory="$1"
  local class="other"
  local timestamp="20260508T143022Z"

  mkdir -p "$work_directory/.gaia/local/forensics/$TREE_KEY_FIXTURE"
  local report_path="$work_directory/.gaia/local/forensics/$TREE_KEY_FIXTURE/${timestamp}-${class}.md"
  printf '%s\n' "$(cat "$FIXTURES/golden-other-class.md")" > "$report_path"

  # Print the classification decision (no user-config remediation)
  printf 'class: other\n'
  printf 'evidence: no taxonomy class matched\n'
  printf 'Report saved: .gaia/local/forensics/%s/%s-%s.md\n' "$TREE_KEY_FIXTURE" "$timestamp" "$class"
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
  other_class_surrogate "$WORK_DIRECTORY"
  local report="$WORK_DIRECTORY/.gaia/local/forensics/$TREE_KEY_FIXTURE/20260508T143022Z-other.md"
  [[ -f "$report" ]]
}

@test "UAT-011: other-class surrogate does NOT print user-config remediation" {
  local output
  output="$(other_class_surrogate "$WORK_DIRECTORY")"
  # Must not contain remediation language
  ! printf '%s' "$output" | grep -qi 'remediation'
}

@test "UAT-011: other-class surrogate offers GH issue (probable bug path)" {
  local output
  output="$(other_class_surrogate "$WORK_DIRECTORY")"
  printf '%s' "$output" | grep -qi 'probable bug\|offering gh\|github issue'
}

@test "UAT-011: gh invoked with class=other in title when user confirms" {
  local stub_directory
  stub_directory="$(mktemp -d)"
  cp "$LIBRARY_DIRECTORY/stub-gh.sh" "$stub_directory/gh"
  chmod +x "$stub_directory/gh"
  export STUB_GH_CAPTURE_FILE="$CAPTURE_FILE"

  local body_file="$WORK_DIRECTORY/body.md"
  printf '## Symptom\nTest.\n' > "$body_file"

  # Simulate the 'other' gh invocation
  PATH="$stub_directory:$PATH" gh issue create \
    --repo "gaia-react/gaia" \
    --label "gaia-forensics" \
    --title "forensics: other, unknown failure outside taxonomy" \
    --body-file "$body_file"

  rm -rf "$stub_directory"

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
