#!/usr/bin/env bats

# Tests the /update-gaia opt-in nudge snapshot gate (SKILL Step 7 setup + Step 10).
#
# The nudge for the per-author audit mode must fire only when the adopter's
# installed .gaia/audit-ci.yml predates the feature (no default_mode key). The
# gate is a snapshot captured BEFORE the Step 7c merge can write default_mode;
# gating on the post-merge file state would let the merge pre-silence the nudge
# on the very run that should surface it.
#
# This exercises the exact grep one-liner the SKILL uses (kept in lock-step here)
# against fixture files.

# Mirror of the SKILL's Step 7 setup snapshot capture.
snapshot_default_mode() {
  local file="$1"
  if [ -f "$file" ] && grep -qE '^[[:space:]]*default_mode[[:space:]]*:' "$file"; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

setup() {
  FIXTURE="$BATS_TEST_TMPDIR/audit-ci.yml"
}

@test "opt-in nudge: snapshot taken before merge, key written by merge does not pre-silence" {
  # Pre-merge installed file predates the feature: no default_mode.
  printf 'gate_label: null\noverride_label: run-audit\n' > "$FIXTURE"
  had_default_mode_before_merge="$(snapshot_default_mode "$FIXTURE")"
  [ "$had_default_mode_before_merge" = "false" ]

  # The Step 7c merge now writes default_mode into the file.
  printf 'gate_label: null\ndefault_mode: ci\noverride_label: run-audit\n' > "$FIXTURE"

  # The STASHED snapshot is still false, so the nudge fires this run even though
  # the current file now has the key. (A post-merge re-read would wrongly silence.)
  [ "$had_default_mode_before_merge" = "false" ]
  [ "$(snapshot_default_mode "$FIXTURE")" = "true" ]  # the file does now carry it
}

@test "opt-in nudge: adopter config already has default_mode → snapshot true → no nudge" {
  printf 'gate_label: null\ndefault_mode: local\noverride_label: run-audit\n' > "$FIXTURE"
  [ "$(snapshot_default_mode "$FIXTURE")" = "true" ]
}

@test "opt-in nudge: a commented-out default_mode does not count as present" {
  # A leading '#' means the key is not declared; the reader would default it.
  printf 'gate_label: null\n# default_mode: ci\n' > "$FIXTURE"
  [ "$(snapshot_default_mode "$FIXTURE")" = "false" ]
}

@test "opt-in nudge: absent audit-ci.yml → snapshot false (nudge fires)" {
  [ "$(snapshot_default_mode "$BATS_TEST_TMPDIR/does-not-exist.yml")" = "false" ]
}
