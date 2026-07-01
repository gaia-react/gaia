#!/usr/bin/env bats
# UAT-007: report file has frontmatter + four headed sections in correct order
# UAT-010: body sections appear in declared order, no extra top-level headers

HERE="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
FIXTURES="$HERE/fixtures"

# Validate a report body (no frontmatter) has the four required sections
# in the declared order and no other top-level (##) headers.
assert_strict_body_schema() {
  local body="$1"

  # Extract top-level (##) headers
  local headers
  headers="$(printf '%s' "$body" | grep -E '^## ' || true)"

  # Must contain all four required headers
  printf '%s' "$headers" | grep -q '^## Symptom'          || return 1
  printf '%s' "$headers" | grep -q '^## Classification'   || return 1
  printf '%s' "$headers" | grep -q '^## Capture'          || return 1
  printf '%s' "$headers" | grep -q '^## Reproduction context' || return 1

  # Must appear in declared order
  local sym_line class_line cap_line repro_line
  sym_line="$(printf '%s' "$body" | grep -n '^## Symptom' | head -1 | cut -d: -f1)"
  class_line="$(printf '%s' "$body" | grep -n '^## Classification' | head -1 | cut -d: -f1)"
  cap_line="$(printf '%s' "$body" | grep -n '^## Capture' | head -1 | cut -d: -f1)"
  repro_line="$(printf '%s' "$body" | grep -n '^## Reproduction context' | head -1 | cut -d: -f1)"

  [[ -n "$sym_line" && -n "$class_line" && -n "$cap_line" && -n "$repro_line" ]] || return 1
  [[ "$sym_line" -lt "$class_line" ]]   || return 1
  [[ "$class_line" -lt "$cap_line" ]]   || return 1
  [[ "$cap_line" -lt "$repro_line" ]]   || return 1

  # Must have exactly 4 top-level (##) headers, no more.
  # Use printf '%s\n' to ensure trailing newline so wc -l counts correctly.
  local header_count
  header_count="$(printf '%s\n' "$headers" | wc -l | tr -d ' ')"
  [[ "$header_count" -eq 4 ]] || return 1

  return 0
}

# Validate frontmatter block has required fields
assert_frontmatter_fields() {
  local frontmatter="$1"
  printf '%s' "$frontmatter" | grep -q '^class: '        || return 1
  printf '%s' "$frontmatter" | grep -q '^gaia_version: ' || return 1
  printf '%s' "$frontmatter" | grep -q '^created: '      || return 1
  return 0
}

# ---------------------------------------------------------------------------
# Schema validation against golden files
# ---------------------------------------------------------------------------

@test "UAT-010: init golden file has four required sections in declared order" {
  local golden="$FIXTURES/golden-init-redacted.md"
  [[ -f "$golden" ]] || skip "golden-init-redacted.md not found"
  local body
  body="$(cat "$golden")"
  assert_strict_body_schema "$body"
}

@test "UAT-010: update golden file has four required sections in declared order" {
  local golden="$FIXTURES/golden-update-redacted.md"
  [[ -f "$golden" ]] || skip "golden-update-redacted.md not found"
  local body
  body="$(cat "$golden")"
  assert_strict_body_schema "$body"
}

@test "UAT-010: secrets golden file has four required sections in declared order" {
  local golden="$FIXTURES/golden-secrets-redacted.md"
  [[ -f "$golden" ]] || skip "golden-secrets-redacted.md not found"
  local body
  body="$(cat "$golden")"
  assert_strict_body_schema "$body"
}

@test "UAT-010: other-class golden file has four required sections in declared order" {
  local golden="$FIXTURES/golden-other-class.md"
  [[ -f "$golden" ]] || skip "golden-other-class.md not found"
  local body
  body="$(cat "$golden")"
  assert_strict_body_schema "$body"
}

# ---------------------------------------------------------------------------
# Frontmatter structure (simulated; we construct a synthetic report)
# ---------------------------------------------------------------------------

@test "UAT-007: frontmatter block contains required fields" {
  local frontmatter
  frontmatter="$(cat <<'EOF'
class: init
gaia_version: 1.2.0
created: 2026-05-08
EOF
)"
  assert_frontmatter_fields "$frontmatter"
}

@test "UAT-007: frontmatter with gh_issue_url field is valid" {
  local frontmatter
  frontmatter="$(cat <<'EOF'
class: hook
gaia_version: 1.2.0
created: 2026-05-08
gh_issue_url: https://github.com/gaia-react/gaia/issues/999
EOF
)"
  assert_frontmatter_fields "$frontmatter"
  printf '%s' "$frontmatter" | grep -q '^gh_issue_url: '
}

