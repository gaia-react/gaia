#!/usr/bin/env bats
# Tests for .claude/hooks/lib/audit-rules-changed.sh, the two-tier reset
# predicate for a Code Audit Team member's per-member review base.
#
# The two tiers are asymmetric in blast radius: a GLOBAL match resets every
# member's anchor, a MEMBER match resets only the member whose own agent
# definition changed, and everything else in the shared machinery set resets
# nobody (it still rotates digests, it just does not throw away a sound
# incremental anchor). These tests pin that boundary directly against the
# real AUDIT_GLOBAL_RULES_PATHS literal rather than a restated copy, so the
# suite stays honest if the literal grows.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  RULES_LIB="$REPO_ROOT/.claude/hooks/lib/audit-rules-changed.sh"
  [ -f "$RULES_LIB" ] || skip "audit-rules-changed.sh not present"
  # shellcheck source=/dev/null
  . "$RULES_LIB"
}

@test "every path in AUDIT_GLOBAL_RULES_PATHS is matched by audit_path_is_global_rule" {
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in "#"*) continue ;; esac
    case "$entry" in
      *"/**") probe="${entry%\*\*}quality-gate.md" ;;
      *) probe="$entry" ;;
    esac
    audit_path_is_global_rule "$probe" || { echo "not matched: $probe" >&2; return 1; }
  done <<<"$AUDIT_GLOBAL_RULES_PATHS"
}

@test "a merely-shared machinery path is not matched by audit_path_is_global_rule" {
  run audit_path_is_global_rule ".claude/hooks/local-janitor.sh"
  [ "$status" -ne 0 ]

  run audit_path_is_global_rule ".github/workflows/code-review-audit.yml"
  [ "$status" -ne 0 ]

  run audit_path_is_global_rule ".gaia/scripts/audit-write-findings.sh"
  [ "$status" -ne 0 ]
}

@test "the two gate-governing rules under .claude/rules/ are global" {
  run audit_path_is_global_rule ".claude/rules/quality-gate.md"
  [ "$status" -eq 0 ]

  run audit_path_is_global_rule ".claude/rules/pr-merge.md"
  [ "$status" -eq 0 ]
}

# The split this pins: a convention rule still rotates every digest (it is
# machinery), but it no longer throws away a sound anchor. A regression here
# reads as a green suite and a roster that silently re-reads its whole owned
# surface on every rule edit, so it is asserted by name rather than by prefix.
@test "a coding-convention rule under .claude/rules/ is not global" {
  run audit_path_is_global_rule ".claude/rules/tailwind.md"
  [ "$status" -ne 0 ]

  run audit_path_is_global_rule ".claude/rules/code-comments.md"
  [ "$status" -ne 0 ]

  run audit_path_is_global_rule ".claude/rules/maintainers/hook-registration.md"
  [ "$status" -ne 0 ]

  run audit_path_is_global_rule ".claude/rules/anything-new.md"
  [ "$status" -ne 0 ]
}

@test "audit_path_is_member_rule matches a member's own agent file and no other" {
  run audit_path_is_member_rule ".claude/agents/code-audit-frontend.md" "code-audit-frontend"
  [ "$status" -eq 0 ]

  run audit_path_is_member_rule ".claude/agents/code-audit-frontend.md" "code-audit-maintainer-shell"
  [ "$status" -ne 0 ]
}

@test "audit_path_is_member_rule returns 1 for an empty member" {
  run audit_path_is_member_rule ".claude/agents/code-audit-frontend.md" ""
  [ "$status" -ne 0 ]
}

@test "audit_rules_reset_for reports the global tier on a global-rules path" {
  run audit_rules_reset_for "code-audit-frontend" <<<".gaia/VERSION"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'global\t.gaia/VERSION')" ]
}

@test "audit_rules_reset_for reports the member tier on the member's own agent file" {
  run audit_rules_reset_for "code-audit-frontend" <<<".claude/agents/code-audit-frontend.md"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'member\t.claude/agents/code-audit-frontend.md')" ]
}

@test "audit_rules_reset_for returns 1 on a delta of only merely-shared machinery" {
  run audit_rules_reset_for "code-audit-frontend" <<'EOF'
.claude/hooks/local-janitor.sh
.gaia/scripts/audit-write-findings.sh
EOF
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "an empty member evaluates the global tier only" {
  run audit_rules_reset_for "" <<<".claude/agents/code-audit-frontend.md"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "a #-comment line inside the literal is never matched as a path" {
  run audit_path_is_global_rule "# gaia:maintainer-only:start"
  [ "$status" -ne 0 ]

  run audit_path_is_global_rule "# gaia:maintainer-only:end"
  [ "$status" -ne 0 ]
}
