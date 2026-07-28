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

# source_sweep9_doc: the ninth sweep's own paragraph in the janitor source's
# header block, from its numbered opener to the blank comment line that ends
# it. The two derivations below read this rather than restating what it says:
# the wiki page names the janitor source as the authoritative home for the
# sweep's mechanics, so a guard that checks the page against a copy kept here
# can only ever drift away from the thing it is guarding.
source_sweep9_doc() {
  awk '/^#   9\. off-pattern outlier residue/, /^#$/' "$HOOK_ABS"
}

# source_sweep9_knobs: the retention-knob names that paragraph mentions, one
# per line. Derived, so retiring or adding a knob in the source updates what
# the wiki is required to document without anyone editing this file.
source_sweep9_knobs() {
  source_sweep9_doc | grep -oE 'GAIA_[A-Z_]+' | sort -u
}

# source_never_traverse_zones: the zone names the paragraph declares the sweep
# never walks into, one per line, bare (no trailing slash) so the wiki may
# write them either way. Read from the "never include ..." clause alone, which
# is why the range stops at the `--` that closes it: the rest of the paragraph
# names paths for other reasons.
source_never_traverse_zones() {
  source_sweep9_doc \
    | sed -n '/zones it walks never include/,/--/p' \
    | tr ' ,' '\n\n' \
    | grep -oE '^[a-z][a-z-]*/$' \
    | tr -d '/' \
    | sort -u
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

@test "AC-4: the outlier sweep's retention knobs, maxdepth-1 scope, and never-traverse zones agree with the janitor source" {
  section=$(janitor_section)
  [ -n "$section" ]

  grep -qF -- 'maxdepth-1' <<< "$section"

  # A floor, not merely non-emptiness: the sweep's paragraph names two
  # retention knobs (the sweep #2 findings window and the sweep #5 cache
  # window), so a derivation that silently collapsed to one would still be
  # non-empty and the loop below would still pass. Same shape as the zone
  # floor further down, and it moves only when the source paragraph does.
  knobs=$(source_sweep9_knobs)
  [ "$(wc -l <<< "$knobs" | tr -d ' ')" -ge 2 ]
  while read -r knob; do
    grep -qF -- "$knob" <<< "$section" || return 1
  done <<< "$knobs"

  zones=$(source_never_traverse_zones)
  [ "$(wc -l <<< "$zones" | tr -d ' ')" -ge 8 ]
  while read -r zone; do
    grep -qF -- "$zone" <<< "$section" || return 1
  done <<< "$zones"
}

@test "AC-5: the janitor section carries no SPEC/UAT identifier, commit sha, or dated/was-now phrasing" {
  section=$(janitor_section)
  [ -n "$section" ]

  grep -qE "UAT-[0-9]+|SPEC-[0-9]+" <<< "$section" && return 1

  ! grep -qE "\bchanged from|was changed|previously (did|was|stated|had|used)|previously set|as of [0-9]{4}|in PR #?[0-9]+|in commit [a-f0-9]{6,}" <<< "$section"
}
