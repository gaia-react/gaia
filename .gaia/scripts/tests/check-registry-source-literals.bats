#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/check-registry-source-literals.sh --
# Check B of the state-registry conformance model (foundations task 2.3,
# design analysis/registry-design.md §4.2, DECISIONS.md D-024). CI-runnable:
# over TRACKED SOURCE only, never the runtime .gaia/local/.
#
# Two directions, two different gating postures (see the script's own header
# comment for the full rationale):
#   - direction 1 (literal -> registry) is REPORT-ONLY today: most call
#     sites still hardcode `.gaia/local/...` paths directly, Phase 3
#     converts them. gaia_check_registry_source_literals always returns 0.
#   - direction 2 (registry -> literal, "no phantom entries") is clean today
#     and is hard-gated here via gaia_check_registry_no_phantom_entries.
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/check-registry-source-literals.bats`.
#
# Assertion style note: per .claude/rules/bats-assertions.md, non-final
# absence checks use a positive match for the bad case plus an explicit
# `return 1`, never `!`-negation; equality/numeric/empty checks use POSIX
# `[ ... ]`, which fails correctly on every bash version.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CHECK="$SCRIPT_DIR/check-registry-source-literals.sh"
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  # shellcheck source=.gaia/scripts/check-registry-source-literals.sh
  source "$CHECK"
}

# run_in_repo <fn> [args...]: runs a sourced-lib function with cwd = the real
# repo root, regardless of where bats itself was invoked from, so
# gaia_registry_path (via state-registry-lib.sh's own $PWD-based resolution)
# locates THIS repo's registry. Mirrors state-registry-lib.bats's own helper.
run_in_repo() {
  run bash -c '
    cd "$1" || exit 1
    # shellcheck disable=SC1090
    source "$2"
    shift 2
    "$@"
  ' _ "$REPO_ROOT" "$CHECK" "$@"
}

@test "structural: check-registry-source-literals.sh is executable" {
  [ -x "$CHECK" ]
}

@test "structural: sourcing the script defines both public functions with no side effects" {
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    type gaia_check_registry_source_literals >/dev/null
    type gaia_check_registry_no_phantom_entries >/dev/null
    echo OK
  ' _ "$CHECK"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ========== direction 2: no phantom entries (hard gate) ==========

@test "real repo: every live registry entry has at least one shipped source reference (no phantom entries)" {
  run_in_repo gaia_check_registry_no_phantom_entries "$REPO_ROOT"
  [ "$status" -eq 0 ]
  grep -qF "PHANTOM:" <<<"$output" && return 1
  return 0
}

@test "fixture: a live entry with no source reference anywhere is flagged PHANTOM" {
  local dir="$BATS_TEST_TMPDIR/phantom-fixture"
  mkdir -p "$dir/.gaia" "$dir/.claude/hooks" "$dir/.claude/commands" "$dir/.claude/skills" "$dir/.claude/agents" \
    "$dir/.gaia/scripts" "$dir/.specify/extensions/gaia/lib" "$dir/.specify/extensions/gaia/commands" \
    "$dir/.gaia/cli/src"
  cat >"$dir/.gaia/state-registry.json" <<'JSON'
{
  "$schema": "./state-registry.schema.json",
  "version": 1,
  "description": "fixture",
  "entries": [
    {
      "id": "nowhere-referenced",
      "path": "nowhere/referenced.json",
      "match": "exact",
      "kind": "file",
      "scope": "main-only",
      "keyed_by": null,
      "why": "fixture entry with deliberately no source reference",
      "writer": "code",
      "reaped_by": null,
      "source": "fixture"
    },
    {
      "id": "not-yet-live-exempt",
      "path": "also/nowhere.json",
      "match": "exact",
      "kind": "file",
      "scope": "main-only",
      "keyed_by": null,
      "why": "fixture not-yet-live entry, exempt from the phantom check by design",
      "writer": "not-yet-live",
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
  printf '#!/usr/bin/env bash\necho hi\n' >"$dir/.claude/hooks/noop.sh"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m init

  # gaia_registry_path (called inside gaia_check_registry_no_phantom_entries)
  # resolves the main root from the process cwd, so the fixture's OWN
  # registry is only in scope when cwd is inside the fixture repo -- run
  # under a subshell cd'd there, mirroring state-registry-lib.bats's own
  # run_in_repo pattern.
  run bash -c '
    cd "$1" || exit 1
    # shellcheck disable=SC1090
    source "$2"
    gaia_check_registry_no_phantom_entries "$1"
  ' _ "$dir" "$CHECK"
  [ "$status" -eq 1 ]
  grep -qF "PHANTOM: nowhere-referenced (nowhere/referenced.json)" <<<"$output" || return 1
  grep -qF "PHANTOM: not-yet-live-exempt" <<<"$output" && return 1
  return 0
}

@test "fixture: a referenced entry (code tier) and a skill-tier-only entry are both NOT phantom" {
  local dir="$BATS_TEST_TMPDIR/covered-fixture"
  mkdir -p "$dir/.gaia" "$dir/.claude/hooks" "$dir/.claude/commands" "$dir/.claude/skills/gaia/references" \
    "$dir/.claude/agents" "$dir/.gaia/scripts" "$dir/.specify/extensions/gaia/lib" \
    "$dir/.specify/extensions/gaia/commands" "$dir/.gaia/cli/src"
  cat >"$dir/.gaia/state-registry.json" <<'JSON'
{
  "$schema": "./state-registry.schema.json",
  "version": 1,
  "description": "fixture",
  "entries": [
    {
      "id": "code-referenced",
      "path": "seen/in-code.json",
      "match": "exact",
      "kind": "file",
      "scope": "main-only",
      "keyed_by": null,
      "why": "referenced from a .sh file",
      "writer": "code",
      "reaped_by": null,
      "source": "fixture"
    },
    {
      "id": "skill-referenced",
      "path": "seen/in-skill.md",
      "match": "exact",
      "kind": "file",
      "scope": "main-only",
      "keyed_by": null,
      "why": "referenced only from a skill markdown body, not any .sh/.ts",
      "writer": "code",
      "reaped_by": null,
      "source": "fixture"
    }
  ],
  "residue": []
}
JSON
  printf '#!/usr/bin/env bash\ntarget=".gaia/local/seen/in-code.json"\necho "$target"\n' >"$dir/.gaia/scripts/writer.sh"
  printf 'Write the report to `.gaia/local/seen/in-skill.md` when done.\n' >"$dir/.claude/skills/gaia/references/example.md"
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
    gaia_check_registry_no_phantom_entries "$1"
  ' _ "$dir" "$CHECK"
  [ "$status" -eq 0 ]
  grep -qF "PHANTOM:" <<<"$output" && return 1
  return 0
}

# ========== direction 1: literal -> registry (report-only) ==========

@test "real repo: gaia_check_registry_source_literals always exits 0 (report-mode, never a CI gate on its own)" {
  run_in_repo gaia_check_registry_source_literals "$REPO_ROOT"
  [ "$status" -eq 0 ]
  grep -qF "direction 1: tracked-source literal -> registry" <<<"$output" || return 1
  grep -qF "direction 2: registry entry -> tracked-source reference" <<<"$output" || return 1
  grep -qF "literal relpaths seen:" <<<"$output" || return 1
}

# ========== normalization unit checks ==========

@test "_gaia_checkb_normalize: braced interpolation collapses to a single wildcard" {
  run _gaia_checkb_normalize 'audit/${m_digest:-<unavailable>}.${m}.ok'
  [ "$status" -eq 0 ]
  [ "$output" = "audit/*.*.ok" ]
}

@test "_gaia_checkb_normalize: printf-style specifiers collapse to a wildcard" {
  run _gaia_checkb_normalize 'cache/spec-session-%s.lock'
  [ "$status" -eq 0 ]
  [ "$output" = "cache/spec-session-*.lock" ]
}

@test "_gaia_checkb_normalize: a trailing sentence period with no separating space is trimmed" {
  run _gaia_checkb_normalize 'cache/gh-artifact-pr.json.'
  [ "$status" -eq 0 ]
  [ "$output" = "cache/gh-artifact-pr.json" ]
}
