#!/usr/bin/env bats
# Tests for `.github/forensics/parse-issue-body.sh`.
#
# Coverage:
#   - deterministic regex extraction (no LLM)
#   - malformed body → needs-human signal (script returns
#     valid=false with a precise error code)
#   - redaction tokens pass through verbatim
#   - frontmatter is optional; when absent, `class` is derived from
#     the `## Classification` section content

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  PARSER="$THIS_DIR/../parse-issue-body.sh"
  FIX="$THIS_DIR/fixtures"
}

# ---------------------------------------------------------------------------
# Happy path: a SPEC-001-conformant body parses to valid JSON with the four
# required sections and the three required frontmatter keys.
# ---------------------------------------------------------------------------

@test "valid body returns valid:true" {
  run "$PARSER" "$FIX/valid.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"valid":true'* ]]
}

@test "valid body extracts class from frontmatter" {
  run "$PARSER" "$FIX/valid.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"class":"quality-gate"'* ]]
}

@test "valid body extracts gaia_version from frontmatter" {
  run "$PARSER" "$FIX/valid.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"gaia_version":"1.4.2"'* ]]
}

@test "valid body extracts created from frontmatter" {
  run "$PARSER" "$FIX/valid.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"created":"2026-05-08"'* ]]
}

@test "valid body extracts optional gh_issue_url when present" {
  run "$PARSER" "$FIX/valid.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"gh_issue_url":"https://github.com/gaia-react/gaia/issues/123"'* ]]
}

@test "valid body extracts symptom section" {
  run "$PARSER" "$FIX/valid.md"
  [ "$status" -eq 0 ]
  # Body contains backtick-fenced inline code; ensure it survives.
  [[ "$output" == *'pnpm typecheck'* ]]
  [[ "$output" == *'TS2304'* ]]
}

@test "valid body extracts classification section" {
  run "$PARSER" "$FIX/valid.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'class: quality-gate'* ]]
  [[ "$output" == *'evidence:'* ]]
}

@test "valid body extracts capture section preserving fenced block" {
  run "$PARSER" "$FIX/valid.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'node_version: v20.11.0'* ]]
  [[ "$output" == *'pnpm_version: 9.0.0'* ]]
}

@test "valid body extracts reproduction_context section" {
  run "$PARSER" "$FIX/valid.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'.claude/hooks/wiki-session-stop.sh'* ]]
  [[ "$output" == *'.claude/hooks/post-tool.sh'* ]]
}

# ---------------------------------------------------------------------------
# Failure modes, UAT-013 (malformed body → needs-human without LLM).
# Each failure emits valid:false plus a precise error code.
# ---------------------------------------------------------------------------

@test "missing symptom returns missing-section" {
  run "$PARSER" "$FIX/missing-symptom.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"valid":false'* ]]
  [[ "$output" == *'"error":"missing-section"'* ]]
  [[ "$output" == *'"symptom"'* ]]
}

@test "missing frontmatter still parses; class is derived from Classification" {
  # Frontmatter is optional. The GH-issue body shape ships without one
  # in some workflows; `class` is derived from the `class: <tag>` line
  # inside the `## Classification` section instead.
  run "$PARSER" "$FIX/missing-frontmatter.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"valid":true'* ]]
  [[ "$output" == *'"class":"other"'* ]]
}

@test "malformed section header returns malformed-section-header" {
  run "$PARSER" "$FIX/malformed-section-header.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"valid":false'* ]]
  [[ "$output" == *'"error":"malformed-section-header"'* ]]
  [[ "$output" == *'"Bogus Header"'* ]]
}

@test "frontmatter without closing delimiter returns malformed-frontmatter" {
  body_file="$BATS_TEST_TMPDIR/no-close.md"
  cat > "$body_file" <<'EOF'
---
class: hook
gaia_version: 1.4.2
created: 2026-05-08

## Symptom

Body without the closing frontmatter delimiter.

## Classification

class: hook
evidence: none.

## Capture

```
empty
```

## Reproduction context

- `.claude/hooks/x.sh`
EOF
  run "$PARSER" "$body_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"valid":false'* ]]
  [[ "$output" == *'"error":"malformed-frontmatter"'* ]]
}

