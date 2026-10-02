#!/usr/bin/env bats
#
# Bats suite for the Serena language-sync statusline segment in
# .gaia/statusline/gaia-statusline.sh (SPEC-016 task-statusline-segment).
#
# The render is a thin consumer of the cache field serenaLangDrift: it
# comma-joins the array via `jq '(.serenaLangDrift // []) | join(", ")'` and
# emits `Run /gaia-serena-sync (Serena missing: <langs>)`. The gate is two
# conditions, not one: per-clone setup complete, and the session sits on the
# main checkout. The cache itself is shared state read from the resolved main
# root, one fact about the clone -- but that fact alone does not make the
# segment render from every tree, only from the tree that can act on it.
# These tests inject the cache directly (no drift computation) and assert the
# rendered right side, covering UAT-013, UAT-015..017.
#
# Hermeticity: each fixture PROJECT_ROOT lives under a per-test mktemp -d with a
# fake $HOME (so the left-side delegation never reads the real
# ~/.claude/settings.json). The refresher scripts are absent from the fixture,
# so the statusline's background-refresh forks are inert. Nothing touches the
# real repo cache.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

SEGMENT='Run /gaia-serena-sync (Serena missing:'

assert_contains() {
  grep -qF -- "$1" <<<"$output"
}

refute_contains() {
  if grep -qF -- "$1" <<<"$output"; then
    echo "unexpected match: $1" >&2
    return 1
  fi
}

setup() {
  THIS_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  STATUSLINE_SOURCE="$THIS_DIRECTORY/../../statusline/gaia-statusline.sh"
  RESOLVER_SOURCE="$THIS_DIRECTORY/../main-root-lib.sh"
  [ -f "$STATUSLINE_SOURCE" ] || skip "gaia-statusline.sh missing"
  [ -f "$RESOLVER_SOURCE" ] || skip "main-root-lib.sh missing"
  command -v jq >/dev/null 2>&1 || skip "jq required"

  TEMPORARY_ROOT_RAW="$(mktemp -d "${TMPDIR:-/tmp}/gaia-serena-sl-XXXXXX")"
  TEMPORARY_ROOT="$(cd "$TEMPORARY_ROOT_RAW" && pwd -P)"

  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"

  # Fake, empty HOME: no ~/.claude/settings.json, so the left side falls back to
  # the bare "Claude Code" label and no user statusline command runs.
  FAKE_HOME="$TEMPORARY_ROOT/home"
  mkdir -p "$FAKE_HOME"
}

teardown() {
  # Clean up any linked worktree first so git does not complain, then the tree.
  if [ -n "${MAIN:-}" ] && [ -n "${LINKED:-}" ] && [ -d "$MAIN" ]; then
    git -C "$MAIN" worktree remove --force "$LINKED" 2>/dev/null || true
  fi
  if [ -n "${TEMPORARY_ROOT:-}" ] && [ -d "$TEMPORARY_ROOT" ]; then
    rm -rf "$TEMPORARY_ROOT"
  fi
  if [ -n "${TEMPORARY_ROOT_RAW:-}" ] && [ "$TEMPORARY_ROOT_RAW" != "${TEMPORARY_ROOT:-}" ] && [ -d "$TEMPORARY_ROOT_RAW" ]; then
    rm -rf "$TEMPORARY_ROOT_RAW"
  fi
}

# scaffold_root <root> : drop a copy of the statusline script under the root's
# .gaia/statusline/ and create the .gaia/local/cache/shared and .gaia/local dirs.
# The resolver library is copied too, so the fixtures exercise the shipped
# main-root resolution rather than silently taking the no-library fallback.
scaffold_root() {
  local root="$1"
  mkdir -p "$root/.gaia/statusline" "$root/.gaia/scripts" \
           "$root/.gaia/local/cache/shared" "$root/.gaia/local"
  cp "$STATUSLINE_SOURCE" "$root/.gaia/statusline/gaia-statusline.sh"
  cp "$RESOLVER_SOURCE" "$root/.gaia/scripts/main-root-lib.sh"
}

