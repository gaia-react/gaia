#!/usr/bin/env bats
#
# Bats suite for the Code Audit Team line of the per-PR block that
# .gaia/scripts/usage-merge.sh prints at every `gh pr merge`, run through the
# real pr-merge-cost.sh hook: the roster read from .gaia/audit-ci.yml, the
# `--auditors` pass-through, the unreadable-roster marker, and the hard-error
# rule for a missing library.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/tests/hooks/usage-merge-audit-line.bats
#
# Rates in the copied table: input $2/M, output $10/M. Every spend literal below
# was added up by hand from the seeded rows.

bats_require_minimum_version 1.5.0

setup() {
  . "$BATS_TEST_DIRNAME/helpers/usage-merge-env.sh"
  # shellcheck disable=SC2034  # read by build_repo in the helper
  SOURCE_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  unset CLAUDE_CODE_SESSION_ID GAIA_TALLY_PROJECTS_ROOT GITHUB_ACTIONS GAIA_USAGE_HOOKS_DISABLE
  unset GAIA_LEDGER_LOCK_FORCE_FALLBACK GAIA_LEDGER_LOCK_TIMEOUT_SECONDS GAIA_USAGE_MERGE_CAP_SECONDS GAIA_USAGE_RENDER_CAP_SECONDS
  export GAIA_LEDGER_LOCK_POLL_SECONDS=0.1
  export GIT_AUTHOR_NAME="GAIA Test" GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test" GIT_COMMITTER_EMAIL="gaia-test@example.com"
  GH_STUB_DIRECTORY="$TEMPORARY_DIRECTORY/ghstub"
  mkdir -p "$GH_STUB_DIRECTORY" "$TEMPORARY_DIRECTORY/bin"
  export GH_STUB_DIRECTORY
  make_stubs
  export PATH="$TEMPORARY_DIRECTORY/bin:$PATH"
  build_repo
}

# agent_segment <session_id> <first_ts> <fresh> <output> <agent_type|-> [agent_id]
agent_segment() {
  if [ "$5" = - ]; then
    segment_row branch:fix/foo "$1" "$2" "$3" "$4"
  else
    segment_row branch:fix/foo "$1" "$2" "$3" "$4" | jq -c --arg agent_type "$5" --arg agent_id "${6:-}" \
      '. + {agent_type: $agent_type} + (if $agent_id == "" then {} else {agent_id: $agent_id} end)'
  fi
}

# seed_audit_branch: main-session spend, two roster-member sidecars, a
# general-purpose sidecar, an `unknown` sidecar, and one segment flushed before
# the agent fields existed. No cost store of any kind is written.
seed_audit_branch() {
  {
    agent_segment s-main 2026-09-23T09:00:00Z 100000 10000 main
    agent_segment s-main 2026-09-23T09:10:00Z 200000 20000 code-audit-frontend a1
    agent_segment s-main 2026-09-23T09:20:00Z 300000 10000 code-audit-maintainer-shell a2
    agent_segment s-main 2026-09-23T09:30:00Z 400000 0 general-purpose a3
    agent_segment s-main 2026-09-23T09:40:00Z 500000 0 unknown a4
    agent_segment s-old 2026-09-23T09:50:00Z 50000 0 -
  } >"$TELEMETRY_DIRECTORY/usage.jsonl"
  gh_view 101 101 fix/foo MERGED 2026-09-25T00:00:00Z
}

@test "the audit line sums only the roster members' spend and marks the segment that predates agent fields" {
  seed_audit_branch
  [ -z "$(find "$REPO" "$TELEMETRY_DIRECTORY" -name 'cost.js*' -print 2>/dev/null)" ]
  run_merge "gh pr merge 101"
  [ "$status" -eq 0 ]
  has_line "[PR cost] pr:101 branch:fix/foo"
  has_line "  audit (Code Audit Team): tokens 530,000  est. cost (USD): \$1.30"
  has_line "  ! lower bound: 1 segment(s) predate agent fields"
  lacks "audit line unavailable"
  lacks "[cycle cost at merge]"
}

