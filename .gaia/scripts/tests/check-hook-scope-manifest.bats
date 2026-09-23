#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/check-hook-scope-manifest.sh -- Check D,
# INV-5: every .claude/hooks/**/*.sh reaches .gaia/local only through a
# resolved root.
#
# Two assertions, both in gaia_check_hook_scope_manifest: no hook holds a
# bare .gaia/local literal, and every hook outside .claude/hooks/lib/ that
# holds a live .gaia/local reference names a resolver-backed lib.
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/check-hook-scope-manifest.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CHECK="$SCRIPT_DIR/check-hook-scope-manifest.sh"
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  # shellcheck source=.gaia/scripts/check-hook-scope-manifest.sh
  source "$CHECK"
}

# make_fixture_repo <name>: an empty .claude/hooks tree under BATS_TEST_TMPDIR.
# Returns the repo path on stdout.
make_fixture_repo() {
  local dir="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$dir/.claude/hooks/lib"
  printf '%s' "$dir"
}

# add_hook <repo> <relpath> <body>: writes a hook script at
# .claude/hooks/<relpath> under <repo> with <body> as its content.
add_hook() {
  local repo="$1" rel="$2" body="$3"
  mkdir -p "$(dirname "$repo/.claude/hooks/$rel")"
  printf '%s\n' "$body" >"$repo/.claude/hooks/$rel"
}

# ========== real repo ==========

@test "real repo: check-hook-scope-manifest.sh is executable" {
  [ -x "$CHECK" ]
}

@test "real repo: sourcing the script defines the gate with no side effects" {
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    type gaia_check_hook_scope_manifest >/dev/null
    echo OK
  ' _ "$CHECK"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "real repo: every hook reaches .gaia/local only through a resolved root" {
  run gaia_check_hook_scope_manifest "$REPO_ROOT"
  [ "$status" -eq 0 ]
  local n
  n="$(find "$REPO_ROOT/.claude/hooks" -name '*.sh' | wc -l | tr -d ' ')"
  grep -qF "all $n hooks reach .gaia/local only through a resolved root" <<<"$output" || return 1
}

@test "real repo: run directly with no argument, it resolves the repo and passes" {
  run bash -c 'cd "$1" && bash "$2"' _ "$REPO_ROOT" "$CHECK"
  [ "$status" -eq 0 ]
}

# ========== bare literal ==========

@test "bare literal: a bare .gaia/local literal in a top-level hook fails" {
  local repo; repo="$(make_fixture_repo bare-top)"
  add_hook "$repo" "foo.sh" '#!/usr/bin/env bash
source .gaia/scripts/main-root-lib.sh
ledger=".gaia/local/plans/x.json"
cat "$ledger"'
  run gaia_check_hook_scope_manifest "$repo"
  [ "$status" -eq 1 ]
  grep -qF "BARE LITERAL: .claude/hooks/foo.sh" <<<"$output" || return 1
  grep -qF ".claude/hooks/foo.sh:3" <<<"$output" || return 1
}

@test "bare literal: a bare .gaia/local literal in a lib fails too" {
  local repo; repo="$(make_fixture_repo bare-lib)"
  add_hook "$repo" "lib/foo.sh" '#!/usr/bin/env bash
cat ".gaia/local/audit/sneaky.json"'
  run gaia_check_hook_scope_manifest "$repo"
  [ "$status" -eq 1 ]
  grep -qF "BARE LITERAL: .claude/hooks/lib/foo.sh" <<<"$output" || return 1
}

@test "bare literal: a hook added with no declaration anywhere is still scanned" {
  local repo; repo="$(make_fixture_repo bare-new)"
  add_hook "$repo" "clean.sh" '#!/usr/bin/env bash
exit 0'
  add_hook "$repo" "nested/new-hook.sh" '#!/usr/bin/env bash
: > ".gaia/local/cache/x"'
  run gaia_check_hook_scope_manifest "$repo"
  [ "$status" -eq 1 ]
  grep -qF "BARE LITERAL: .claude/hooks/nested/new-hook.sh" <<<"$output" || return 1
}

