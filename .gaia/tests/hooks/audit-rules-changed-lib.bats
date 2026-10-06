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
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  RULES_LIBRARY="$REPO_ROOT/.claude/hooks/lib/audit-rules-changed.sh"
  [ -f "$RULES_LIBRARY" ] || skip "audit-rules-changed.sh not present"
  # shellcheck source=/dev/null
  . "$RULES_LIBRARY"
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
  run audit_path_is_global_rule ".claude/hooks/lib/audit-selfheal-paths.sh"
  [ "$status" -ne 0 ]

  run audit_path_is_global_rule ".github/audit/resolve-check-base.sh"
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
.claude/hooks/lib/audit-selfheal-paths.sh
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

# A GLOBAL path that is not machinery resets every member's anchor while
# rotating no digest, so a change to it demands no fresh clearance for the very
# file that resets everyone. Walks the real literal, so a new entry is covered
# the moment it lands.
@test "every path in AUDIT_GLOBAL_RULES_PATHS is also matched by audit_path_is_machinery" {
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh"
  checked=0
  unmatched=""
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in "#"*) continue ;; esac
    checked=$((checked + 1))
    audit_path_is_machinery "$entry" || unmatched="$unmatched $entry"
  done <<<"$AUDIT_GLOBAL_RULES_PATHS"

  [ "$checked" -gt 0 ]
  [ -z "$unmatched" ] || { printf 'global rule not machinery:%s\n' "$unmatched" >&2; return 1; }
}

# The router with its helper library, the light-marker script and the reviewer
# definition decide whether a clearance is believed, so a change to any of them
# resets every member's anchor. Asserted per path, with a sibling that must
# stay out.

@test "each light-review file is a global rule and is also machinery" {
  . "$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh"
  for light_path in \
    .gaia/scripts/audit-light-route.sh \
    .claude/hooks/lib/audit-light-route-lib.sh \
    .gaia/scripts/audit-light-mark.sh \
    .claude/agents/audit-light-reviewer.md; do
    audit_path_is_global_rule "$light_path" || { echo "not a global rule: $light_path" >&2; return 1; }
    audit_path_is_machinery "$light_path" || { echo "global but not machinery: $light_path" >&2; return 1; }
  done
}

@test "audit_rules_reset_for reports the global tier for a light-review file" {
  run audit_rules_reset_for "code-audit-frontend" <<<".gaia/scripts/audit-light-mark.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'global\t.gaia/scripts/audit-light-mark.sh')" ]
}

@test "a sibling of a light-review file is not a global rule" {
  audit_path_is_global_rule ".gaia/scripts/audit-light-route.sh" || return 1
  run audit_path_is_global_rule ".gaia/scripts/audit-light-route.sh.bak"
  [ "$status" -ne 0 ]
  run audit_path_is_global_rule ".gaia/scripts/audit-light-telemetry.sh"
  [ "$status" -ne 0 ]
  run audit_path_is_global_rule ".claude/hooks/lib/audit-light-route-lib.sh.bak"
  [ "$status" -ne 0 ]
  run audit_path_is_global_rule ".claude/agents/audit-light-reviewer.md.orig"
  [ "$status" -ne 0 ]
}
