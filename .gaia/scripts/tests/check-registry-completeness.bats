#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/check-registry-completeness.sh --
# Check B-completeness of the state-registry conformance model (foundations
# task 2.3, design analysis/registry-design.md §4.3, DECISIONS.md D-024).
# CI-runnable, one-time-frozen: asserts the registry's live `entries` union
# `residue` id set still matches the snapshot taken when task 2.3 built the
# registry (the mechanized form of SPEC-061 UAT-002's "union == denominator,
# nothing unclassified, nothing double-placed"). The
# scope/dup/enum/required-field half of that invariant is already covered by
# .gaia/scripts/tests/state-registry-lib.bats's own structural tests; this
# suite does not repeat those, only the id-set freeze.
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/check-registry-completeness.bats`.
#
# Assertion style note: per .claude/rules/bats-assertions.md, non-final
# absence checks use a positive match for the bad case plus an explicit
# `return 1`, never `!`-negation; equality/numeric/empty checks use POSIX
# `[ ... ]`, which fails correctly on every bash version.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CHECK="$SCRIPT_DIR/check-registry-completeness.sh"
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  # shellcheck source=.gaia/scripts/check-registry-completeness.sh
  source "$CHECK"
}

# run_in_repo <fn> [args...]: cwd = the real repo root regardless of where
# bats itself was invoked from, so gaia_registry_path resolves THIS repo's
# registry. Mirrors state-registry-lib.bats's own helper.
run_in_repo() {
  run bash -c '
    cd "$1" || exit 1
    # shellcheck disable=SC1090
    source "$2"
    shift 2
    "$@"
  ' _ "$REPO_ROOT" "$CHECK" "$@"
}

@test "structural: check-registry-completeness.sh is executable" {
  [ -x "$CHECK" ]
}

@test "structural: sourcing the script defines gaia_check_registry_completeness with no side effects" {
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    type gaia_check_registry_completeness >/dev/null
    echo OK
  ' _ "$CHECK"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "real repo: the registry id set matches the frozen inventory denominator (hard gate)" {
  run_in_repo gaia_check_registry_completeness
  [ "$status" -eq 0 ]
  grep -qF "registry id set matches the frozen inventory denominator" <<<"$output" || return 1
}

@test "real repo: the frozen snapshot's counts match the registry's actual entries/residue lengths" {
  local registry="$REPO_ROOT/.gaia/state-registry.json"
  local actual_entries actual_residue
  actual_entries="$(jq -r '.entries | length' "$registry")"
  actual_residue="$(jq -r '.residue | length' "$registry")"
  grep -qF "$actual_entries entries, $actual_residue residue" \
    <(run_in_repo gaia_check_registry_completeness; printf '%s\n' "$output") || return 1
}

@test "fixture: a dropped entry id fails with a diff" {
  local dir="$BATS_TEST_TMPDIR/dropped-fixture"
  mkdir -p "$dir/.gaia"
  cat >"$dir/.gaia/state-registry.json" <<'JSON'
{
  "$schema": "./state-registry.schema.json",
  "version": 1,
  "description": "fixture",
  "entries": [
    {
      "id": "only-entry",
      "path": "only.json",
      "match": "exact",
      "kind": "file",
      "scope": "main-only",
      "keyed_by": null,
      "why": "fixture",
      "writer": "code",
      "reaped_by": null,
      "source": "fixture"
    }
  ],
  "residue": []
}
JSON
  git init -q --initial-branch=main "$dir"
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name T
  git -C "$dir" config commit.gpgsign false
  git -C "$dir" add -A
  git -C "$dir" commit -q -m init

  run bash -c '
    cd "$1" || exit 1
    # shellcheck disable=SC1090
    source "$2"
    gaia_check_registry_completeness
  ' _ "$dir" "$CHECK"
  [ "$status" -eq 1 ]
  grep -qF "REGISTRY ENTRY ID SET CHANGED" <<<"$output" || return 1
}
