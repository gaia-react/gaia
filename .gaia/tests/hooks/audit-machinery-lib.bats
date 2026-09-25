#!/usr/bin/env bats
# Tests for .claude/hooks/lib/audit-machinery.sh, the one machinery-path
# matcher for the Code Audit Team.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  MACHINERY_LIB="$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh"
  [ -f "$MACHINERY_LIB" ] || skip "audit-machinery.sh not present"
  # shellcheck source=/dev/null
  . "$MACHINERY_LIB"
}

# The gate-machinery lockstep set: files whose change must rotate every
# member's digest. An entry dropped from AUDIT_MACHINERY_PATHS fails open (a
# change to that file merges without forcing any re-audit), so each one is
# asserted by name. Files covered by a `/**` prefix entry are listed too, so
# narrowing that prefix reds here.

@test "every gate-machinery file is matched by audit_path_is_machinery" {
  unmatched=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    audit_path_is_machinery "$f" || unmatched="$unmatched $f"
  done <<'EOF'
.gaia/audit-ci.yml
.claude/hooks/lib/audit-scope.sh
.claude/hooks/lib/audit-machinery.sh
.claude/hooks/lib/audit-base-provenance.sh
.claude/hooks/lib/audit-clearance.sh
.claude/hooks/lib/audit-digest.sh
.claude/hooks/lib/audit-selfheal-paths.sh
.claude/hooks/lib/gaia-version.sh
.gaia/scripts/audit-write-clearance.sh
.gaia/scripts/audit-member-digest.sh
.gaia/scripts/audit-resolve-scope.sh
.gaia/scripts/resolve-audit-members.sh
.gaia/scripts/audit-noop-detect.sh
.claude/hooks/pr-merge-audit-check.sh
.claude/hooks/post-audit-status.sh
.claude/hooks/audit-stamp-trailer.sh
.claude/hooks/block-selfheal-paths.sh
.github/audit/resolve-audit-base.sh
.github/audit/audit-success-present.sh
.github/audit/gate-pending-members.sh
.github/workflows/code-review-audit.yml
.gaia/cli/templates/workflows/code-review-audit.yml.tmpl
.gaia/cli/src/automation/templates/workflows/code-review-audit.yml.tmpl
.claude/agents/code-audit-frontend.md
.claude/agents/code-audit-maintainer-shell.md
.claude/agents/code-audit-maintainer-node.md
.claude/agents/code-audit-github-workflows.md
.gaia/VERSION
EOF
  [ -z "$unmatched" ] || { printf 'not matched by audit_path_is_machinery:%s\n' "$unmatched" >&2; return 1; }
}
