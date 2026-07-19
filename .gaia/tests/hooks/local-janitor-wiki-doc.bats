#!/usr/bin/env bats
#
# Wiki/source conformance for the session-start janitor's sweep enumeration.
# The "## The session-start janitor" section in
# wiki/concepts/Local Working State.md must enumerate one bullet per janitor
# sweep, its stated count numeral must equal both the enumerated bullet count
# and the sweep count derived from .claude/hooks/local-janitor.sh source, and
# the outlier sweep's own documentation must name its three retention knobs
# and state the maxdepth-1 scope and never-traverse zones. This mechanically
# enforces the agreement so the enumeration cannot silently drift when a
# sweep is added, removed, or renumbered.
#
# Assertion style note: per .claude/rules/bats-assertions.md, non-final
# absence checks use a positive match for the bad case plus an explicit
# `return 1`, never `!`-negation; final-line absence uses `!`-negation since
# its own status is the test result there.

setup() {
  HOOK_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/local-janitor.sh
  WIKI_ABS=$(cd "$BATS_TEST_DIRNAME/../../../wiki/concepts" && pwd)/"Local Working State.md"
}

# source_sweep_count: the number of distinct `# --- N.` sweep-section headers
# in the janitor source, deduped by the integer N. The `2b.` re-run ledger
# sub-block is written `# 2b.`, not `# --- `, so it never matches here and is
# never double-counted.
source_sweep_count() {
  grep -oE '^# --- [0-9]+\. ' "$HOOK_ABS" | grep -oE '[0-9]+' | sort -un | wc -l | tr -d ' '
}

# janitor_section: the session-start janitor section body, from its heading
# (exclusive) to the next `## ` heading (exclusive).
janitor_section() {
  awk '
    /^## The session-start janitor/ { found = 1; next }
    found && /^## / { exit }
    found { print }
  ' "$WIKI_ABS"
}

# numeral_to_int: map the number-word following "It sweeps " to an integer.
# Echoes -1 for an unrecognized word so callers can reject it.
numeral_to_int() {
  case "$1" in
    one) echo 1 ;;
    two) echo 2 ;;
    three) echo 3 ;;
    four) echo 4 ;;
    five) echo 5 ;;
    six) echo 6 ;;
    seven) echo 7 ;;
    eight) echo 8 ;;
    nine) echo 9 ;;
    ten) echo 10 ;;
    *) echo -1 ;;
  esac
}

@test "AC-1: the janitor source declares a non-degenerate count of numbered sweep headers, exactly nine" {
  run source_sweep_count
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
  [ "$output" -eq 9 ]
}

@test "AC-2: the wiki's stated sweep numeral maps to the same integer as the source-derived count" {
  section=$(janitor_section)
  [ -n "$section" ]

  numeral=$(grep -oE 'It sweeps [a-z]+ things' <<< "$section" | grep -oE '[a-z]+ things' | cut -d' ' -f1)
  [ -n "$numeral" ]

  stated=$(numeral_to_int "$numeral")
  [ "$stated" -gt 0 ]

  source_count=$(source_sweep_count)
  [ "$stated" -eq "$source_count" ]
}

@test "AC-3: the section's enumerated bullet count equals the source-derived sweep count" {
  section=$(janitor_section)
  bullet_count=$(grep -cE '^- \*\*' <<< "$section")
  source_count=$(source_sweep_count)
  [ "$bullet_count" -eq "$source_count" ]
}

@test "AC-4: the outlier sweep documents all three retention knobs, the maxdepth-1 scope, and the never-traverse zones" {
  section=$(janitor_section)
  [ -n "$section" ]

  grep -qF -- 'GAIA_OUTLIER_RETENTION_DAYS' <<< "$section"
  grep -qF -- 'GAIA_AUDIT_FINDINGS_RETENTION_HOURS' <<< "$section"
  grep -qF -- 'GAIA_CACHE_ARTIFACT_RETENTION_DAYS' <<< "$section"
  grep -qF -- 'maxdepth-1' <<< "$section"

  for zone in telemetry red-ledger handoff plans specs debt forensics archived security comprehensive; do
    grep -qF -- "$zone" <<< "$section" || return 1
  done
}

@test "AC-5: the janitor section carries no SPEC/UAT identifier, commit sha, or dated/was-now phrasing" {
  section=$(janitor_section)
  [ -n "$section" ]

  grep -qE "UAT-[0-9]+|SPEC-[0-9]+" <<< "$section" && return 1

  ! grep -qE "\bchanged from|was changed|previously (did|was|stated|had|used)|previously set|as of [0-9]{4}|in PR #?[0-9]+|in commit [a-f0-9]{6,}" <<< "$section"
}
