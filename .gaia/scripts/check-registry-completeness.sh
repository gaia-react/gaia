#!/usr/bin/env bash
# shellcheck shell=bash
#
# Check B-completeness -- registry <-> frozen inventory denominator
# (state-registry conformance model, foundations task 2.3, design
# analysis/registry-design.md §4.3).
#
# Mechanizes SPEC-061 UAT-002: the union of live `entries` and `residue`
# equals the frozen inventory denominator, every live entry sits in exactly
# one scope, and none is unclassified or double-placed. The
# scope/dup/enum-validity half of that invariant is already asserted
# directly against the registry by
# .gaia/scripts/tests/state-registry-lib.bats's own structural tests (no
# duplicate ids across entries+residue; every scope value is one of the four
# enum members; keyed_by required iff scope=="shared"; every required field
# present) -- this script does not repeat those. It adds the one thing they
# do not cover: whether the registry's OWN id set still matches what it was
# authored against.
#
# The inventory denominator (analysis/gaia-local-state-inventory.md) lives in
# the sibling program repo, one level above this checkout, and is never read
# at runtime here -- a conformance check that reaches across repos is not
# meaningful in CI, where only this repo is checked out. Instead this script
# embeds the expected id set as a checked-in snapshot, taken from the
# registry as task 2.3 built it. A later hand-edit that silently drops an
# id, duplicates one under a new name, or adds one without updating this
# snapshot fails here -- which is the point: this is the one-time-frozen half
# of Check B (design §4.3), not a perpetual gate against the registry ever
# growing. A deliberate registry change (a later phase adding a
# newly-scoped entry) updates GAIA_REGISTRY_COMPLETENESS_ENTRY_IDS /
# GAIA_REGISTRY_COMPLETENESS_RESIDUE_IDS below in the same change, exactly as
# the denominator spot-check array in state-registry-lib.bats is updated
# when the registry's shape changes.
#
# Dual-mode: source it for gaia_check_registry_completeness, or run it
# directly (see "Executable entry" at the bottom). Relies on
# gaia_registry_path resolving against the process cwd (via
# main-root-lib.sh), same as every other state-registry-lib.sh consumer --
# run it from inside the repo whose registry is under test.

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/state-registry-lib.sh"

# Frozen at task 2.3's build, one id per line, sorted -- matches
# `jq -r '.entries[].id' .gaia/state-registry.json | sort`.
GAIA_REGISTRY_COMPLETENESS_ENTRY_IDS='
audit-clearance-markers
audit-findings-rerun-sidecars
audit-progress-log
audit-security-notes
audit-window-breadcrumb
audit-worthiness-ledger
cache-shared
debt-count-and-refresh
declined-updates
forensics
gh-artifact-pr-cache
handoff
harden-declines
health-audit-scratch-files
health-audit-scratch-subtrees
machine-markers
plans-main
project-id
react-perf-run-scratch
red-ledger
setup-state
spec-audit-scratch
spec-chain-guard
spec-draft-and-gate1-scratch
spec-session-scratch
specs-main
statusline-wrappers
telemetry-cost-ledger
v2-update-notes
version-check-lock
wiki-promote-and-uat-write-scratch
worktree-locks
'

# Frozen at task 2.3's build, one id per line, sorted -- matches
# `jq -r '.residue[].id' .gaia/state-registry.json | sort`.
GAIA_REGISTRY_COMPLETENESS_RESIDUE_IDS='
audit-carried-markers-residue
cache-shared-coaching-active-residue
mentorship-config
mentorship-swept-sentinel-residue
plans-archived-residue
specs-archived-residue
telemetry-analytics-residue
telemetry-cloud-residue
'

# gaia_check_registry_completeness
#   Compares the registry's current .entries[].id set and .residue[].id set
#   (each sorted) against the frozen snapshots above. Prints a diff-style
#   report on any mismatch. Returns 0 when both match exactly, 1 otherwise.
gaia_check_registry_completeness() {
  local registry
  registry="$(gaia_registry_path)" || return 1

  local expected_entries expected_residue actual_entries actual_residue
  expected_entries="$(printf '%s\n' "$GAIA_REGISTRY_COMPLETENESS_ENTRY_IDS" | sed '/^$/d' | sort)"
  expected_residue="$(printf '%s\n' "$GAIA_REGISTRY_COMPLETENESS_RESIDUE_IDS" | sed '/^$/d' | sort)"
  actual_entries="$(jq -r '.entries[].id' "$registry" | sort)"
  actual_residue="$(jq -r '.residue[].id' "$registry" | sort)"

  local rc=0
  if [ "$actual_entries" != "$expected_entries" ]; then
    printf 'REGISTRY ENTRY ID SET CHANGED (diff expected -> actual):\n'
    diff <(printf '%s\n' "$expected_entries") <(printf '%s\n' "$actual_entries")
    rc=1
  fi
  if [ "$actual_residue" != "$expected_residue" ]; then
    printf 'REGISTRY RESIDUE ID SET CHANGED (diff expected -> actual):\n'
    diff <(printf '%s\n' "$expected_residue") <(printf '%s\n' "$actual_residue")
    rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    printf 'registry id set matches the frozen inventory denominator: %d entries, %d residue\n' \
      "$(printf '%s\n' "$actual_entries" | sed '/^$/d' | wc -l | tr -d ' ')" \
      "$(printf '%s\n' "$actual_residue" | sed '/^$/d' | wc -l | tr -d ' ')"
  fi
  return $rc
}

# Executable entry.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  gaia_check_registry_completeness
  exit $?
fi
