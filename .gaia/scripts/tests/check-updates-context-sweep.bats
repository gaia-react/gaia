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
  SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  REAL_REGISTRY="$(cd "$SCRIPTS_DIR/.." && pwd)/state-registry.json"
  command -v jq >/dev/null 2>&1 || skip "jq required"
  command -v git >/dev/null 2>&1 || skip "git required"
}

# make_main [script-override]: a committed main checkout holding the refresher
# (or the given scratch copy of it) and the resolver. Sets MAIN and CTX.
make_main() {
  local script_src="${1:-$SCRIPTS_DIR/check-updates.sh}"
  MAIN="$(mktemp -d "$BATS_TEST_TMPDIR/main.XXXXXX")"
  MAIN="$(cd "$MAIN" && pwd -P)"
  mkdir -p "$MAIN/.gaia/scripts" "$MAIN/.gaia/local" "$MAIN/bin"
  cp "$script_src" "$MAIN/.gaia/scripts/check-updates.sh"
  cp "$SCRIPTS_DIR/main-root-lib.sh" "$MAIN/.gaia/scripts/main-root-lib.sh"
  printf '1.0.0\n' > "$MAIN/.gaia/VERSION"
  git -C "$MAIN" init -q
  git -C "$MAIN" config user.email t@t.t
  git -C "$MAIN" config user.name t
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -qm fixture
  CTX="$MAIN/.gaia/local/cache/shared/context"
  mkdir -p "$CTX"
}

# seed_context: the UAT-020 fixture. 8 days is past the 7-day sweep, 1 is not.
seed_context() {
  printf '{}' > "$CTX/old.json"
  printf '{}' > "$CTX/new.json"
  printf '{}' > "$CTX/old.json.tmp.123"
  printf 'x' > "$CTX/notes.txt"
  printf '{}' > "$BATS_TEST_TMPDIR/elsewhere"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$CTX/link.json"
  touch -t "$(days_ago 8)" "$CTX/old.json" "$CTX/old.json.tmp.123" "$CTX/notes.txt"
  touch -h -t "$(days_ago 8)" "$CTX/link.json"
  touch -t "$(days_ago 1)" "$CTX/new.json"
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
  [ ! -e "$CTX/old.json" ]
  [ ! -e "$CTX/old.json.tmp.123" ]
  [ -e "$CTX/new.json" ]
  [ -e "$CTX/notes.txt" ]
  [ -L "$CTX/link.json" ]
}

@test "sweep red state: with the TTL not past, the 8-day-old file survives" {
  make_main
  seed_context
  printf '{"checkedAt":%s}\n' "$(date +%s)" > "$MAIN/.gaia/local/cache/shared/update-check.json"
  run_refresher
  [ "$status" -eq 0 ]
  [ -e "$CTX/old.json" ]
  [ -e "$CTX/old.json.tmp.123" ]
}

@test "sweep red state: a scratch copy without the age test deletes the 1-day file" {
  local scratch="$BATS_TEST_TMPDIR/check-updates-noage.sh"
  sed 's/ -mtime +"\$CONTEXT_SWEEP_DAYS"//' "$SCRIPTS_DIR/check-updates.sh" > "$scratch"
  # The mutation must have landed, or this test proves nothing.
  if cmp -s "$scratch" "$SCRIPTS_DIR/check-updates.sh"; then
    printf 'age test not found in check-updates.sh; mutation did not apply\n' >&2
    return 1
  fi
  make_main "$scratch"
  seed_context
  run_refresher
  [ "$status" -eq 0 ]
  [ ! -e "$CTX/new.json" ]
  [ -e "$CTX/notes.txt" ]
  [ -L "$CTX/link.json" ]
}

# ---------- registry rows ----------

# make_registry_repo: a fixture repo whose main-root registry is a scratch copy
# of the real one, with the lib beside it. Sets REG_REPO and REG.
make_registry_repo() {
  REG_REPO="$(mktemp -d "$BATS_TEST_TMPDIR/reg.XXXXXX")"
  REG_REPO="$(cd "$REG_REPO" && pwd -P)"
  mkdir -p "$REG_REPO/.gaia/scripts"
  cp "$SCRIPTS_DIR/state-registry-lib.sh" "$SCRIPTS_DIR/main-root-lib.sh" "$REG_REPO/.gaia/scripts/"
  cp "$REAL_REGISTRY" "$REG_REPO/.gaia/state-registry.json"
  REG="$REG_REPO/.gaia/state-registry.json"
  git -C "$REG_REPO" init -q
}

classify() {
  run bash -c 'cd "$1" && bash .gaia/scripts/state-registry-lib.sh classify "$2"' _ "$REG_REPO" "$1"
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
  jq '(.entries[] | select(.id == "context-readings") | .scope) = "per-tree"' "$REG" > "$REG.new"
  mv "$REG.new" "$REG"
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
  jq '.entries |= map(select(.id != "local-settings"))' "$REG" > "$REG.new"
  mv "$REG.new" "$REG"
  classify "settings.json"
  [ "$output" = "unknown" ]
}

@test "registry: checkpoint-override.json maps to checkpoint-override exactly, its .bak sibling does not" {
  make_registry_repo
  run jq -r '.entries[] | select(.path == "checkpoint-override.json") | .id' "$REAL_REGISTRY"
  [ "$output" = "checkpoint-override" ]
  classify "checkpoint-override.json"
  [ "$output" = "shared" ]
  classify "checkpoint-override.json.bak"
  [ "$output" = "unknown" ]
}

@test "registry red twin: without the checkpoint-override row checkpoint-override.json classifies unknown" {
  make_registry_repo
  jq '.entries |= map(select(.id != "checkpoint-override"))' "$REG" > "$REG.new"
  mv "$REG.new" "$REG"
  classify "checkpoint-override.json"
  [ "$output" = "unknown" ]
}
