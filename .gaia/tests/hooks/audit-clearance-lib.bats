#!/usr/bin/env bats
# Tests for .claude/hooks/lib/audit-clearance.sh's clearance_scan function, the
# enumerating counterpart to the digest-keyed predicates (clearance_acceptable,
# clearance_member_cleared, clearance_member_refused) the rest of the file
# already covers indirectly through their four CONSUMER suites. This is the
# library's first unit suite.
#
# clearance_scan applies the same well-formedness key clearance_acceptable
# does (body parses as JSON; .digest equals the filename stem; .member and
# .provenance match the caller's query; .tree is non-empty), read from the
# filename instead of supplied by the caller, and drops every record that
# fails any of it.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  CLEARANCE_LIB="$REPO_ROOT/.claude/hooks/lib/audit-clearance.sh"
  [ -f "$CLEARANCE_LIB" ] || skip "audit-clearance.sh not present"
  command -v jq >/dev/null 2>&1 || skip "jq required"
}

# write_marker <path> <member> <provenance> <digest> <tree> [<version> <sha>]
# All fields are present in the body (empty string when the caller omits
# version/sha), matching what an absent key would read back as through
# clearance_field's `// empty` -- an explicit "" and a missing key are
# indistinguishable to a caller of clearance_scan.
write_marker() {
  local path="$1" member="$2" provenance="$3" digest="$4" tree="$5" version="${6:-}" sha="${7:-}"
  jq -cn \
    --arg version "$version" --arg member "$member" --arg provenance "$provenance" \
    --arg digest "$digest" --arg tree "$tree" --arg sha "$sha" \
    '{version:$version, schema:4, member:$member, provenance:$provenance,
      digest:$digest, tree:$tree, sha:$sha, audited_at:"2026-01-01T00:00:00Z"}' \
    > "$path"
}

# scan <root> <member> <provenance> -> sets $status/$output via bats' run
scan() {
  run bash -c '. "$1"; clearance_scan "$2" "$3" "$4"' \
    _ "$CLEARANCE_LIB" "$1" "$2" "$3"
}

# ---------------------------------------------------------------------------
# Acceptance criterion 1: the full acceptance/rejection matrix, all fixtures
# in one store so the accepted lines prove the rejects are actually excluded
# rather than merely never seeded.
# ---------------------------------------------------------------------------

@test "clearance_scan emits exactly the acceptable earned records for the default member" {
  ROOT="$BATS_TEST_TMPDIR/matrix"
  AUDIT_DIR="$ROOT/.gaia/local/audit"
  mkdir -p "$AUDIT_DIR"

  # Accepted: default-member earned clearance, missing version/sha.
  write_marker "$AUDIT_DIR/aaa111.ok" code-audit-frontend earned aaa111 treeA

  # Accepted: specialist earned clearance (different member, must not leak
  # into a default-member scan).
  write_marker "$AUDIT_DIR/bbb222.code-audit-maintainer-shell.ok" \
    code-audit-maintainer-shell earned bbb222 treeB v1.2.3 shaB

  # Rejected: body .digest does not equal the filename stem.
  write_marker "$AUDIT_DIR/ccc333.ok" code-audit-frontend earned different999 treeC

  # Rejected: body .member is a different member than the filename implies.
  write_marker "$AUDIT_DIR/ddd444.ok" code-audit-maintainer-node earned ddd444 treeD

  # Rejected: body .provenance is refused while scanning earned.
  write_marker "$AUDIT_DIR/eee555.ok" code-audit-frontend refused eee555 treeE

  # Rejected: .tree present but empty.
  write_marker "$AUDIT_DIR/fff666.ok" code-audit-frontend earned fff666 ""

  # Rejected: .tree key absent entirely (not just empty).
  jq -cn '{version:"", schema:4, member:"code-audit-frontend",
           provenance:"earned", digest:"ggg777"}' > "$AUDIT_DIR/ggg777.ok"

  # Rejected: not valid JSON at all -- must not crash and must print nothing.
  printf 'not json {' > "$AUDIT_DIR/hhh888.ok"

  # Rejected: old-scheme body, no .digest field at all.
  jq -cn '{member:"code-audit-frontend", provenance:"earned", tree:"treeI"}' \
    > "$AUDIT_DIR/iii999.ok"

  scan "$ROOT" code-audit-frontend earned
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
  printf '%s\n' "$output" | grep -qF "$(printf 'treeA\t\t\t')$AUDIT_DIR/aaa111.ok" || return 1
}

