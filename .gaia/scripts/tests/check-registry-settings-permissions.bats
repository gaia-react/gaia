#!/usr/bin/env bats
#
# Conformance suite for
# .gaia/scripts/check-registry-settings-permissions.sh -- the settings.json
# <-> registry permission conformance check (task 3.4, analysis/
# task-3.4-settings-permissions-design.md). CI-runnable: reads the tracked
# .claude/settings.json only.
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/check-registry-settings-permissions.bats`.
#
# Assertion style note: per .claude/rules/bats-assertions.md, non-final
# absence checks use a positive match for the bad case plus an explicit
# `return 1`, never `!`-negation; equality/numeric/empty checks use POSIX
# `[ ... ]`, which fails correctly on every bash version.
#
# Fixture approach for the RED/carve-out cases: gaia_registry_recognizes
# (called inside the function under test) resolves the registry via
# gaia_registry_path -> gaia_resolve_main_root, which reads the PROCESS CWD,
# never the repo_root argument passed to
# gaia_check_registry_settings_permissions. That argument only ever gates
# where <repo_root>/.claude/settings.json is read from. So a fixture run
# cd's into the REAL repo root (the real registry resolves) while passing a
# temp directory -- containing nothing but its own .claude/settings.json --
# as the repo_root argument. No .gaia symlink is needed; verified empirically
# against this script before writing these tests.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CHECK="$SCRIPT_DIR/check-registry-settings-permissions.sh"
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  # shellcheck source=.gaia/scripts/check-registry-settings-permissions.sh
  source "$CHECK"
}

# run_in_repo <fn> [args...]: runs a sourced-lib function with cwd = the real
# repo root, regardless of where bats itself was invoked from, so
# gaia_registry_path (via state-registry-lib.sh's own $PWD-based resolution)
# locates THIS repo's registry. Mirrors
# check-registry-source-literals.bats's own helper.
run_in_repo() {
  run bash -c '
    cd "$1" || exit 1
    # shellcheck disable=SC1090
    source "$2"
    shift 2
    "$@"
  ' _ "$REPO_ROOT" "$CHECK" "$@"
}

# run_with_fixture_settings <fixture_settings_json>: writes <fixture_settings_json>
# to a fresh temp dir's .claude/settings.json, then runs
# gaia_check_registry_settings_permissions against it with cwd = the real repo
# root (see the file-header note on why this resolves the real registry
# without any .gaia symlink).
run_with_fixture_settings() {
  local fixture_dir="$BATS_TEST_TMPDIR/fixture-$RANDOM"
  mkdir -p "$fixture_dir/.claude"
  printf '%s' "$1" >"$fixture_dir/.claude/settings.json"
  run bash -c '
    cd "$1" || exit 1
    # shellcheck disable=SC1090
    source "$2"
    gaia_check_registry_settings_permissions "$3"
  ' _ "$REPO_ROOT" "$CHECK" "$fixture_dir"
}

# run_with_fixture_settings_norepo <fixture_settings_json>: like
# run_with_fixture_settings, but runs with cwd = a fresh NON-repo temp dir, so
# gaia_registry_path (via gaia_resolve_main_root) cannot resolve a registry.
# Exercises the fail-closed guard.
run_with_fixture_settings_norepo() {
  local fixture_dir="$BATS_TEST_TMPDIR/fixture-norepo-$RANDOM"
  local norepo_dir="$BATS_TEST_TMPDIR/norepo-$RANDOM"
  mkdir -p "$fixture_dir/.claude" "$norepo_dir"
  printf '%s' "$1" >"$fixture_dir/.claude/settings.json"
  run bash -c '
    cd "$1" || exit 1
    # shellcheck disable=SC1090
    source "$2"
    gaia_check_registry_settings_permissions "$3"
  ' _ "$norepo_dir" "$CHECK" "$fixture_dir"
}

@test "structural: check-registry-settings-permissions.sh is executable" {
  [ -x "$CHECK" ]
}

@test "structural: sourcing the script defines the public function with no side effects" {
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    type gaia_check_registry_settings_permissions >/dev/null
    echo OK
  ' _ "$CHECK"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ========== GREEN: the real repo settings.json ==========

@test "real repo: settings.json permissions pass (rc 0, no UNRECOGNIZED lines)" {
  run_in_repo gaia_check_registry_settings_permissions "$REPO_ROOT"
  [ "$status" -eq 0 ]
  grep -qF "UNRECOGNIZED:" <<<"$output" && return 1
  return 0
}

@test "real repo: every current base subtree (cache/handoff/plans/specs/audit) is exercised by a real rule" {
  local allow deny
  allow="$(jq -r '.permissions.allow[]' "$REPO_ROOT/.claude/settings.json")"
  deny="$(jq -r '.permissions.deny[]' "$REPO_ROOT/.claude/settings.json")"
  grep -qF ".gaia/local/cache" <<<"$allow" || return 1
  grep -qF ".gaia/local/handoff" <<<"$allow" || return 1
  grep -qF ".gaia/local/plans" <<<"$allow" || return 1
  grep -qF ".gaia/local/specs" <<<"$allow" || return 1
  grep -qF ".gaia/local/audit" <<<"$deny" || return 1
  return 0
}

# ========== RED: phantom subtree ==========

@test "fixture: a rule naming an unregistered subtree fails and names it" {
  run_with_fixture_settings '{
  "permissions": {
    "allow": ["Bash(rm -rf .gaia/local/frobnicate/*)"],
    "deny": []
  }
}'
  [ "$status" -ne 0 ]
  grep -qF "UNRECOGNIZED: Bash(rm -rf .gaia/local/frobnicate/*) (base frobnicate)" <<<"$output" || return 1
}

# ========== RED: rename drift ==========

@test "fixture: a rule whose base is a plausible-but-unregistered rename fails and names it" {
  run_with_fixture_settings '{
  "permissions": {
    "allow": ["Bash(rm -rf .gaia/local/handoffs/*)"],
    "deny": []
  }
}'
  [ "$status" -ne 0 ]
  grep -qF "UNRECOGNIZED: Bash(rm -rf .gaia/local/handoffs/*) (base handoffs)" <<<"$output" || return 1
}

# ========== carve-out: generic grants and non-.gaia/local paths ==========

@test "fixture: generic grants and non-.gaia/local paths do not trigger a failure" {
  run_with_fixture_settings '{
  "permissions": {
    "allow": [
      "Bash(mkdir -p .gaia/local)",
      "Bash(mkdir -p .gaia/local/*)",
      "Bash(rm -rf .gaia/cache)"
    ],
    "deny": ["Edit(.gaia/**)"]
  }
}'
  [ "$status" -eq 0 ]
  grep -qF "UNRECOGNIZED:" <<<"$output" && return 1
  return 0
}

# ========== fail-closed: unresolvable registry ==========

@test "fixture: fails CLOSED when the registry is unresolvable (no vacuous green)" {
  # The rule WOULD be recognized against the real registry, so a non-zero
  # status here can only be the fail-closed guard -- not phantom detection.
  run_with_fixture_settings_norepo '{
  "permissions": {
    "allow": ["Bash(rm -rf .gaia/local/cache/*)"],
    "deny": []
  }
}'
  [ "$status" -ne 0 ]
  grep -qF "state registry unresolvable" <<<"$output" || return 1
}
