#!/usr/bin/env bash
# audit-rules-changed.sh: the reset predicate for a Code Audit Team member's
# PER-MEMBER review base. Sourced, never executed; does no work at source time.
#
# Generating rule: within the shared machinery set (audit-machinery.sh), some
# files decide which paths a member owns, which paths count as machinery, how
# a digest is computed, whether a clearance is believed, which members are
# dispatched, where the gate looks for a clearance, or under which version any
# of that was decided. A change to one of those invalidates every member's
# anchor, because the rules the anchor was judged sound under have moved. This
# is the GLOBAL tier: AUDIT_GLOBAL_RULES_PATHS below.
#
# The generating rule is about SCOPE and BELIEF, never about CRITERIA. A
# coding-convention rule under .claude/rules/ changes how code should be
# written, not which paths a member owns or whether a clearance is honored,
# so it is NOT global. An anchor records that a member READ a surface, and
# rewording a convention does not un-read it; what a convention change owes is
# a fresh clearance for the diff under review, and .claude/rules/** sits in
# AUDIT_MACHINERY_PATHS, so that is already owed. Holding criteria to
# invalidate anchors would ask this merge gate to re-sweep every owned surface
# for retroactive conformance, which is not the job it does, at the price of
# making a one-word rule edit the most expensive change in the repository.
# The two rules that DO decide gate mechanics are named individually below.
#
# A member's own agent definition (.claude/agents/<member>.md) is a second,
# narrower case: it decides only what that one member reviews and how, so it
# resets only that member's anchor. This is the MEMBER tier.
#
# Everything else in the machinery set is merely shared: it still rotates
# digests (a fresh clearance is still required before the merge gate opens),
# but it does not invalidate a standing incremental anchor. This file is that
# carve-out; it never widens or narrows AUDIT_MACHINERY_PATHS itself.
#
# This file lands under .claude/hooks/lib/, which the machinery matcher's
# `.claude/hooks/lib/**` prefix entry already sweeps, so it is machinery by
# construction and needs no entry of its own in AUDIT_MACHINERY_PATHS.
#
# Matching semantics mirror audit_path_is_machinery: the same `/**`-directory-
# prefix and exact-path rules, the same unconditional `*.bats` exclusion, plus
# explicit `#`-comment skipping. audit_path_is_machinery has no comment
# skipping (a `#` line there falls through to its exact-match arm and can
# never equal a real path); that accident is not good enough here, because
# this file's literal is also walked as DATA by the completeness check.
#
# No entry below ends in `/**`, so the prefix arm and the `*.bats` early
# return decide nothing today. Both are retained deliberately: they keep this
# matcher's semantics identical to audit_path_is_machinery, which still
# carries `/**` entries and still excludes suites, so a `/**` entry re-added
# here inherits the exclusion instead of silently losing it. Deleting either
# arm as dead code is what would introduce the defect.
#
# The `# gaia:maintainer-only` markers around resolve-audit-spawn.sh mark it
# release-excluded; an adopter bundle must not carry a bare reference to a
# file the adopter does not have.
#
# Bash 3.2 compatible (macOS default). Never `cd`.

AUDIT_GLOBAL_RULES_PATHS="$(cat <<'EOF'
.gaia/VERSION
.gaia/audit-ci.yml
.claude/hooks/lib/audit-scope.sh
.claude/hooks/lib/audit-machinery.sh
.claude/hooks/lib/audit-clearance.sh
.claude/hooks/lib/audit-digest.sh
.claude/hooks/lib/audit-rules-changed.sh
.claude/hooks/lib/audit-base-provenance.sh
# gaia-version.sh derives the version literal every producer stamps and every
# reader compares for equality, so a change to it can make a standing clearance
# stop matching. It is global for the same reason the stampers and readers that
# used to hold the idiom inline (audit-stamp-trailer.sh, post-audit-status.sh,
# pr-merge-audit-check.sh, resolve-audit-base.sh) already are: extracting the
# logic must not quietly demote the tier it was reviewed under.
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
# The two rules under .claude/rules/ that govern the gate rather than the
# code. quality-gate.md decides the deterministic checks a clearance
# stands on, and pr-merge.md decides the marker handshake: where the gate
# looks for a clearance and when one is believed. Every other rule in that
# directory is coding convention, is merely shared, and is enumerated in
# AUDIT_MERELY_SHARED_PATHS in .gaia/scripts/audit-rules-changed-complete.sh.
.claude/rules/quality-gate.md
.claude/rules/pr-merge.md
EOF
)"

# audit_path_is_global_rule <path> -> exit 0 iff the path is in the set above.
audit_path_is_global_rule() {
  local path="$1" entry prefix

  case "$path" in
    *.bats) return 1 ;;
  esac

  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in
      "#"*) continue ;;
      *"/**")
        prefix="${entry%\*\*}"
        case "$path" in
          "$prefix"*) return 0 ;;
        esac
        ;;
      *)
        [ "$path" = "$entry" ] && return 0
        ;;
    esac
  done <<EOF
$AUDIT_GLOBAL_RULES_PATHS
EOF

  return 1
}

# audit_path_is_member_rule <path> <member> -> exit 0 iff <member> is
# non-empty and <path> is exactly .claude/agents/<member>.md.
audit_path_is_member_rule() {
  local path="$1" member="$2"

  [ -n "$member" ] || return 1
  [ "$path" = ".claude/agents/${member}.md" ]
}

# audit_rules_reset_for <member>: BATCH, newline-delimited paths on stdin.
# Per path, in order: global tier first, then the member tier. Prints
# "<tier>\t<path>" for the FIRST reset-forcing path and returns 0; returns 1,
# printing nothing, when no path forces a reset. <tier> is the literal
# "global" or "member". An empty <member> evaluates the global tier only.
#
# Returns on the first hit without draining stdin, exactly like
# audit_delta_has_machinery. Every caller must feed this by here-string,
# never by pipe: a piped `git diff` writing past the pipe buffer after an
# early return takes SIGPIPE, and under `set -o pipefail` the pipeline status
# collapses to false, silently skipping the reset.
audit_rules_reset_for() {
  local member="$1" path

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if audit_path_is_global_rule "$path"; then
      printf 'global\t%s\n' "$path"
      return 0
    fi
    if audit_path_is_member_rule "$path" "$member"; then
      printf 'member\t%s\n' "$path"
      return 0
    fi
  done

  return 1
}
