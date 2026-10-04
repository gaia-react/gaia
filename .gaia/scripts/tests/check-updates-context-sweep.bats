#!/usr/bin/env bats
#
# SPEC-093 housekeeping: the context-reading sweep in check-updates.sh and the
# state-registry rows for the two new .gaia/local paths.
#
# Run via: bash .gaia/scripts/bats5.sh .gaia/scripts/tests/check-updates-context-sweep.bats < /dev/null
#
# The TTL test seam is the `checkedAt` field of cache/shared/update-check.json:
# a missing or old value is "past the TTL", a value of now is "not past".
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPTS_DIRECTORY="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  REAL_REGISTRY="$(cd "$SCRIPTS_DIRECTORY/.." && pwd)/state-registry.json"
  command -v jq >/dev/null 2>&1 || skip "jq required"
  command -v git >/dev/null 2>&1 || skip "git required"
}

# make_main [script-override]: a committed main checkout holding the refresher
# (or the given scratch copy of it) and the resolver. Sets MAIN and CONTEXT_DIRECTORY.
make_main() {
  local script_source="${1:-$SCRIPTS_DIRECTORY/check-updates.sh}"
  MAIN="$(mktemp -d "$BATS_TEST_TMPDIR/main.XXXXXX")"
  MAIN="$(cd "$MAIN" && pwd -P)"
  mkdir -p "$MAIN/.gaia/scripts" "$MAIN/.gaia/local" "$MAIN/bin"
  cp "$script_source" "$MAIN/.gaia/scripts/check-updates.sh"
  cp "$SCRIPTS_DIRECTORY/main-root-lib.sh" "$MAIN/.gaia/scripts/main-root-lib.sh"
  printf '1.0.0\n' > "$MAIN/.gaia/VERSION"
  git -C "$MAIN" init -q
  git -C "$MAIN" config user.email t@t.t
  git -C "$MAIN" config user.name t
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -qm fixture
  CONTEXT_DIRECTORY="$MAIN/.gaia/local/cache/shared/context"
  mkdir -p "$CONTEXT_DIRECTORY"
}

# seed_context: the UAT-020 fixture. 8 days is past the 7-day sweep, 1 is not.
seed_context() {
  printf '{}' > "$CONTEXT_DIRECTORY/old.json"
  printf '{}' > "$CONTEXT_DIRECTORY/new.json"
  printf '{}' > "$CONTEXT_DIRECTORY/old.json.tmp.123"
  printf 'x' > "$CONTEXT_DIRECTORY/notes.txt"
  printf '{}' > "$BATS_TEST_TMPDIR/elsewhere"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$CONTEXT_DIRECTORY/link.json"
  touch -t "$(days_ago 8)" "$CONTEXT_DIRECTORY/old.json" "$CONTEXT_DIRECTORY/old.json.tmp.123" "$CONTEXT_DIRECTORY/notes.txt"
  touch -h -t "$(days_ago 8)" "$CONTEXT_DIRECTORY/link.json"
  touch -t "$(days_ago 1)" "$CONTEXT_DIRECTORY/new.json"
}

# days_ago <n>: touch -t stamp, BSD and GNU safe via epoch arithmetic.
days_ago() {
  local epoch=$(( $(date +%s) - $1 * 86400 ))
  date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$epoch" +%Y%m%d%H%M.%S
}

run_refresher() {
  PATH="$MAIN/bin:$PATH" run bash "$MAIN/.gaia/scripts/check-updates.sh" < /dev/null
}

@test "sweep: past the TTL, only stale regular *.json and *.json.tmp.* files are removed" {
  make_main
  seed_context
  run_refresher
  [ "$status" -eq 0 ]
  [ ! -e "$CONTEXT_DIRECTORY/old.json" ]
  [ ! -e "$CONTEXT_DIRECTORY/old.json.tmp.123" ]
  [ -e "$CONTEXT_DIRECTORY/new.json" ]
  [ -e "$CONTEXT_DIRECTORY/notes.txt" ]
  [ -L "$CONTEXT_DIRECTORY/link.json" ]
}

@test "sweep red state: with the TTL not past, the 8-day-old file survives" {
  make_main
  seed_context
  printf '{"checkedAt":%s,"securitySource":"dependabot"}\n' "$(date +%s)" > "$MAIN/.gaia/local/cache/shared/update-check.json"
  run_refresher
  [ "$status" -eq 0 ]
  [ -e "$CONTEXT_DIRECTORY/old.json" ]
  [ -e "$CONTEXT_DIRECTORY/old.json.tmp.123" ]
}

