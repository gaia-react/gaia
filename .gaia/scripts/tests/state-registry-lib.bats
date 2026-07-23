#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/state-registry-lib.sh, the state-registry
# reader (foundations task 2.3). Two kinds of test live here: functional tests
# of the reader lib's public API against the real, tracked
# .gaia/state-registry.json (this repo's own registry IS the fixture -- it is
# tracked machinery, not per-run test data), and structural/schema tests that
# assert the registry's own invariants directly with jq (no JSON Schema
# validator is a repo dependency, so schema conformance is checked by hand
# against the same invariants .gaia/state-registry.schema.json encodes).
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/state-registry-lib.bats`.
#
# Assertion style note: per .claude/rules/bats-assertions.md, non-final
# absence checks use a positive match for the bad case plus an explicit
# `return 1`, never `!`-negation; equality/numeric/empty checks use POSIX
# `[ ... ]`, which fails correctly on every bash version; substring checks use
# `grep -qF`.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  LIB="$SCRIPT_DIR/state-registry-lib.sh"
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  REGISTRY="$REPO_ROOT/.gaia/state-registry.json"
  SCHEMA="$REPO_ROOT/.gaia/state-registry.schema.json"
  # shellcheck source=.gaia/scripts/state-registry-lib.sh
  source "$LIB"
}

# run_in_repo <fn> [args...]: runs a sourced-lib function with cwd = the real
# repo root, regardless of where bats itself was invoked from, so
# gaia_resolve_main_root (via main-root-lib.sh) resolves against this repo's
# own git layout.
run_in_repo() {
  run bash -c '
    cd "$1" || exit 1
    # shellcheck disable=SC1090
    source "$2"
    shift 2
    "$@"
  ' _ "$REPO_ROOT" "$LIB" "$@"
}

# ========== structural ==========

@test "structural: state-registry-lib.sh is executable" {
  [ -x "$LIB" ]
}

@test "structural: sourcing the library defines all four public functions with no side effects" {
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    type gaia_registry_path >/dev/null
    type gaia_registry_linkable_paths >/dev/null
    type gaia_registry_recognizes >/dev/null
    type gaia_registry_classify >/dev/null
    echo OK
  ' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "structural: the registry and schema are valid JSON" {
  jq empty "$REGISTRY"
  jq empty "$SCHEMA"
}

# ========== gaia_registry_path ==========

@test "gaia_registry_path: resolves to <repo-root>/.gaia/state-registry.json" {
  run_in_repo gaia_registry_path
  [ "$status" -eq 0 ]
  [ "$output" = "$REGISTRY" ]
}

@test "gaia_registry_path: worktree-safe, resolves the MAIN checkout's registry from inside a linked worktree" {
  # Canonicalized via mktemp/pwd -P: macOS resolves /var -> /private/var inside
  # the resolver's own physical resolution, and the resolver's output is
  # compared byte-for-byte below, so a non-canonical tmp path would desync for
  # reasons that have nothing to do with the function under test (mirrors
  # main-root-lib.bats's own fixture-root note).
  mkdir -p "$BATS_TEST_TMPDIR/wtmain"
  main="$(cd "$BATS_TEST_TMPDIR/wtmain" && pwd -P)"
  mkdir -p "$main/.gaia"
  git init -q --initial-branch=main "$main"
  git -C "$main" config user.email t@example.com
  git -C "$main" config user.name "T"
  git -C "$main" config commit.gpgsign false
  echo '{"$schema":"./state-registry.schema.json","version":1,"description":"fixture","entries":[],"residue":[]}' \
    >"$main/.gaia/state-registry.json"
  git -C "$main" add -A
  git -C "$main" commit -q -m init
  git -C "$main" branch wt
  git -C "$main" worktree add -q "$main-wt" wt

  run bash -c '
    cd "$1" || exit 1
    # shellcheck disable=SC1090
    source "$2"
    gaia_registry_path
  ' _ "$main-wt" "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "$main/.gaia/state-registry.json" ]
}

@test "gaia_registry_path: no jq on PATH fails with one stderr diagnostic, nothing on stdout" {
  # bats' `run` merges stdout and stderr into one $output (see
  # main-root-lib.bats's own note on this), so stdout and stderr are captured
  # separately here rather than through `run`.
  errfile="$BATS_TEST_TMPDIR/gaia_registry_path.stderr"
  saved_path="$PATH"
  # shellcheck disable=SC2123 # deliberately blank PATH to make jq unfindable; restored right after the call
  PATH=""
  # gaia_registry_path is expected to fail here; set +e/-e brackets the call so
  # that expected failure doesn't trip the @test body's own `set -e` before
  # status_val can be captured (a plain, non-`local` assignment's exit status
  # IS the command substitution's, unlike the `local x=$(...)` masking case).
  set +e
  stdout_val="$(gaia_registry_path 2>"$errfile")"
  status_val=$?
  set -e
  PATH="$saved_path"
  [ "$status_val" -eq 1 ]
  [ -z "$stdout_val" ]
  [ -s "$errfile" ]
  [ "$(wc -l <"$errfile" | tr -d ' ')" -eq 1 ]
}

# ========== gaia_registry_linkable_paths ==========

@test "gaia_registry_linkable_paths: prints exactly the 5 linkable paths in stable order" {
  run_in_repo gaia_registry_linkable_paths
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 5 ]
  [ "${lines[0]}" = "setup-state.json" ]
  [ "${lines[1]}" = "cache/shared" ]
  [ "${lines[2]}" = "audit" ]
  [ "${lines[3]}" = "telemetry" ]
  [ "${lines[4]}" = "debt" ]
}

# ========== gaia_registry_recognizes ==========

@test "gaia_registry_recognizes: a known per-tree directory (red-ledger, type d) is recognized" {
  run_in_repo gaia_registry_recognizes "red-ledger" d
  [ "$status" -eq 0 ]
}

@test "gaia_registry_recognizes: a known residue file (mentorship.json, type f) is recognized" {
  run_in_repo gaia_registry_recognizes "mentorship.json" f
  [ "$status" -eq 0 ]
}

@test "gaia_registry_recognizes: a known shared glob family (audit clearance marker, type f) is recognized" {
  run_in_repo gaia_registry_recognizes "audit/abc123.ok" f
  [ "$status" -eq 0 ]
}

@test "gaia_registry_recognizes: a made-up unknown child is NOT recognized" {
  run_in_repo gaia_registry_recognizes "totally-made-up-thing.xyz" f
  [ "$status" -eq 1 ]
}

@test "gaia_registry_recognizes: jq unavailable fails SAFE (recognized, exit 0) rather than reaping the unknown" {
  saved_path="$PATH"
  # shellcheck disable=SC2123 # deliberately blank PATH to make jq unfindable; restored right after the call
  PATH=""
  run gaia_registry_recognizes "totally-made-up-thing.xyz" f
  PATH="$saved_path"
  [ "$status" -eq 0 ]
}

@test "gaia_registry_recognizes: a bare container dir that holds classified children (audit) is recognized as their ancestor" {
  run_in_repo gaia_registry_recognizes "audit" d
  [ "$status" -eq 0 ]
}

@test "gaia_registry_recognizes: a nested container dir (audit/security) is recognized as an ancestor" {
  run_in_repo gaia_registry_recognizes "audit/security" d
  [ "$status" -eq 0 ]
}

@test "gaia_registry_recognizes: a made-up dir that is NOT an ancestor of any entry is unknown" {
  run_in_repo gaia_registry_recognizes "cache/adopter-owned-thing" d
  [ "$status" -eq 1 ]
}

@test "gaia_registry_recognizes: ancestor recognition is for directories only, a same-named FILE is not a container" {
  # A file cannot hold entries; `audit` as a type-f arg must not borrow the
  # directory's ancestor recognition.
  run_in_repo gaia_registry_recognizes "audit" f
  [ "$status" -eq 1 ]
}

# ========== gaia_registry_classify ==========

@test "gaia_registry_classify: red-ledger classifies as per-tree" {
  run_in_repo gaia_registry_classify "red-ledger"
  [ "$status" -eq 0 ]
  [ "$output" = "per-tree" ]
}

@test "gaia_registry_classify: mentorship.json classifies as residue" {
  run_in_repo gaia_registry_classify "mentorship.json"
  [ "$status" -eq 0 ]
  [ "$output" = "residue" ]
}

@test "gaia_registry_classify: an unknown child classifies as unknown" {
  run_in_repo gaia_registry_classify "totally-made-up-thing.xyz"
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

@test "gaia_registry_classify: a residue leaf nested under a live shared prefix wins over the containing prefix" {
  run_in_repo gaia_registry_classify "cache/shared/coaching-active.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "residue" ]
}

@test "gaia_registry_classify: jq unavailable prints nothing and returns 1 (not a reap gate, no fail-open contract)" {
  saved_path="$PATH"
  # shellcheck disable=SC2123 # deliberately blank PATH to make jq unfindable; restored right after the call
  PATH=""
  run gaia_registry_classify "red-ledger"
  PATH="$saved_path"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ========== denominator spot-check (design success check 3, mechanized) ==========
# One representative relpath per family from the top-level / audit/ / cache/
# inventory tables; every one must classify, never "unknown".

@test "denominator spot-check: a representative sample from every family classifies (none unknown)" {
  local -a cases=(
    "setup-state.json:shared"
    "cache/shared/update-check.json:shared"
    "audit/abc123.ok:shared"
    "audit/abc123.def456.findings.json:shared"
    "audit/abc123.progress.log:shared"
    "audit/security/deadbeef.md:shared"
    "telemetry/cost.jsonl:shared"
    "debt/count.json:shared"
    "debt/refresh-requested:shared"
    "red-ledger/observations.jsonl:per-tree"
    "audit/worthiness.jsonl:per-tree"
    "forensics/2026-07-23-x.md:per-tree"
    "handoff/HANDOFF-2026-07-23-x.md:per-tree"
    "harden/declines.json:per-tree"
    "specs/ledger.json:main-only"
    "plans/ledger.json:main-only"
    "cache/gh-artifact-pr.json:main-only"
    "cache/spec-chain-abc123.json:main-only"
    "worktree-locks/my-worktree:main-only"
    ".project-id:main-only"
    "declined-updates.json:main-only"
    ".patched-statusline.sh:main-only"
    "dep-audit-baseline.json:main-only"
    "automation.json:main-only"
    "sandbox.json:main-only"
    "setup-in-progress:main-only"
    "cache/v2-update-notes.md:main-only"
    "cache/draft-SPEC-042.md:ephemeral"
    "cache/gate1-SPEC-042.json:ephemeral"
    "cache/spec-session-SPEC-042.json:ephemeral"
    "cache/audit-SPEC-042:ephemeral"
    "cache/audit-window-SPEC-042.json:ephemeral"
    "cache/wiki-promote/SPEC-042.json:ephemeral"
    "cache/uat-write/SPEC-042.json:ephemeral"
    "cache/some-run/renders.json:ephemeral"
    "cache/version-check.lock:ephemeral"
    "audit/KNOWLEDGE-2026-07-23.md:ephemeral"
    "audit/issue-body-abc.md:ephemeral"
    "audit/comprehensive/gauge.json:ephemeral"
    "audit/archived/2026-07-23:ephemeral"
    "mentorship.json:residue"
    "telemetry/cloud/x.json:residue"
    "telemetry/analytics/x.json:residue"
    "cache/shared/coaching-active.txt:residue"
    "audit/abc123.carried:residue"
    ".mentorship-swept:residue"
    "plans/archived/PLAN-001:residue"
    "specs/archived/SPEC-001:residue"
  )
  local case_line relpath expected got
  for case_line in "${cases[@]}"; do
    relpath="${case_line%%:*}"
    expected="${case_line##*:}"
    run_in_repo gaia_registry_classify "$relpath"
    got="$output"
    if [ "$got" = "unknown" ]; then
      echo "NOT COVERED: $relpath (expected $expected)"
      return 1
    fi
    if [ "$got" != "$expected" ]; then
      echo "WRONG SCOPE: $relpath got '$got' expected '$expected'"
      return 1
    fi
  done
}

# ========== schema-shaped structural invariants (no validator dependency; direct jq) ==========

@test "schema invariant: every scope==shared entry has a non-empty string keyed_by" {
  run jq -e '[.entries[] | select(.scope == "shared") | (.keyed_by | type == "string" and length > 0)] | all' "$REGISTRY"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "schema invariant: every non-shared entry has keyed_by == null" {
  run jq -e '[.entries[] | select(.scope != "shared") | (.keyed_by == null)] | all' "$REGISTRY"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "schema invariant: match/kind/scope/writer enums are all within the allowed set" {
  run jq -e '
    ([.entries[].match] | all(. as $m | ["exact","glob","prefix"] | index($m) != null))
    and ([.entries[].kind] | all(. as $k | ["file","dir"] | index($k) != null))
    and ([.entries[].scope] | all(. as $s | ["shared","per-tree","main-only","ephemeral"] | index($s) != null))
    and ([.entries[].writer] | all(. as $w | ["code","hand-authored","not-yet-live"] | index($w) != null))
    and ([.residue[].match] | all(. as $m | ["exact","glob","prefix"] | index($m) != null))
    and ([.residue[].writer] | all(. == "none-residue"))
  ' "$REGISTRY"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "schema invariant: no duplicate ids across entries and residue" {
  run jq -e '
    ([(.entries[].id), (.residue[].id)]) as $all
    | ($all | length) == ($all | unique | length)
  ' "$REGISTRY"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "schema invariant: every entry and residue row carries all required fields" {
  run jq -e '
    (.entries | all(has("id") and has("path") and has("match") and has("kind") and has("scope") and has("keyed_by") and has("why") and has("writer") and has("reaped_by") and has("source")))
    and (.residue | all(has("id") and has("path") and has("match") and has("why") and has("writer")))
  ' "$REGISTRY"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}