# write_cache <root> <serenaLangDrift-json-or-ABSENT>
write_cache() {
  local root="$1" drift="$2"
  if [ "$drift" = "ABSENT" ]; then
    printf '{"outdatedCount":0,"gaiaHasUpdate":false}\n' > "$root/.gaia/local/cache/shared/update-check.json"
  else
    printf '{"outdatedCount":0,"gaiaHasUpdate":false,"serenaLangDrift":%s}\n' "$drift" \
      > "$root/.gaia/local/cache/shared/update-check.json"
  fi
}

# write_setup <root> <complete|null|none>
write_setup() {
  local root="$1" mode="$2"
  case "$mode" in
    complete) printf '{"completed_at":"2026-01-01T00:00:00Z"}\n' > "$root/.gaia/local/setup-state.json" ;;
    null)     printf '{"completed_at":null}\n' > "$root/.gaia/local/setup-state.json" ;;
    none)     rm -f "$root/.gaia/local/setup-state.json" ;;
  esac
}

# render <root> : pipe a minimal Claude Code JSON payload into the fixture's
# statusline with the fake HOME; combined output lands in $output via `run`.
render() {
  run env HOME="$FAKE_HOME" bash -c 'printf "%s" "{}" | bash "$1"' _ "$1/.gaia/statusline/gaia-statusline.sh"
}

@test "UAT-013 statusline: serenaLangDrift [python, go], setup complete -> full segment" {
  local root="$TEMPORARY_ROOT/r013"
  scaffold_root "$root"
  write_cache "$root" '["python","go"]'
  write_setup "$root" complete
  render "$root"
  [ "$status" -eq 0 ]
  assert_contains 'Run /gaia-serena-sync (Serena missing: python, go)'
}

@test "UAT-015 statusline: empty array and absent field both render no segment" {
  local root_empty="$TEMPORARY_ROOT/r015empty"
  scaffold_root "$root_empty"
  write_cache "$root_empty" '[]'
  write_setup "$root_empty" complete
  render "$root_empty"
  [ "$status" -eq 0 ]
  refute_contains "$SEGMENT"

  local root_absent="$TEMPORARY_ROOT/r015absent"
  scaffold_root "$root_absent"
  write_cache "$root_absent" ABSENT
  write_setup "$root_absent" complete
  render "$root_absent"
  [ "$status" -eq 0 ]
  refute_contains "$SEGMENT"
}

@test "UAT-016 statusline: non-empty drift is suppressed from a linked git worktree" {
  # The Serena segment is nudge 7: it renders only from the main checkout, even
  # though the drift cache it reads is shared state living under main. The
  # worktree is left UNPROVISIONED (no symlinks back to main) and the cache is
  # written only under main, so a render here that showed the segment could
  # only come from a main-anchored read that ignored the worktree gate -- the
  # case this test rules out.
  MAIN="$TEMPORARY_ROOT/main"
  mkdir -p "$MAIN"
  git -C "$MAIN" init -q
  git -C "$MAIN" commit --allow-empty -q -m "init"
  LINKED="$TEMPORARY_ROOT/linked"
  git -C "$MAIN" worktree add -q "$LINKED" -b "feat/serena-sl"

  scaffold_root "$MAIN"
  scaffold_root "$LINKED"
  write_cache "$MAIN" '["go"]'
  write_setup "$MAIN" complete
  render "$LINKED"
  [ "$status" -eq 0 ]
  refute_contains 'Run /gaia-serena-sync (Serena missing: go)'

  # Mirror: the identical cache and setup state still renders from main.
  # Without this, the refutation above would stay green even if the segment
  # stopped rendering anywhere at all.
  render "$MAIN"
  [ "$status" -eq 0 ]
  assert_contains 'Run /gaia-serena-sync (Serena missing: go)'
}

@test "UAT-017 statusline: non-empty drift but setup not complete (missing or null) -> no segment" {
  # (a) setup-state.json entirely absent.
  local root_none="$TEMPORARY_ROOT/r017none"
  scaffold_root "$root_none"
  write_cache "$root_none" '["go"]'
  write_setup "$root_none" none
  render "$root_none"
  [ "$status" -eq 0 ]
  refute_contains "$SEGMENT"

  # (b) setup-state.json present but completed_at is null.
  local root_null="$TEMPORARY_ROOT/r017null"
  scaffold_root "$root_null"
  write_cache "$root_null" '["go"]'
  write_setup "$root_null" null
  render "$root_null"
  [ "$status" -eq 0 ]
  refute_contains "$SEGMENT"
}