@test "sweep red state: a scratch copy without the age test deletes the 1-day file" {
  local scratch="$BATS_TEST_TMPDIR/check-updates-noage.sh"
  sed 's/ -mtime +"\$CONTEXT_SWEEP_DAYS"//' "$SCRIPTS_DIRECTORY/check-updates.sh" > "$scratch"
  # The mutation must have landed, or this test proves nothing.
  if cmp -s "$scratch" "$SCRIPTS_DIRECTORY/check-updates.sh"; then
    printf 'age test not found in check-updates.sh; mutation did not apply\n' >&2
    return 1
  fi
  make_main "$scratch"
  seed_context
  run_refresher
  [ "$status" -eq 0 ]
  [ ! -e "$CONTEXT_DIRECTORY/new.json" ]
  [ -e "$CONTEXT_DIRECTORY/notes.txt" ]
  [ -L "$CONTEXT_DIRECTORY/link.json" ]
}

# ---------- registry rows ----------

# make_registry_repo: a fixture repo whose main-root registry is a scratch copy
# of the real one, with the lib beside it. Sets REGISTRY_REPO and REGISTRY_FILE.
make_registry_repo() {
  REGISTRY_REPO="$(mktemp -d "$BATS_TEST_TMPDIR/reg.XXXXXX")"
  REGISTRY_REPO="$(cd "$REGISTRY_REPO" && pwd -P)"
  mkdir -p "$REGISTRY_REPO/.gaia/scripts"
  cp "$SCRIPTS_DIRECTORY/state-registry-lib.sh" "$SCRIPTS_DIRECTORY/main-root-lib.sh" "$REGISTRY_REPO/.gaia/scripts/"
  cp "$REAL_REGISTRY" "$REGISTRY_REPO/.gaia/state-registry.json"
  REGISTRY_FILE="$REGISTRY_REPO/.gaia/state-registry.json"
  git -C "$REGISTRY_REPO" init -q
}

classify() {
  run bash -c 'cd "$1" && bash .gaia/scripts/state-registry-lib.sh classify "$2"' _ "$REGISTRY_REPO" "$1"
}

@test "registry: context-readings precedes cache-shared and carries a reaper" {
  run jq -e '
    ([.entries[].id] | index("context-readings")) < ([.entries[].id] | index("cache-shared"))
    and (.entries[] | select(.id == "context-readings") | .reaped_by | startswith("check-updates.sh"))
  ' "$REAL_REGISTRY"
  [ "$status" -eq 0 ]
}

@test "registry: a context file classifies via the context-readings row, not cache-shared" {
  make_registry_repo
  # Give the new row a scope no other row has, so reaching it is observable.
  jq '(.entries[] | select(.id == "context-readings") | .scope) = "per-tree"' "$REGISTRY_FILE" > "$REGISTRY_FILE.new"
  mv "$REGISTRY_FILE.new" "$REGISTRY_FILE"
  classify "cache/shared/context/abc.json"
  [ "$status" -eq 0 ]
  [ "$output" = "per-tree" ]
  classify "cache/shared/update-check.json"
  [ "$output" = "shared" ]
}

@test "registry: the real registry classifies a context file and the update cache as shared" {
  make_registry_repo
  classify "cache/shared/context/abc.json"
  [ "$output" = "shared" ]
  classify "cache/shared/update-check.json"
  [ "$output" = "shared" ]
}

@test "registry: settings.json maps to local-settings exactly, settings.json.bak does not" {
  make_registry_repo
  classify "settings.json"
  [ "$output" = "shared" ]
  classify "settings.json.bak"
  [ "$output" = "unknown" ]
}

@test "registry red twin: without the local-settings row settings.json classifies unknown" {
  make_registry_repo
  jq '.entries |= map(select(.id != "local-settings"))' "$REGISTRY_FILE" > "$REGISTRY_FILE.new"
  mv "$REGISTRY_FILE.new" "$REGISTRY_FILE"
  classify "settings.json"
  [ "$output" = "unknown" ]
}

@test "registry: protected/checkpoint-override.json maps to checkpoint-override exactly, its .bak sibling does not" {
  make_registry_repo
  run jq -r '.entries[] | select(.path == "protected/checkpoint-override.json") | .id' "$REAL_REGISTRY"
  [ "$output" = "checkpoint-override" ]
  classify "protected/checkpoint-override.json"
  [ "$output" = "shared" ]
  classify "protected/checkpoint-override.json.bak"
  [ "$output" = "unknown" ]
}

@test "registry red twin: without the checkpoint-override row protected/checkpoint-override.json classifies unknown" {
  make_registry_repo
  jq '.entries |= map(select(.id != "checkpoint-override"))' "$REGISTRY_FILE" > "$REGISTRY_FILE.new"
  mv "$REGISTRY_FILE.new" "$REGISTRY_FILE"
  classify "protected/checkpoint-override.json"
  [ "$output" = "unknown" ]
}

@test "registry red twin: without the audit-loop-state row a protected/audit-loop state file classifies unknown" {
  make_registry_repo
  classify "protected/audit-loop/feat/x.json"
  [ "$output" = "main-only" ]
  jq '.entries |= map(select(.id != "audit-loop-state"))' "$REGISTRY_FILE" > "$REGISTRY_FILE.new"
  mv "$REGISTRY_FILE.new" "$REGISTRY_FILE"
  classify "protected/audit-loop/feat/x.json"
  [ "$output" = "unknown" ]
}
