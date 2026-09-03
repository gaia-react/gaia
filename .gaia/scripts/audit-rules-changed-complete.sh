#!/usr/bin/env bash
# audit-rules-changed-complete.sh: the two-tier reset-predicate completeness
# check.
#
# Contract A carves a GLOBAL and a MEMBER tier out of the shared machinery
# set (audit-machinery.sh) for a different decision than machinery-set
# membership: whether a standing per-member review anchor is still sound, not
# whether a fresh clearance is required. A gate-machinery file silently left
# out of AUDIT_GLOBAL_RULES_PATHS fails in the UNDER-resetting direction: it
# still rotates every member's digest (so the merge gate still demands a
# fresh clearance), but a member's stale anchor from before that file changed
# would be trusted as sound review coverage when it is not.
#
# Assertions 1 and 2 both check the same hardcoded lockstep list against the
# two libraries, so a NEW global-rules file missing from that list is missing
# from both and stays green -- neither can catch the case this check exists
# for. Assertion 3 is the one that can: it walks the machinery set from the
# outside (every tracked file audit_path_is_machinery flags) and demands each
# lands in exactly one of the three tiers, so a machinery file nobody
# classified anywhere reds by name instead of silently defaulting to
# merely-shared.
#
# Bash 3.2 compatible. Never `cd` (outside the source-time lib resolution).
set -uo pipefail

# Source both libraries from THIS script's own on-disk location, never cwd:
# .gaia/scripts -> ../../.claude/hooks/lib.
_self_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.claude/hooks/lib" 2>/dev/null && pwd)" || true
if [ -n "${_self_lib_dir:-}" ] && [ -f "$_self_lib_dir/audit-rules-changed.sh" ]; then
  # shellcheck source=/dev/null
  . "$_self_lib_dir/audit-rules-changed.sh"
fi
if [ -n "${_self_lib_dir:-}" ] && [ -f "$_self_lib_dir/audit-machinery.sh" ]; then
  # shellcheck source=/dev/null
  . "$_self_lib_dir/audit-machinery.sh"
fi

if ! command -v audit_path_is_global_rule >/dev/null 2>&1 || ! command -v audit_path_is_member_rule >/dev/null 2>&1; then
  printf 'audit-rules-changed-complete.sh: rules-changed library unavailable\n' >&2
  exit 1
fi
if ! command -v audit_machinery_flags >/dev/null 2>&1; then
  printf 'audit-rules-changed-complete.sh: machinery library unavailable\n' >&2
  exit 1
fi

repo_root="${1:-}"
if [ -z "$repo_root" ]; then
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    printf 'audit-rules-changed-complete.sh: not a git repository and no repo_root argument given\n' >&2
    exit 2
  }
fi

# 1. Lockstep completeness. Same content as AUDIT_GLOBAL_RULES_PATHS. Every
# entry there is an exact path, so this list is a byte-for-byte mirror with no
# prefix entry to spell out as a probe.
GLOBAL_RULES_FILES="$(cat <<'EOF'
.gaia/VERSION
.gaia/audit-ci.yml
.claude/hooks/lib/audit-scope.sh
.claude/hooks/lib/audit-machinery.sh
.claude/hooks/lib/audit-clearance.sh
.claude/hooks/lib/audit-digest.sh
.claude/hooks/lib/audit-rules-changed.sh
.claude/hooks/lib/audit-base-provenance.sh
.claude/hooks/lib/gaia-version.sh
.gaia/scripts/audit-write-clearance.sh
.gaia/scripts/audit-member-digest.sh
.gaia/scripts/audit-key-lib.sh
.gaia/scripts/main-root-lib.sh
.gaia/scripts/resolve-audit-members.sh
# gaia:maintainer-only:start
.gaia/scripts/resolve-audit-spawn.sh
# gaia:maintainer-only:end
.claude/hooks/audit-stamp-trailer.sh
.claude/hooks/post-audit-status.sh
.claude/hooks/pr-merge-audit-check.sh
.github/audit/resolve-audit-base.sh
.claude/rules/quality-gate.md
.claude/rules/pr-merge.md
EOF
)"

missing1=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in "#"*) continue ;; esac
  if ! audit_path_is_global_rule "$f"; then
    printf 'global-rules file not matched by audit_path_is_global_rule: %s\n' "$f" >&2
    missing1=$((missing1 + 1))
  fi
done <<EOF
$GLOBAL_RULES_FILES
EOF

# 2. Global rules are a subset of machinery: a global rule that rotates no
# member's digest would demand no fresh clearance for the very file that
# resets everyone's anchor.
missing2=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in "#"*) continue ;; esac
  if ! audit_path_is_machinery "$f"; then
    printf 'global-rules file not covered by audit_path_is_machinery: %s\n' "$f" >&2
    missing2=$((missing2 + 1))
  fi
done <<EOF
$GLOBAL_RULES_FILES
EOF