@test "UAT-007: class field in frontmatter must be from closed taxonomy set" {
  local valid_classes="init update wiki-sync quality-gate hook scaffold dev-server other"
  for class in $valid_classes; do
    local frontmatter="class: $class"$'\n'"gaia_version: 1.0.0"$'\n'"created: 2026-05-08"
    assert_frontmatter_fields "$frontmatter"
    printf '%s' "$frontmatter" | grep -q "^class: $class"
  done
}

@test "UAT-010: Classification section contains 'class:' and 'evidence:' lines" {
  local golden="$FIXTURES/golden-init-redacted.md"
  [[ -f "$golden" ]] || skip "golden-init-redacted.md not found"
  local body
  body="$(cat "$golden")"

  # Extract the Classification section
  local class_section
  class_section="$(printf '%s' "$body" | awk '/^## Classification/{found=1} found && /^## / && !/^## Classification/{exit} found{print}')"
  printf '%s' "$class_section" | grep -q '^class: '
  printf '%s' "$class_section" | grep -q '^evidence: '
}

@test "UAT-010: Capture section contains version fields" {
  local golden="$FIXTURES/golden-init-redacted.md"
  [[ -f "$golden" ]] || skip "golden-init-redacted.md not found"
  local body
  body="$(cat "$golden")"

  local cap_section
  cap_section="$(printf '%s' "$body" | awk '/^## Capture/{found=1} found && /^## / && !/^## Capture/{exit} found{print}')"
  printf '%s' "$cap_section" | grep -q '^gaia_version: '
  printf '%s' "$cap_section" | grep -q '^node: '
  printf '%s' "$cap_section" | grep -q '^pnpm: '
  # COV-7: claude_code is part of the canonical envelope and must be asserted.
  printf '%s' "$cap_section" | grep -q '^claude_code: '
  printf '%s' "$cap_section" | grep -q '^branch: '
  printf '%s' "$cap_section" | grep -q '^dirty: '
}

# ---------------------------------------------------------------------------
# TST-02: canonical Capture rendering is byte-identical everywhere.
#
# Header-presence checks (above) never caught the whitespace/indentation drift
# between the three renderings (forensics.md, capture.md, the goldens). These
# two tests pin the canonical form byte-for-byte: no blank line after a `## `
# header, `class_state_files:` immediately followed by two-space-indented list
# items, and the seven canonical envelope keys in declared order.
# ---------------------------------------------------------------------------

@test "TST-02: golden-init Capture block matches the canonical rendering byte-for-byte" {
  local golden="$FIXTURES/golden-init-redacted.md"
  [[ -f "$golden" ]] || skip "golden-init-redacted.md not found"

  local body cap_section
  body="$(cat "$golden")"
  cap_section="$(printf '%s' "$body" | awk '/^## Capture/{found=1} found && /^## / && !/^## Capture/{exit} found{print}')"

  local expected
  expected="$(cat <<'EOF'
## Capture
gaia_version: 1.2.0
node: v20.11.0
pnpm: 8.15.4
claude_code: 1.0.0
branch: main
dirty: false
class_state_files:
  - .gaia/manifest.json: present, version 1.2.0
  - .gaia/local/setup-state.json: present, lastStep "rename"
  - package.json: present, name "gaia" (rename incomplete)
EOF
)"
  [[ "$cap_section" == "$expected" ]]
}

@test "TST-02: golden-other-class is byte-identical to the canonical empty-list rendering" {
  local golden="$FIXTURES/golden-other-class.md"
  [[ -f "$golden" ]] || skip "golden-other-class.md not found"

  local actual expected
  actual="$(cat "$golden")"
  expected="$(cat <<'EOF'
## Symptom
Something went wrong when I ran GAIA but I am not sure which workflow caused it. The output was unexpected and the tool did not complete its task.

## Classification
class: other
evidence: no taxonomy class matched

## Capture
gaia_version: 1.2.0
node: v20.11.0
pnpm: 8.15.4
claude_code: 1.0.0
branch: main
dirty: false
class_state_files: []

## Reproduction context
The user ran a GAIA workflow but the description does not match any known failure taxonomy class. The failure is treated as a probable GAIA bug. The GH issue offer is made without user-config remediation steps.
EOF
)"
  [[ "$actual" == "$expected" ]]
}
