#!/usr/bin/env bats
# .gaia/tests/forensics/unit.bats; SPEC-002 layer B regression suite.
#
# This file delegates to the bats suites under `.github/forensics/tests/`
# (parser, scope-checker, verdict-parser, handlers, quality-gate runner)
# AND adds layer-A fixture invariants:
#
#   - the six `valid-*` / `non-issue-*` / `redaction-*` / `denylist-*` /
#     `unenumerated-*` fixtures parse cleanly (`.valid == true`);
#   - the two `malformed-*` fixtures parse to the documented error code;
#   - the `redaction-passthrough` fixture's two redaction tokens survive
#     the parser byte-for-byte (UAT-015);
#   - `denylist-attempt` (UAT-007) and `unenumerated-attempt` (UAT-014)
#     resolve to `ok:false` via `check-scope.sh`.
#
# UATs covered automatically by layer A+B (no GitHub round-trip):
#   UAT-003 (handlers.bats / parse-verdict.bats), UAT-007, UAT-009,
#   UAT-013, UAT-014, UAT-015.
#
# Layer C (manual checklist) covers UAT-001 / UAT-002 / UAT-004 /
# UAT-005 / UAT-006 / UAT-008 / UAT-010 / UAT-011 / UAT-012; see
# `.gaia/tests/forensics/integration.md`.

setup() {
  # Resolve repo root from the test file location: this file lives at
  # `.gaia/tests/forensics/unit.bats`, so the repo root is three levels up.
  REPO_ROOT="$( cd "$( dirname "$BATS_TEST_FILENAME" )/../../.." && pwd )"
  FORENSICS_DIR="$REPO_ROOT/.github/forensics"
  FIXTURES_DIR="$REPO_ROOT/.gaia/tests/forensics/fixtures"
  PARSER="$FORENSICS_DIR/parse-issue-body.sh"
  SCOPE="$FORENSICS_DIR/check-scope.sh"
}

# ---------------------------------------------------------------------------
# Delegation: run every bats suite under `.github/forensics/tests/` so a
# single `pnpm test:forensics` invocation runs the entire forensics
# regression surface. Each suite emits its own ok/not ok lines; this file
# adds a single bats test that wraps the run and checks the exit code.
# ---------------------------------------------------------------------------

@test "delegate: .github/forensics/tests/*.bats all green" {
  run bats "$FORENSICS_DIR/tests/"
  if [ "$status" -ne 0 ]; then
    echo "$output"
  fi
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Layer-A fixture invariants; `valid` group.
# ---------------------------------------------------------------------------

@test "fixture valid-init-failure parses cleanly" {
  run "$PARSER" "$FIXTURES_DIR/valid-init-failure.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"valid":true'* ]]
  [[ "$output" == *'"class":"init"'* ]]
}

@test "fixture valid-update-conflict parses cleanly" {
  run "$PARSER" "$FIXTURES_DIR/valid-update-conflict.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"valid":true'* ]]
  [[ "$output" == *'"class":"update"'* ]]
}

@test "fixture non-issue-config parses cleanly" {
  run "$PARSER" "$FIXTURES_DIR/non-issue-config.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"valid":true'* ]]
  [[ "$output" == *'"class":"dev-server"'* ]]
}

# ---------------------------------------------------------------------------
# Layer-A fixture invariants; `malformed` group (UAT-013).
# ---------------------------------------------------------------------------

@test "fixture malformed-missing-symptom returns missing-section" {
  run "$PARSER" "$FIXTURES_DIR/malformed-missing-symptom.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"valid":false'* ]]
  [[ "$output" == *'"error":"missing-section"'* ]]
  [[ "$output" == *'"symptom"'* ]]
}

@test "fixture malformed-frontmatter returns malformed-frontmatter" {
  run "$PARSER" "$FIXTURES_DIR/malformed-frontmatter.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"valid":false'* ]]
  [[ "$output" == *'"error":"malformed-frontmatter"'* ]]
}

# ---------------------------------------------------------------------------
# Layer-A fixture invariants; UAT-015 redaction passthrough.
#
# The fixture deliberately carries TWO tokens: a `<redacted>` literal AND
# a repo-relative path (`.gaia/cli/src/config/load.ts`) derived from an
# absolute path. Both must survive the parser byte-for-byte.
# ---------------------------------------------------------------------------

@test "fixture redaction-passthrough preserves <redacted> token verbatim" {
  run "$PARSER" "$FIXTURES_DIR/redaction-passthrough.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'<redacted>'* ]]
  [[ "$output" == *'api_key: <redacted>'* ]]
}

@test "fixture redaction-passthrough preserves repo-relative path token verbatim" {
  run "$PARSER" "$FIXTURES_DIR/redaction-passthrough.md"
  [ "$status" -eq 0 ]
  # Two distinct sites: capture (`config_path: ...`) and reproduction context.
  [[ "$output" == *'config_path: .gaia/cli/src/config/load.ts'* ]]
  [[ "$output" == *'.gaia/cli/src/config/load.ts'* ]]
}

# ---------------------------------------------------------------------------
# Layer-A fixture invariants; UAT-007 (denylist) and UAT-014 (unenumerated).
#
# Both fixtures parse as VALID bodies; the boundary they exercise is the
# scope checker that the workflow runs AFTER the classifier proposes
# paths. We feed the proposed paths through `check-scope.sh` directly.
# ---------------------------------------------------------------------------

@test "fixture denylist-attempt parses cleanly (boundary tested via check-scope)" {
  run "$PARSER" "$FIXTURES_DIR/denylist-attempt.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"valid":true'* ]]
}

@test "UAT-007: mixed allow + deny path proposal denies the whole attempt" {
  # The fixture's reproduction-context names two paths: one in the allowlist
  # (`.claude/hooks/`), one on the canonical denylist (`app/`). Per UAT-007
  # the WHOLE attempt is denied; `ok:false`; not just the denylisted path.
  run "$SCOPE" .claude/hooks/wiki-session-stop.sh app/routes/_index.tsx
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":false'* ]]
  [[ "$output" == *'app/routes/_index.tsx'* ]]
  [[ "$output" == *'"reason":"denylist"'* ]]
  # The allowed leg still appears in `allowed[]`; the partition is informational
  # but `ok` is false, which is what the workflow gates on.
  [[ "$output" == *'.claude/hooks/wiki-session-stop.sh'* ]]
}

@test "fixture unenumerated-attempt parses cleanly (boundary tested via check-scope)" {
  run "$PARSER" "$FIXTURES_DIR/unenumerated-attempt.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"valid":true'* ]]
}

@test "UAT-014: unenumerated path (package.json) denied as default-deny-unenumerated" {
  run "$SCOPE" package.json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":false'* ]]
  [[ "$output" == *'"reason":"default-deny-unenumerated"'* ]]
}