@test "clearance_scan emits exactly the acceptable specialist record, with version/sha carried through" {
  ROOT="$BATS_TEST_TMPDIR/specialist"
  AUDIT_DIR="$ROOT/.gaia/local/audit"
  mkdir -p "$AUDIT_DIR"
  write_marker "$AUDIT_DIR/aaa111.ok" code-audit-frontend earned aaa111 treeA
  write_marker "$AUDIT_DIR/bbb222.code-audit-maintainer-shell.ok" \
    code-audit-maintainer-shell earned bbb222 treeB v1.2.3 shaB

  scan "$ROOT" code-audit-maintainer-shell earned
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
  [ "$output" = "$(printf 'treeB\tv1.2.3\tshaB\t')$AUDIT_DIR/bbb222.code-audit-maintainer-shell.ok" ] || return 1
}

# ---------------------------------------------------------------------------
# Acceptance criterion 2: provenance families never cross.
# ---------------------------------------------------------------------------

@test "scanning refused finds the refusal family and nothing from the earned family, and vice versa" {
  ROOT="$BATS_TEST_TMPDIR/provenance"
  AUDIT_DIR="$ROOT/.gaia/local/audit"
  mkdir -p "$AUDIT_DIR"
  write_marker "$AUDIT_DIR/aaa111.ok" code-audit-frontend earned aaa111 treeA
  write_marker "$AUDIT_DIR/ccc333.refused" code-audit-frontend refused ccc333 treeC

  scan "$ROOT" code-audit-frontend earned
  [ "$status" -eq 0 ]
  grep -qF "treeA" <<<"$output" || return 1
  grep -qF "treeC" <<<"$output" && return 1

  scan "$ROOT" code-audit-frontend refused
  [ "$status" -eq 0 ]
  grep -qF "treeC" <<<"$output" || return 1
  grep -qF "treeA" <<<"$output" && return 1
  true
}

# ---------------------------------------------------------------------------
# Acceptance criterion 3: jq required, fail-closed. Empty-shim PATH idiom from
# audit-base-agreement.bats's require_jq test.
# ---------------------------------------------------------------------------

@test "with jq removed from PATH, clearance_scan prints nothing and returns 1" {
  ROOT="$BATS_TEST_TMPDIR/nojq"
  AUDIT_DIR="$ROOT/.gaia/local/audit"
  mkdir -p "$AUDIT_DIR"
  write_marker "$AUDIT_DIR/aaa111.ok" code-audit-frontend earned aaa111 treeA
  SHIM="$BATS_TEST_TMPDIR/no-jq-bin"
  mkdir -p "$SHIM"

  run bash -c 'PATH="$1"; . "$2"; clearance_scan "$3" code-audit-frontend earned' \
    _ "$SHIM" "$CLEARANCE_LIB" "$ROOT"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Acceptance criterion 4: an absent (or empty) audit directory returns 1 and
# prints nothing -- never an error, never a partial line.
# ---------------------------------------------------------------------------

@test "an absent audit directory returns 1 and prints nothing" {
  ROOT="$BATS_TEST_TMPDIR/absent"
  mkdir -p "$ROOT"
  scan "$ROOT" code-audit-frontend earned
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "an empty audit directory returns 1 and prints nothing" {
  ROOT="$BATS_TEST_TMPDIR/empty"
  mkdir -p "$ROOT/.gaia/local/audit"
  scan "$ROOT" code-audit-frontend earned
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Acceptance criterion 5: every existing function in the file is unchanged.
# Proven here structurally; the four consumer suites are run separately and
# reported green in the executor's notes, and `git diff` confirms no existing
# function body moved.
# ---------------------------------------------------------------------------

@test "every pre-existing clearance_* symbol is still defined" {
  for fn in clearance_earned_path clearance_refused_path clearance_field \
    clearance_acceptable clearance_refusal_acceptable clearance_member_cleared \
    clearance_member_refused; do
    grep -qF "${fn}() {" "$CLEARANCE_LIB" || return 1
  done
}