@test "the roster is read from the audit-ci.yml of the tree the hook runs from, so a different roster sums different members" {
  seed_audit_branch
  cat >"$REPO/.gaia/audit-ci.yml" <<'EOF'
auditors:
  - name: general-purpose
    default: true
    globs:
      - "x/**"
EOF
  run_merge "gh pr merge 101"
  [ "$status" -eq 0 ]
  has_line "  audit (Code Audit Team): tokens 400,000  est. cost (USD): \$0.80"
}

@test "an unreadable roster prints the marker once after the block, no audit line, and the rest of the block" {
  seed_audit_branch
  rm "$REPO/.gaia/audit-ci.yml"
  run_merge "gh pr merge 101"
  [ "$status" -eq 0 ]
  has_line "[PR cost] pr:101 branch:fix/foo"
  has_line "  est. cost (USD): \$3.50"
  has_line "  ! audit line unavailable: no auditors roster in .gaia/audit-ci.yml"
  [ "$(grep -c 'audit line unavailable' <<<"$output")" -eq 1 ]
  lacks "audit (Code Audit Team)"
  [ "$(printf '%s\n' "$output" | tail -n 1)" = "  ! audit line unavailable: no auditors roster in .gaia/audit-ci.yml" ] || return 1
}

@test "guards-must-fail: a copy of usage-merge.sh without the marker line fails the unreadable-roster expectation" {
  seed_audit_branch
  rm "$REPO/.gaia/audit-ci.yml"
  sed '/audit line unavailable/d' "$REPO/.gaia/scripts/usage-merge.sh" >"$REPO/.gaia/scripts/usage-merge-mutant.sh"
  cmp -s "$REPO/.gaia/scripts/usage-merge.sh" "$REPO/.gaia/scripts/usage-merge-mutant.sh" && return 1
  run_script "$REPO/.gaia/scripts/usage-merge-mutant.sh" "gh pr merge 101"
  [ "$status" -eq 0 ]
  has_line "[PR cost] pr:101 branch:fix/foo"
  grep -qF "audit line unavailable" <<<"$output" && return 1
  true
}

@test "a missing usage-lib.sh makes usage-merge.sh exit non-zero naming it, and the hook prints the unavailable marker" {
  seed_audit_branch
  rm "$REPO/.gaia/scripts/usage-lib.sh"
  run --separate-stderr run_script_split "$REPO/.gaia/scripts/usage-merge.sh" "gh pr merge 101"
  [ "$status" -ne 0 ]
  grep -qF "usage-lib.sh" <<<"$stderr"
  run_merge "gh pr merge 101"
  [ "$status" -eq 0 ]
  has_line "[PR cost] unavailable: usage-merge.sh exited 1; rerun: bash .gaia/scripts/usage.sh pr 101"
}

@test "a missing audit-scope.sh makes usage-merge.sh exit non-zero naming it" {
  seed_audit_branch
  rm "$REPO/.claude/hooks/lib/audit-scope.sh"
  run --separate-stderr run_script_split "$REPO/.gaia/scripts/usage-merge.sh" "gh pr merge 101"
  [ "$status" -ne 0 ]
  grep -qF "audit-scope.sh" <<<"$stderr"
}

@test "a missing usage.sh makes usage-merge.sh exit non-zero naming it" {
  seed_audit_branch
  rm "$REPO/.gaia/scripts/usage.sh"
  run --separate-stderr run_script_split "$REPO/.gaia/scripts/usage-merge.sh" "gh pr merge 101"
  [ "$status" -ne 0 ]
  grep -qF "usage.sh" <<<"$stderr"
}

# run_script_split <script> <command>: a usage-merge.sh copy run directly, for
# a caller that wants stdout and stderr apart.
run_script_split() {
  (cd "$REPO" && printf %s "$(payload_for "$2" s-hook)" | bash "$1")
}
