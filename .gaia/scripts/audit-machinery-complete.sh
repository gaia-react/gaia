#!/usr/bin/env bash
# audit-machinery-complete.sh: the gate-machinery completeness check.
#
# Under per-member digest keying, only files matched by audit_path_is_machinery
# land in every member's digest. An unlisted gate-machinery file is therefore a
# fail-open (a change to it rotates no member's key, so it merges unaudited by
# the members it should force), not a cosmetic gap. This check carries a
# HARDCODED list of the gate-machinery files -- the lockstep consumer set -- and
# asserts each is matched by audit_path_is_machinery. It prints each unmatched
# file on stderr and exits non-zero if any gap exists; exits 0 when complete.
#
# The list is the post-cutover final state (it reflects where the tree lands
# after the cutover phases). audit-carry-forward.sh is deliberately absent: that
# file is deleted, not machinery.
#
# Bash 3.2 compatible. Never `cd` (outside the source-time lib resolution).
set -uo pipefail

# Source the machinery lib from THIS script's own on-disk location, never cwd:
# .gaia/scripts -> ../../.claude/hooks/lib.
_self_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.claude/hooks/lib" 2>/dev/null && pwd)" || true
if [ -n "${_self_lib_dir:-}" ] && [ -f "$_self_lib_dir/audit-machinery.sh" ]; then
  # shellcheck source=/dev/null
  . "$_self_lib_dir/audit-machinery.sh"
fi

if ! command -v audit_path_is_machinery >/dev/null 2>&1; then
  printf 'audit-machinery-complete.sh: machinery library unavailable\n' >&2
  exit 1
fi

# The gate-machinery lockstep consumer set. Each must be matched by
# audit_path_is_machinery after the machinery-list edits (several are covered by
# a `/**` prefix entry; the rest are exact entries).
GATE_MACHINERY_FILES="$(cat <<'EOF'
.gaia/audit-ci.yml
.claude/hooks/lib/audit-scope.sh
.claude/hooks/lib/audit-machinery.sh
.claude/hooks/lib/audit-clearance.sh
.claude/hooks/lib/audit-digest.sh
.claude/hooks/lib/audit-dispositions.sh
.claude/hooks/lib/audit-selfheal-paths.sh
.gaia/scripts/audit-write-clearance.sh
.gaia/scripts/audit-member-digest.sh
.gaia/scripts/audit-machinery-complete.sh
.gaia/scripts/resolve-audit-members.sh
.gaia/scripts/resolve-audit-spawn.sh
.gaia/scripts/audit-noop-detect.sh
.claude/hooks/pr-merge-audit-check.sh
.claude/hooks/audit-disposition-check.sh
.claude/hooks/post-audit-status.sh
.claude/hooks/audit-stamp-trailer.sh
.claude/hooks/local-janitor.sh
.claude/hooks/block-selfheal-paths.sh
.github/audit/check-trailer.sh
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
.claude/agents/code-audit-maintainer-prose.md
.gaia/VERSION
EOF
)"

missing=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if ! audit_path_is_machinery "$f"; then
    printf 'gate-machinery file not matched by audit_path_is_machinery: %s\n' "$f" >&2
    missing=$((missing + 1))
  fi
done <<EOF
$GATE_MACHINERY_FILES
EOF

if [ "$missing" -gt 0 ]; then
  printf 'audit-machinery-complete.sh: %d gate-machinery file(s) unmatched by AUDIT_MACHINERY_PATHS\n' "$missing" >&2
  exit 1
fi
exit 0