@test "frontmatter missing class falls through to Classification derivation" {
  # When the frontmatter doesn't carry `class:` and the `## Classification`
  # section also lacks a `class: <tag>` line, the parser reports the
  # missing class explicitly rather than treating it as a frontmatter
  # problem, `class` is the one load-bearing field downstream.
  body_file="$BATS_TEST_TMPDIR/no-class.md"
  cat > "$body_file" <<'EOF'
---
gaia_version: 1.4.2
created: 2026-05-08
---

## Symptom

x

## Classification

x

## Capture

x

## Reproduction context

x
EOF
  run "$PARSER" "$body_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"valid":false'* ]]
  [[ "$output" == *'"error":"missing-class"'* ]]
}

@test "frontmatterless body with class in Classification parses cleanly" {
  body_file="$BATS_TEST_TMPDIR/no-fm.md"
  cat > "$body_file" <<'EOF'
## Symptom

`/update-gaia` skipped a file even though the manifest declared it owned.

## Classification

class: update
evidence: "three-way merge" + .gaia/manifest.json

## Capture

gaia_version: 1.4.2
node: v22.0.0

## Reproduction context

Routine /update-deps run; downstream CI broke because a file was missing.
EOF
  run "$PARSER" "$body_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"valid":true'* ]]
  [[ "$output" == *'"class":"update"'* ]]
  [[ "$output" == *'"gaia_version":"1.4.2"'* ]]
}

@test "empty section body returns empty-section" {
  body_file="$BATS_TEST_TMPDIR/empty-symptom.md"
  cat > "$body_file" <<'EOF'
---
class: hook
gaia_version: 1.4.2
created: 2026-05-08
---

## Symptom

## Classification

x

## Capture

x

## Reproduction context

x
EOF
  run "$PARSER" "$body_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"valid":false'* ]]
  [[ "$output" == *'"error":"empty-section"'* ]]
  [[ "$output" == *'"symptom"'* ]]
}

@test "all four sections missing reports them all" {
  body_file="$BATS_TEST_TMPDIR/no-sections.md"
  cat > "$body_file" <<'EOF'
---
class: other
gaia_version: 1.4.2
created: 2026-05-08
---

just freeform text, no headers at all.
EOF
  run "$PARSER" "$body_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"valid":false'* ]]
  [[ "$output" == *'"error":"missing-section"'* ]]
  [[ "$output" == *'"symptom"'* ]]
  [[ "$output" == *'"classification"'* ]]
  [[ "$output" == *'"capture"'* ]]
  [[ "$output" == *'"reproduction_context"'* ]]
}

# ---------------------------------------------------------------------------
# UAT-015, redaction tokens pass through verbatim.
# ---------------------------------------------------------------------------

@test "redaction tokens pass through symptom verbatim" {
  run "$PARSER" "$FIX/redaction-passthrough.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'<redacted>'* ]]
}

@test "redaction tokens pass through capture verbatim" {
  run "$PARSER" "$FIX/redaction-passthrough.md"
  [ "$status" -eq 0 ]
  # capture section contains both tokens; both must appear byte-identically.
  [[ "$output" == *'api_key: <redacted>'* ]]
  [[ "$output" == *'config_path: <repo-relative-paths>'* ]]
  [[ "$output" == *'git_branch: feature/<redacted>-fix'* ]]
}

@test "redaction tokens pass through reproduction_context verbatim" {
  run "$PARSER" "$FIX/redaction-passthrough.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'- `<repo-relative-paths>`'* ]]
  [[ "$output" == *'file at `<repo-relative-paths>` referencing `<redacted>`'* ]]
}

@test "optional gh_issue_url is null when absent from frontmatter" {
  run "$PARSER" "$FIX/redaction-passthrough.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"gh_issue_url":null'* ]]
}

# ---------------------------------------------------------------------------
# CLI / script-error contract.
# ---------------------------------------------------------------------------

