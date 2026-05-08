#!/usr/bin/env bats
# Tests for `.github/forensics/render-prompt.sh`.
#
# SPEC-003 UAT-001 / UAT-002 / UAT-003 / UAT-004. The shipped workflow's
# inline `awk -v` rendering blocks failed on multi-line section content,
# corrupted `&` characters via `gsub` replacement-string semantics, and
# could not be exercised by bats. This suite covers the structural fix:
# every render edge-case the shipped renderer would have mishandled, plus
# the contract's exit-code surface (missing template, malformed args,
# unknown keys, duplicate keys, empty values, values containing `=`).

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIR/../render-prompt.sh"
  FIXTURES="$THIS_DIR/fixtures"
  [ -x "$SCRIPT" ] || skip "render-prompt.sh not executable"
}

# --- 1. Basic substitution -------------------------------------------------

@test "basic: single placeholder substitutes" {
  run "$SCRIPT" "$FIXTURES/render-template-special-chars.md" \
    "SYMPTOM=hello" \
    "CAPTURE=world"
  [ "$status" -eq 0 ]
  [ "$output" = "Symptom: hello
Capture: world" ]
}

# --- 2. Multi-line value (UAT-001) -----------------------------------------

@test "multi-line value preserves all lines verbatim" {
  multi=$'line1\nline2\nline3'
  run "$SCRIPT" "$FIXTURES/render-template-special-chars.md" \
    "SYMPTOM=x" \
    "CAPTURE=$multi"
  [ "$status" -eq 0 ]
  [ "$output" = "Symptom: x
Capture: line1
line2
line3" ]
}

# --- 3. Multi-line value with fenced code block (UAT-001) ------------------

@test "multi-line value containing a fenced code block round-trips" {
  fenced=$'```bash\nset -e\necho hi\n```'
  run "$SCRIPT" "$FIXTURES/render-template-multiline.md" \
    "ISSUE_NUMBER=42" \
    "CAPTURE=$fenced"
  [ "$status" -eq 0 ]
  [ "$output" = 'Issue #42

## Capture

```
```bash
set -e
echo hi
```
```

## End' ]
}

# --- 4. Ampersand in value (UAT-002) ---------------------------------------

@test "ampersand in value passes through literally (no & replacement-string expansion)" {
  run "$SCRIPT" "$FIXTURES/render-template-special-chars.md" \
    "SYMPTOM=install fails & dev-server hangs" \
    "CAPTURE=x"
  [ "$status" -eq 0 ]
  [ "$output" = "Symptom: install fails & dev-server hangs
Capture: x" ]
}

# --- 5. Backslash in value (UAT-002) ---------------------------------------

@test "backslashes in value pass through literally" {
  run "$SCRIPT" "$FIXTURES/render-template-special-chars.md" \
    "SYMPTOM=x" \
    'CAPTURE=C:\path\to\file'
  [ "$status" -eq 0 ]
  [ "$output" = 'Symptom: x
Capture: C:\path\to\file' ]
}

# --- 6. Forward slash in value (defensive) ---------------------------------

@test "forward slashes in value pass through literally" {
  run "$SCRIPT" "$FIXTURES/render-template-special-chars.md" \
    "SYMPTOM=x" \
    "CAPTURE=/path/to/file"
  [ "$status" -eq 0 ]
  [ "$output" = "Symptom: x
Capture: /path/to/file" ]
}

# --- 7. Placeholder token in value (UAT-003) -------------------------------

@test "placeholder token inside a value is NOT re-substituted by a later pass" {
  # CAPTURE substitutes first (lexical order in args is preserved by the
  # script). Its value contains the literal string `{{SYMPTOM}}`. SYMPTOM's
  # subsequent pass MUST NOT re-substitute that string — single-pass-per-
  # placeholder guarantee.
  run "$SCRIPT" "$FIXTURES/render-template-placeholder-collision.md" \
    "CAPTURE=user wrote {{SYMPTOM}} in their capture" \
    "SYMPTOM=actual-symptom"
  [ "$status" -eq 0 ]
  [ "$output" = "Symptom: actual-symptom
Capture: user wrote {{SYMPTOM}} in their capture" ]
}

# --- 8. Multiple placeholders, mixed values --------------------------------

@test "all seven classifier tokens substitute with no cross-contamination" {
  run "$SCRIPT" "$FIXTURES/render-template-basic.md" \
    "ISSUE_NUMBER=999" \
    "SYMPTOM=sym-val" \
    "CLASSIFICATION=cls-val" \
    "CAPTURE=cap-val" \
    "REPRO_CONTEXT=rep-val" \
    "ALLOWLIST=al-val" \
    "DENYLIST=dl-val"
  [ "$status" -eq 0 ]
  [ "$output" = "Issue #999 classifier prompt.

Symptom: sym-val
Classification: cls-val
Capture: cap-val
Reproduction context: rep-val
Allowlist: al-val
Denylist: dl-val" ]
}

# --- 9. Missing template file ---------------------------------------------

@test "missing template file: exit 2 with stderr message" {
  run "$SCRIPT" "/nonexistent/template.md" "FOO=bar"
  [ "$status" -eq 2 ]
  [[ "$output" == *"template not found"* ]]
}

# --- 10. Malformed key=value arg ------------------------------------------

@test "malformed key=value (no '='): exit 2" {
  run "$SCRIPT" "$FIXTURES/render-template-basic.md" "FOO"
  [ "$status" -eq 2 ]
  [[ "$output" == *"malformed key=value"* ]]
}

# --- 11. Key not in template ----------------------------------------------

@test "key not present in template: exit 2 with key name" {
  run "$SCRIPT" "$FIXTURES/render-template-special-chars.md" \
    "SYMPTOM=x" \
    "CAPTURE=y" \
    "BOGUS=z"
  [ "$status" -eq 2 ]
  [[ "$output" == *"BOGUS"* ]]
  [[ "$output" == *"not present in template"* ]]
}

# --- 12. Duplicate key arg -------------------------------------------------

@test "duplicate key: exit 2 with key name" {
  run "$SCRIPT" "$FIXTURES/render-template-special-chars.md" \
    "SYMPTOM=a" \
    "SYMPTOM=b" \
    "CAPTURE=c"
  [ "$status" -eq 2 ]
  [[ "$output" == *"duplicate key"* ]]
  [[ "$output" == *"SYMPTOM"* ]]
}

# --- 13. Empty value -------------------------------------------------------

@test "empty value substitutes to empty string" {
  run "$SCRIPT" "$FIXTURES/render-template-special-chars.md" \
    "SYMPTOM=" \
    "CAPTURE=x"
  [ "$status" -eq 0 ]
  # Template has `Symptom: {{SYMPTOM}}` — empty value collapses the
  # placeholder but the literal space before it stays. The expected
  # string has a trailing space after `Symptom:`.
  expected="Symptom: "$'\n'"Capture: x"
  [ "$output" = "$expected" ]
}

# --- 14. Value containing `=` ---------------------------------------------

@test "value containing '=' splits on first '=' only" {
  run "$SCRIPT" "$FIXTURES/render-template-special-chars.md" \
    "SYMPTOM=a=b=c" \
    "CAPTURE=x"
  [ "$status" -eq 0 ]
  [ "$output" = "Symptom: a=b=c
Capture: x" ]
}

# --- 15. Idempotency / determinism ----------------------------------------

@test "two consecutive runs with identical inputs produce byte-identical output" {
  out1="$BATS_TEST_TMPDIR/out1"
  out2="$BATS_TEST_TMPDIR/out2"
  multi=$'line1\nline2 with & ampersand\nline3 with \\ backslash'
  "$SCRIPT" "$FIXTURES/render-template-basic.md" \
    "ISSUE_NUMBER=42" \
    "SYMPTOM=s" \
    "CLASSIFICATION=c" \
    "CAPTURE=$multi" \
    "REPRO_CONTEXT=r" \
    "ALLOWLIST=a" \
    "DENYLIST=d" > "$out1"
  "$SCRIPT" "$FIXTURES/render-template-basic.md" \
    "ISSUE_NUMBER=42" \
    "SYMPTOM=s" \
    "CLASSIFICATION=c" \
    "CAPTURE=$multi" \
    "REPRO_CONTEXT=r" \
    "ALLOWLIST=a" \
    "DENYLIST=d" > "$out2"
  cmp "$out1" "$out2"
}

# --- 16. Newline termination ----------------------------------------------
# Workflow YAML pipes the rendered output into a $GITHUB_OUTPUT heredoc; if
# the last byte is not a newline, the closing delimiter ends up appended to
# the last content line and the heredoc parser rejects it
# ("Matching delimiter not found"). Lock the invariant.

@test "rendered output ends with a newline byte" {
  out="$BATS_TEST_TMPDIR/out"
  "$SCRIPT" "$FIXTURES/render-template-basic.md" \
    "ISSUE_NUMBER=42" \
    "SYMPTOM=s" \
    "CLASSIFICATION=c" \
    "CAPTURE=cap" \
    "REPRO_CONTEXT=r" \
    "ALLOWLIST=a" \
    "DENYLIST=d" > "$out"
  last_byte="$(tail -c 1 "$out" | od -An -c | tr -d ' ')"
  [ "$last_byte" = "\\n" ]
}

@test "rendered output ends with a newline even when template has no trailing newline" {
  template="$BATS_TEST_TMPDIR/no-trailing.md"
  printf '%s' "Issue {{ISSUE_NUMBER}}" > "$template"
  out="$BATS_TEST_TMPDIR/out"
  "$SCRIPT" "$template" "ISSUE_NUMBER=42" > "$out"
  last_byte="$(tail -c 1 "$out" | od -An -c | tr -d ' ')"
  [ "$last_byte" = "\\n" ]
}

# --- 17. Empty template ----------------------------------------------------
# A 0-byte template trips the per-key "key not present in template" check on
# the first supplied key, exiting 2. The behavior is correct (a template that
# substitutes nothing is meaningless) but undocumented; pin it.

@test "empty template rejects all keys with exit 2" {
  template="$BATS_TEST_TMPDIR/empty.md"
  : > "$template"
  run "$SCRIPT" "$template" "FOO=bar"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not present in template"* ]]
}