# 3. The machinery set is fully partitioned: every machinery file is global,
# a member's own agent definition, or explicitly merely-shared -- never zero
# of the three, never more than one.
AUDIT_MERELY_SHARED_PATHS="$(cat <<'EOF'
.claude/hooks/audit-disposition-check.sh
.claude/hooks/block-selfheal-paths.sh
.claude/hooks/lib/audit-dispositions.sh
.claude/hooks/lib/audit-selfheal-paths.sh
.claude/hooks/lib/gaia-active-plan.sh
.claude/hooks/lib/gaia-ci-defer.sh
.claude/hooks/lib/reader-operands.sh
.claude/hooks/lib/red-ledger.sh
.claude/hooks/lib/repo-scope.sh
.claude/hooks/lib/verb-arming-walk.sh
.claude/hooks/lib/verb-arming.sh
.claude/hooks/lib/worthiness-ledger.sh
.claude/hooks/local-janitor.sh
# The coding-convention half of .claude/rules/. That directory is machinery by
# a `/**` prefix, so every file under it needs a tier; the two that govern the
# gate are global (see audit-rules-changed.sh) and these are the rest, listed
# one by one because this matcher takes exact paths only. A `/**` form here
# could not express the split: it would sweep the two global rules back in and
# assertion 3 would red them as an overlap. Adding a rule file without adding
# it here reds by name in assertion 3, which is the intended discovery path;
# the maintainer-only hook-and-rule registration rule states the obligation.
.claude/rules/accessibility.md
.claude/rules/api-service.md
.claude/rules/bats-assertions.md
.claude/rules/code-comments.md
.claude/rules/code-search.md
.claude/rules/coding-guidelines.md
.claude/rules/dep-audit.md
.claude/rules/design-baseline.md
.claude/rules/gaia-folder.md
.claude/rules/guards-must-fail.md
.claude/rules/i18n.md
.claude/rules/instruction-files.md
.claude/rules/issue-claim.md
.claude/rules/knip.md
# gaia:maintainer-only:start
.claude/rules/maintainers/github-workflow-distribution.md
.claude/rules/maintainers/guard-and-diagnostic-surfaces.md
.claude/rules/maintainers/hook-registration.md
.claude/rules/maintainers/smoke.md
# gaia:maintainer-only:end
.claude/rules/partial-cause-reporting.md
.claude/rules/playwright.md
.claude/rules/react-router-docs.md
.claude/rules/repo-relative-paths.md
.claude/rules/routes.md
.claude/rules/serena-cc-override.md
.claude/rules/shell-cwd.md
.claude/rules/state-pattern.md
.claude/rules/storybook.md
.claude/rules/subagent-dispatch.md
.claude/rules/tailwind.md
.claude/rules/wiki-style.md
# gaia:maintainer-only:start
.gaia/cli/src/automation/templates/workflows/code-review-audit.yml.tmpl
# gaia:maintainer-only:end
.gaia/cli/templates/workflows/code-review-audit.yml.tmpl
.gaia/scripts/audit-machinery-complete.sh
.gaia/scripts/audit-rules-changed-complete.sh
.gaia/scripts/audit-noop-detect.sh
.gaia/scripts/audit-write-findings.sh
.gaia/scripts/link-worktree.sh
.gaia/scripts/read-audit-ci-config.sh
.github/audit/audit-success-present.sh
.github/audit/check-trailer.sh
.github/audit/cra-status-upsert.sh
.github/audit/gate-pending-members.sh
.github/audit/resolve-check-base.sh
.github/audit/write-audit-status.sh
.github/workflows/code-review-audit.yml
EOF
)"

_audit_rules_changed_complete_path_is_merely_shared() {
  local path="$1" entry
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in "#"*) continue ;; esac
    [ "$path" = "$entry" ] && return 0
  done <<EOF
$AUDIT_MERELY_SHARED_PATHS
EOF
  return 1
}

missing3=0
scanned3=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  scanned3=$((scanned3 + 1))
  path="${line%%$'\t'*}"
  flag="${line##*$'\t'}"
  [ "$flag" = "1" ] || continue

  member=""
  case "$path" in
    .claude/agents/code-audit-*.md)
      member="${path#.claude/agents/}"
      member="${member%.md}"
      ;;
  esac

  hits=0
  if audit_path_is_global_rule "$path"; then hits=$((hits + 1)); fi
  if [ -n "$member" ] && audit_path_is_member_rule "$path" "$member"; then hits=$((hits + 1)); fi
  if _audit_rules_changed_complete_path_is_merely_shared "$path"; then hits=$((hits + 1)); fi

  if [ "$hits" -eq 0 ]; then
    printf 'machinery file classified by none of global, member, or merely-shared: %s\n' "$path" >&2
    missing3=$((missing3 + 1))
  elif [ "$hits" -gt 1 ]; then
    printf 'machinery file classified by more than one tier (overlap): %s\n' "$path" >&2
    missing3=$((missing3 + 1))
  fi
done < <(git -C "$repo_root" -c core.quotepath=false ls-files -z | tr '\0' '\n' | audit_machinery_flags)

# An empty read is a broken discovery, never a clean partition. This loop reads
# from a process substitution, whose failure `pipefail` cannot see, and every
# counter it feeds lives inside its body, so a failing walk leaves the partition
# check passing at exit 0 while the two checks above still report normally --
# the vacuous half is invisible in the output. Every real tree carries tracked
# files, so zero rows means the discovery is wrong rather than the tree. The
# three sibling discoveries hard-error on this identical condition.
if [ "$scanned3" -eq 0 ]; then
  printf 'audit-rules-changed-complete.sh: ERROR: the tracked-file walk yielded no rows; the partition check scanned nothing\n' >&2
  exit 1
fi

if [ "$missing1" -gt 0 ]; then
  printf 'audit-rules-changed-complete.sh: %d global-rules file(s) unmatched by AUDIT_GLOBAL_RULES_PATHS\n' "$missing1" >&2
fi
if [ "$missing2" -gt 0 ]; then
  printf 'audit-rules-changed-complete.sh: %d global-rules file(s) not covered by AUDIT_MACHINERY_PATHS\n' "$missing2" >&2
fi
if [ "$missing3" -gt 0 ]; then
  printf 'audit-rules-changed-complete.sh: %d machinery file(s) failing the global/member/merely-shared partition\n' "$missing3" >&2
fi

if [ "$missing1" -gt 0 ] || [ "$missing2" -gt 0 ] || [ "$missing3" -gt 0 ]; then
  exit 1
fi
exit 0