@test "bare literal: a comment mentioning .gaia/local does not trip the check" {
  local repo; repo="$(make_fixture_repo bare-comment)"
  add_hook "$repo" "foo.sh" '#!/usr/bin/env bash
# This guard never touches .gaia/local.
exit 0'
  run gaia_check_hook_scope_manifest "$repo"
  [ "$status" -eq 0 ]
}

@test "bare literal: a structural regex over an already-resolved path passes" {
  local repo; repo="$(make_fixture_repo bare-regex)"
  add_hook "$repo" "foo.sh" '#!/usr/bin/env bash
source .gaia/scripts/main-root-lib.sh
name="$(printf "%s" "$1" | sed "s#.*/\.gaia/local/##")"'
  run gaia_check_hook_scope_manifest "$repo"
  [ "$status" -eq 0 ]
}

# ========== resolver-backed ==========

@test "resolver: a resolved-root-joined reference naming main-root-lib.sh passes" {
  local repo; repo="$(make_fixture_repo resolver-clean)"
  add_hook "$repo" "foo.sh" '#!/usr/bin/env bash
source .gaia/scripts/main-root-lib.sh
root="$(gaia_resolve_main_root)"
ledger="$root/.gaia/local/plans/x.json"
cat "$ledger"'
  run gaia_check_hook_scope_manifest "$repo"
  [ "$status" -eq 0 ]
}

@test "resolver: a top-level hook joining a hand-derived root with no resolver lib fails" {
  local repo; repo="$(make_fixture_repo resolver-none)"
  add_hook "$repo" "foo.sh" '#!/usr/bin/env bash
root="$(git rev-parse --show-toplevel)"
ledger="$root/.gaia/local/plans/x.json"
cat "$ledger"'
  run gaia_check_hook_scope_manifest "$repo"
  [ "$status" -eq 1 ]
  grep -qF "NO RESOLVER: .claude/hooks/foo.sh" <<<"$output" || return 1
}

@test "resolver: a hook that inherits its root via a resolver-backed lib, holding no literal of its own, passes" {
  local repo; repo="$(make_fixture_repo resolver-inherits)"
  add_hook "$repo" "foo.sh" '#!/usr/bin/env bash
. .claude/hooks/lib/gaia-active-plan.sh
plan_dir="$(resolve_active_plan_dir)"
echo "$plan_dir"'
  run gaia_check_hook_scope_manifest "$repo"
  [ "$status" -eq 0 ]
}

@test "resolver: a lib taking its root from the caller passes (lib/audit-clearance.sh's own shape)" {
  local repo; repo="$(make_fixture_repo resolver-lib-param)"
  add_hook "$repo" "lib/foo.sh" '#!/usr/bin/env bash
marker_path() {
  local root="$1" digest="$2"
  printf "%s\n" "${root}/.gaia/local/audit/${digest}.ok"
}'
  run gaia_check_hook_scope_manifest "$repo"
  [ "$status" -eq 0 ]
}

# ========== whole gate ==========

@test "gate: one bad hook among clean ones still fails the whole gate" {
  local repo; repo="$(make_fixture_repo gate-onebad)"
  add_hook "$repo" "foo.sh" '#!/usr/bin/env bash
source .gaia/scripts/main-root-lib.sh
root="$(gaia_resolve_main_root)"
cat "$root/.gaia/local/plans/x.json"'
  add_hook "$repo" "bar.sh" '#!/usr/bin/env bash
cat ".gaia/local/audit/sneaky.json"'
  run gaia_check_hook_scope_manifest "$repo"
  [ "$status" -eq 1 ]
  grep -qF "BARE LITERAL: .claude/hooks/bar.sh" <<<"$output" || return 1
  grep -qF "foo.sh" <<<"$output" && return 1
  return 0
}

@test "gate: a tree with no hooks fails rather than passing over nothing" {
  local repo; repo="$(make_fixture_repo gate-empty)"
  run gaia_check_hook_scope_manifest "$repo"
  [ "$status" -eq 1 ]
  grep -qF "no hooks found" <<<"$output" || return 1
}

@test "gate: a root with no .claude/hooks directory fails" {
  run gaia_check_hook_scope_manifest "$BATS_TEST_TMPDIR/nowhere"
  [ "$status" -eq 1 ]
  grep -qF "no .claude/hooks directory" <<<"$output" || return 1
}
