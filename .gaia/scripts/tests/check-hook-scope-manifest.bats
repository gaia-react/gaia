#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/check-hook-scope-manifest.sh -- Check D,
# INV-5's hook tree-scope manifest (task 3.6 design
# analysis/task-3.6-hook-scope-design.md §7).
#
# Four assertions, each with its own function: coverage (every
# .claude/hooks/**/*.sh has exactly one entry), schema (manifest + schema are
# valid JSON, every state token is a known registry id or a well-formed
# path: token), the derive arm (a main-only/shared/per-tree-backed entry's
# hook has no bare .gaia/local literal), and any honesty (a scope: any
# entry's hook has no bare .gaia/local literal either).
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/check-hook-scope-manifest.bats`.
#
# Assertion style note: per .claude/rules/bats-assertions.md, non-final
# absence checks use a positive match for the bad case plus an explicit
# `return 1`, never `!`-negation; equality/numeric/empty checks use POSIX
# `[ ... ]`, which fails correctly on every bash version; substring checks use
# `grep -qF`.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CHECK="$SCRIPT_DIR/check-hook-scope-manifest.sh"
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  # shellcheck source=.gaia/scripts/check-hook-scope-manifest.sh
  source "$CHECK"
  FIXTURE_REPOS=()
}

teardown() {
  local d
  for d in "${FIXTURE_REPOS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  return 0
}

# make_fixture_repo <name>: a fresh git repo under BATS_TEST_TMPDIR with a
# minimal state registry (two entries: one main-only, one per-tree) and no
# hooks yet -- callers add hooks + a manifest with add_hook / write_manifest.
# Returns the repo path on stdout.
make_fixture_repo() {
  local name="$1"
  local dir="$BATS_TEST_TMPDIR/$name"
  mkdir -p "$dir/.claude/hooks/lib" "$dir/.gaia"
  git init -q --initial-branch=main "$dir"
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name T
  git -C "$dir" config commit.gpgsign false

  cat >"$dir/.gaia/state-registry.json" <<'JSON'
{
  "entries": [
    { "id": "plans-main", "scope": "main-only" },
    { "id": "red-ledger", "scope": "per-tree" },
    { "id": "cache-shared", "scope": "shared" },
    { "id": "spec-draft-and-gate1-scratch", "scope": "ephemeral" }
  ]
}
JSON
  FIXTURE_REPOS+=("$dir")
  printf '%s' "$dir"
}

# add_hook <repo> <relpath> <body>: writes a hook script at
# .claude/hooks/<relpath> under <repo> with <body> as its content.
add_hook() {
  local repo="$1" rel="$2" body="$3"
  mkdir -p "$(dirname "$repo/.claude/hooks/$rel")"
  printf '%s\n' "$body" >"$repo/.claude/hooks/$rel"
}

# write_manifest <repo> <hooks_json>: writes .gaia/hook-scopes.json with the
# given raw `hooks` array JSON text (already the full array, including
# brackets), and a placeholder schema file (only its own JSON-validity is
# asserted, never its content against the manifest -- no validator dependency,
# matching this repo's own state-registry-lib.bats convention).
write_manifest() {
  local repo="$1" hooks_json="$2"
  printf '{"$schema":"./hook-scopes.schema.json","hooks":%s}\n' "$hooks_json" \
    >"$repo/.gaia/hook-scopes.json"
  printf '{"$schema":"https://json-schema.org/draft/2020-12/schema"}\n' \
    >"$repo/.gaia/hook-scopes.schema.json"
}

commit_all() {
  local repo="$1"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m fixture
}

# ========== real repo ==========

@test "real repo: check-hook-scope-manifest.sh is executable" {
  [ -x "$CHECK" ]
}

@test "real repo: sourcing the script defines all four functions with no side effects" {
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    type gaia_check_hook_manifest_coverage >/dev/null
    type gaia_check_hook_manifest_schema >/dev/null
    type gaia_check_hook_manifest_derive_arm >/dev/null
    type gaia_check_hook_manifest_any_honesty >/dev/null
    type gaia_check_hook_scope_manifest >/dev/null
    echo OK
  ' _ "$CHECK"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "real repo: the manifest covers every .claude/hooks/**/*.sh with no orphans or duplicates" {
  run gaia_check_hook_manifest_coverage "$REPO_ROOT"
  [ "$status" -eq 0 ]
  local n
  n="$(find "$REPO_ROOT/.claude/hooks" -name '*.sh' | wc -l | tr -d ' ')"
  grep -qF "all $n hooks present, no orphans, no duplicates" <<<"$output" || return 1
}

@test "real repo: the manifest and schema are valid JSON with every state token recognized" {
  run gaia_check_hook_manifest_schema "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "real repo: the derive arm holds for every main-only/shared/per-tree-backed entry" {
  run gaia_check_hook_manifest_derive_arm "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "real repo: any-honesty holds for every scope: any entry" {
  run gaia_check_hook_manifest_any_honesty "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "real repo: the full conformance gate passes" {
  run gaia_check_hook_scope_manifest "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

# ========== assertion 1: coverage ==========

@test "coverage: a hook with no manifest entry fails" {
  local repo; repo="$(make_fixture_repo cov-missing)"
  add_hook "$repo" "foo.sh" "#!/usr/bin/env bash
exit 0"
  write_manifest "$repo" '[]'
  commit_all "$repo"
  run gaia_check_hook_manifest_coverage "$repo"
  [ "$status" -eq 1 ]
  grep -qF "foo.sh" <<<"$output" || return 1
}

@test "coverage: an orphan manifest entry (no such file) fails" {
  local repo; repo="$(make_fixture_repo cov-orphan)"
  write_manifest "$repo" '[{"hook":".claude/hooks/ghost.sh","scope":"any","state":[],"why":"x"}]'
  commit_all "$repo"
  run gaia_check_hook_manifest_coverage "$repo"
  [ "$status" -eq 1 ]
  grep -qF "orphan" <<<"$output" || return 1
  grep -qF "ghost.sh" <<<"$output" || return 1
}

@test "coverage: a duplicate manifest entry fails" {
  local repo; repo="$(make_fixture_repo cov-dup)"
  add_hook "$repo" "foo.sh" "#!/usr/bin/env bash
exit 0"
  write_manifest "$repo" '[
    {"hook":".claude/hooks/foo.sh","scope":"any","state":[],"why":"x"},
    {"hook":".claude/hooks/foo.sh","scope":"any","state":[],"why":"x again"}
  ]'
  commit_all "$repo"
  run gaia_check_hook_manifest_coverage "$repo"
  [ "$status" -eq 1 ]
  grep -qF "duplicate" <<<"$output" || return 1
}

@test "coverage: an invalid scope value fails" {
  local repo; repo="$(make_fixture_repo cov-badscope)"
  add_hook "$repo" "foo.sh" "#!/usr/bin/env bash
exit 0"
  write_manifest "$repo" '[{"hook":".claude/hooks/foo.sh","scope":"sometimes","state":[],"why":"x"}]'
  commit_all "$repo"
  run gaia_check_hook_manifest_coverage "$repo"
  [ "$status" -eq 1 ]
  grep -qF "invalid scope" <<<"$output" || return 1
}

@test "coverage: a complete, one-to-one manifest passes" {
  local repo; repo="$(make_fixture_repo cov-clean)"
  add_hook "$repo" "foo.sh" "#!/usr/bin/env bash
exit 0"
  add_hook "$repo" "lib/bar.sh" "#!/usr/bin/env bash
true"
  write_manifest "$repo" '[
    {"hook":".claude/hooks/foo.sh","scope":"any","state":[],"why":"x"},
    {"hook":".claude/hooks/lib/bar.sh","scope":"any","state":[],"why":"y"}
  ]'
  commit_all "$repo"
  run gaia_check_hook_manifest_coverage "$repo"
  [ "$status" -eq 0 ]
  grep -qF "all 2 hooks present" <<<"$output" || return 1
}

# ========== assertion 2: schema ==========

@test "schema: an unrecognized state token (not a registry id, not a path: token) fails" {
  local repo; repo="$(make_fixture_repo schema-badtoken)"
  add_hook "$repo" "foo.sh" "#!/usr/bin/env bash
exit 0"
  write_manifest "$repo" '[{"hook":".claude/hooks/foo.sh","scope":"main-only","state":["not-a-real-id"],"why":"x"}]'
  commit_all "$repo"
  run gaia_check_hook_manifest_schema "$repo"
  [ "$status" -eq 1 ]
  grep -qF "unrecognized state token" <<<"$output" || return 1
  grep -qF "not-a-real-id" <<<"$output" || return 1
}

@test "schema: a known registry id in state passes" {
  local repo; repo="$(make_fixture_repo schema-goodtoken)"
  add_hook "$repo" "foo.sh" "#!/usr/bin/env bash
exit 0"
  write_manifest "$repo" '[{"hook":".claude/hooks/foo.sh","scope":"main-only","state":["plans-main"],"why":"x"}]'
  commit_all "$repo"
  run gaia_check_hook_manifest_schema "$repo"
  [ "$status" -eq 0 ]
}

@test "schema: a well-formed path: token passes without a registry lookup" {
  local repo; repo="$(make_fixture_repo schema-pathtoken)"
  add_hook "$repo" "foo.sh" "#!/usr/bin/env bash
exit 0"
  write_manifest "$repo" '[{"hook":".claude/hooks/foo.sh","scope":"per-tree","state":["path:.claude/some-marker"],"why":"x"}]'
  commit_all "$repo"
  run gaia_check_hook_manifest_schema "$repo"
  [ "$status" -eq 0 ]
}

@test "schema: a malformed hook path (not under .claude/hooks/, or not .sh) fails" {
  local repo; repo="$(make_fixture_repo schema-badpath)"
  write_manifest "$repo" '[{"hook":"scripts/foo.sh","scope":"any","state":[],"why":"x"}]'
  commit_all "$repo"
  run gaia_check_hook_manifest_schema "$repo"
  [ "$status" -eq 1 ]
  grep -qF "malformed hook path" <<<"$output" || return 1
}

@test "schema: an entry missing a required field fails" {
  local repo; repo="$(make_fixture_repo schema-missingfield)"
  add_hook "$repo" "foo.sh" "#!/usr/bin/env bash
exit 0"
  write_manifest "$repo" '[{"hook":".claude/hooks/foo.sh","scope":"any","state":[]}]'
  commit_all "$repo"
  run gaia_check_hook_manifest_schema "$repo"
  [ "$status" -eq 1 ]
  grep -qF "missing a required field" <<<"$output" || return 1
}

@test "schema: invalid JSON in the manifest fails" {
  local repo; repo="$(make_fixture_repo schema-badjson)"
  printf '{not valid json' >"$repo/.gaia/hook-scopes.json"
  printf '{}' >"$repo/.gaia/hook-scopes.schema.json"
  commit_all "$repo"
  run gaia_check_hook_manifest_schema "$repo"
  [ "$status" -eq 1 ]
  grep -qF "not valid JSON" <<<"$output" || return 1
}

# ========== assertion 3: derive arm ==========

@test "derive arm: a bare .gaia/local literal in a main-only-backed entry fails" {
  local repo; repo="$(make_fixture_repo derive-bare)"
  add_hook "$repo" "foo.sh" '#!/usr/bin/env bash
ledger=".gaia/local/plans/x.json"
cat "$ledger"'
  write_manifest "$repo" '[{"hook":".claude/hooks/foo.sh","scope":"main-only","state":["plans-main"],"why":"x"}]'
  commit_all "$repo"
  run gaia_check_hook_manifest_derive_arm "$repo"
  [ "$status" -eq 1 ]
  grep -qF "bare .gaia/local literal" <<<"$output" || return 1
  grep -qF "foo.sh" <<<"$output" || return 1
}

@test "derive arm: a resolved-root-joined reference naming main-root-lib.sh passes" {
  local repo; repo="$(make_fixture_repo derive-clean)"
  add_hook "$repo" "foo.sh" '#!/usr/bin/env bash
source .gaia/scripts/main-root-lib.sh
root="$(gaia_resolve_main_root)"
ledger="$root/.gaia/local/plans/x.json"
cat "$ledger"'
  write_manifest "$repo" '[{"hook":".claude/hooks/foo.sh","scope":"main-only","state":["plans-main"],"why":"x"}]'
  commit_all "$repo"
  run gaia_check_hook_manifest_derive_arm "$repo"
  [ "$status" -eq 0 ]
}

@test "derive arm: a resolved-root-joined reference naming NO resolver lib fails" {
  local repo; repo="$(make_fixture_repo derive-noresolver)"
  add_hook "$repo" "foo.sh" '#!/usr/bin/env bash
root="$(git rev-parse --show-toplevel)"
ledger="$root/.gaia/local/plans/x.json"
cat "$ledger"'
  write_manifest "$repo" '[{"hook":".claude/hooks/foo.sh","scope":"main-only","state":["plans-main"],"why":"x"}]'
  commit_all "$repo"
  run gaia_check_hook_manifest_derive_arm "$repo"
  [ "$status" -eq 1 ]
  grep -qF "names no resolver-backed lib" <<<"$output" || return 1
}

@test "derive arm: a comment mentioning .gaia/local does not trip the check" {
  local repo; repo="$(make_fixture_repo derive-comment)"
  add_hook "$repo" "foo.sh" '#!/usr/bin/env bash
# See .gaia/local/plans for the plan ledger.
source .gaia/scripts/main-root-lib.sh
root="$(gaia_resolve_main_root)"
ledger="$root/.gaia/local/plans/x.json"
cat "$ledger"'
  write_manifest "$repo" '[{"hook":".claude/hooks/foo.sh","scope":"main-only","state":["plans-main"],"why":"x"}]'
  commit_all "$repo"
  run gaia_check_hook_manifest_derive_arm "$repo"
  [ "$status" -eq 0 ]
}

@test "derive arm: an entry whose state is path:-only (Pattern D) is exempt" {
  local repo; repo="$(make_fixture_repo derive-pathonly)"
  add_hook "$repo" "foo.sh" '#!/usr/bin/env bash
marker=".claude/some-marker"
: > "$marker"'
  write_manifest "$repo" '[{"hook":".claude/hooks/foo.sh","scope":"per-tree","state":["path:.claude/some-marker"],"why":"x"}]'
  commit_all "$repo"
  run gaia_check_hook_manifest_derive_arm "$repo"
  [ "$status" -eq 0 ]
}

@test "derive arm: a hook that inherits its root via a resolver-backed lib name, holding no literal of its own, passes" {
  local repo; repo="$(make_fixture_repo derive-inherits)"
  add_hook "$repo" "foo.sh" '#!/usr/bin/env bash
. .claude/hooks/lib/gaia-active-plan.sh
plan_dir="$(resolve_active_plan_dir)"
echo "$plan_dir"'
  write_manifest "$repo" '[{"hook":".claude/hooks/foo.sh","scope":"main-only","state":["plans-main"],"why":"x"}]'
  commit_all "$repo"
  run gaia_check_hook_manifest_derive_arm "$repo"
  [ "$status" -eq 0 ]
}

@test "derive arm: an ephemeral-scoped registry id in state does not qualify the entry" {
  local repo; repo="$(make_fixture_repo derive-ephemeral)"
  add_hook "$repo" "foo.sh" '#!/usr/bin/env bash
draft=".gaia/local/cache/draft-x.md"
cat "$draft"'
  write_manifest "$repo" '[{"hook":".claude/hooks/foo.sh","scope":"any","state":["spec-draft-and-gate1-scratch"],"why":"x"}]'
  commit_all "$repo"
  run gaia_check_hook_manifest_derive_arm "$repo"
  [ "$status" -eq 0 ]
}

# ========== assertion 4: any honesty ==========

@test "any honesty: a bare .gaia/local literal in a scope: any entry fails" {
  local repo; repo="$(make_fixture_repo any-bare)"
  add_hook "$repo" "foo.sh" '#!/usr/bin/env bash
cat ".gaia/local/audit/sneaky.json"'
  write_manifest "$repo" '[{"hook":".claude/hooks/foo.sh","scope":"any","state":[],"why":"x"}]'
  commit_all "$repo"
  run gaia_check_hook_manifest_any_honesty "$repo"
  [ "$status" -eq 1 ]
  grep -qF "bare .gaia/local literal" <<<"$output" || return 1
}

@test "any honesty: a caller-supplied root parameter reference passes (lib/audit-clearance.sh's own shape)" {
  local repo; repo="$(make_fixture_repo any-param)"
  add_hook "$repo" "foo.sh" '#!/usr/bin/env bash
marker_path() {
  local root="$1" digest="$2"
  printf "%s\n" "${root}/.gaia/local/audit/${digest}.ok"
}'
  write_manifest "$repo" '[{"hook":".claude/hooks/foo.sh","scope":"any","state":[],"why":"x"}]'
  commit_all "$repo"
  run gaia_check_hook_manifest_any_honesty "$repo"
  [ "$status" -eq 0 ]
}

@test "any honesty: a plain stateless guard with no .gaia/local mention at all passes" {
  local repo; repo="$(make_fixture_repo any-clean)"
  add_hook "$repo" "foo.sh" '#!/usr/bin/env bash
exit 0'
  write_manifest "$repo" '[{"hook":".claude/hooks/foo.sh","scope":"any","state":[],"why":"x"}]'
  commit_all "$repo"
  run gaia_check_hook_manifest_any_honesty "$repo"
  [ "$status" -eq 0 ]
}

@test "any honesty: a comment mentioning .gaia/local does not trip the check" {
  local repo; repo="$(make_fixture_repo any-comment)"
  add_hook "$repo" "foo.sh" '#!/usr/bin/env bash
# This guard never touches .gaia/local.
exit 0'
  write_manifest "$repo" '[{"hook":".claude/hooks/foo.sh","scope":"any","state":[],"why":"x"}]'
  commit_all "$repo"
  run gaia_check_hook_manifest_any_honesty "$repo"
  [ "$status" -eq 0 ]
}

# ========== full gate ==========

@test "full gate: a clean fixture passes every assertion" {
  local repo; repo="$(make_fixture_repo full-clean)"
  add_hook "$repo" "foo.sh" '#!/usr/bin/env bash
source .gaia/scripts/main-root-lib.sh
root="$(gaia_resolve_main_root)"
ledger="$root/.gaia/local/plans/x.json"
cat "$ledger"'
  add_hook "$repo" "bar.sh" '#!/usr/bin/env bash
exit 0'
  write_manifest "$repo" '[
    {"hook":".claude/hooks/foo.sh","scope":"main-only","state":["plans-main"],"why":"x"},
    {"hook":".claude/hooks/bar.sh","scope":"any","state":[],"why":"y"}
  ]'
  commit_all "$repo"
  run gaia_check_hook_scope_manifest "$repo"
  [ "$status" -eq 0 ]
}

@test "full gate: a single bad entry among many still fails the whole gate" {
  local repo; repo="$(make_fixture_repo full-onebad)"
  add_hook "$repo" "foo.sh" '#!/usr/bin/env bash
source .gaia/scripts/main-root-lib.sh
root="$(gaia_resolve_main_root)"
ledger="$root/.gaia/local/plans/x.json"
cat "$ledger"'
  add_hook "$repo" "bar.sh" '#!/usr/bin/env bash
cat ".gaia/local/audit/sneaky.json"'
  write_manifest "$repo" '[
    {"hook":".claude/hooks/foo.sh","scope":"main-only","state":["plans-main"],"why":"x"},
    {"hook":".claude/hooks/bar.sh","scope":"any","state":[],"why":"y"}
  ]'
  commit_all "$repo"
  run gaia_check_hook_scope_manifest "$repo"
  [ "$status" -eq 1 ]
}