@test "no args prints usage and exits 2" {
  run "$PARSER"
  [ "$status" -eq 2 ]
}

@test "missing input file exits 2" {
  run "$PARSER" "$BATS_TEST_TMPDIR/does-not-exist.md"
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Determinism, re-running on the same input is byte-identical (UAT-009
# in spirit: deterministic, not LLM-touched).
# ---------------------------------------------------------------------------

@test "parser output is byte-identical across two runs (determinism)" {
  run "$PARSER" "$FIX/valid.md"
  first="$output"
  run "$PARSER" "$FIX/valid.md"
  [ "$output" = "$first" ]
}

# ---------------------------------------------------------------------------
# SPEC-003 UAT-006, pipefail + internal-error JSON envelope. When awk
# fails, the script must NOT fall through to a default valid:false; it
# must emit `{"internal_error":true,...}` so the workflow can distinguish
# infrastructure failure from a malformed body.
# ---------------------------------------------------------------------------

@test "pipefail preamble is declared" {
  grep -qE '^set -uo pipefail' "$PARSER"
}

@test "awk failure emits internal-error JSON envelope (not valid:false)" {
  # Shadow `awk` with a stub that always exits non-zero. The script is
  # invoked via `env PATH=...` so it picks up the stub before the system
  # awk. Exit-code check on the FIRST awk call (frontmatter-extract)
  # fires immediately.
  fake_bin="$BATS_TEST_TMPDIR/fake-bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/awk" <<'STUB'
#!/usr/bin/env bash
exit 7
STUB
  chmod +x "$fake_bin/awk"

  run env PATH="$fake_bin:$PATH" "$PARSER" "$FIX/valid.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"internal_error":true'* ]]
  [[ "$output" == *'"stage":"frontmatter-extract"'* ]]
  [[ "$output" == *'"exit_code":7'* ]]
  # Critical: the failure path does NOT pretend to be a malformed body.
  [[ "$output" != *'"valid":false'* ]]
}

# ---------------------------------------------------------------------------
# JSON shape sanity, make sure the success JSON contains all required
# top-level keys.
# ---------------------------------------------------------------------------

@test "success JSON contains frontmatter and sections objects" {
  run "$PARSER" "$FIX/valid.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"frontmatter":{'* ]]
  [[ "$output" == *'"sections":{'* ]]
  [[ "$output" == *'"symptom":'* ]]
  [[ "$output" == *'"classification":'* ]]
  [[ "$output" == *'"capture":'* ]]
  [[ "$output" == *'"reproduction_context":'* ]]
}

# ---------------------------------------------------------------------------
# Control-byte hygiene, `json_escape_file` strips raw 0x01–0x1f bytes so
# the emitted JSON stays valid even on pathological input.
# ---------------------------------------------------------------------------

@test "embedded control bytes do not break the emitted JSON" {
  fixture="$BATS_TEST_TMPDIR/control-bytes.md"
  # Build a SPEC-001-shaped body whose Symptom contains a 0x01 byte.
  # If the byte leaks through, jq rejects the output as invalid JSON.
  ctrl="$(printf 'before\x01after')"
  {
    printf -- '---\n'
    printf 'class: quality-gate\n'
    printf 'gaia_version: 1.4.2\n'
    printf 'created: 2026-05-08\n'
    printf -- '---\n'
    printf '## Symptom\n\n%s\n\n' "$ctrl"
    printf '## Classification\n\nclass: quality-gate\n\n'
    printf '## Capture\n\nnode_version: v20.11.0\n\n'
    printf '## Reproduction context\n\nplaceholder\n'
  } > "$fixture"
  run "$PARSER" "$fixture"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e . > /dev/null
  # Bytes on either side of the stripped 0x01 must survive, guards
  # against a regression where the strip drops more than the control
  # byte (whole line, whole section, etc.). The control byte itself is
  # stripped, so the symptom collapses to "beforeafter".
  printf '%s' "$output" | jq -e '.sections.symptom == "beforeafter"' > /dev/null
}
