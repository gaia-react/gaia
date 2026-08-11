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
# rendered right side, covering UAT-013..017.
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
  THIS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  STATUSLINE_SRC="$THIS_DIR/../../statusline/gaia-statusline.sh"
  RESOLVER_SRC="$THIS_DIR/../main-root-lib.sh"
  [ -f "$STATUSLINE_SRC" ] || skip "gaia-statusline.sh missing"
  [ -f "$RESOLVER_SRC" ] || skip "main-root-lib.sh missing"
  command -v jq >/dev/null 2>&1 || skip "jq required"

  TMPROOT_RAW="$(mktemp -d "${TMPDIR:-/tmp}/gaia-serena-sl-XXXXXX")"
  TMPROOT="$(cd "$TMPROOT_RAW" && pwd -P)"

  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"

  # Fake, empty HOME: no ~/.claude/settings.json, so the left side falls back to
  # the bare "Claude Code" label and no user statusline command runs.
  FAKE_HOME="$TMPROOT/home"
  mkdir -p "$FAKE_HOME"
}

teardown() {
  # Clean up any linked worktree first so git does not complain, then the tree.
  if [ -n "${MAIN:-}" ] && [ -n "${LINKED:-}" ] && [ -d "$MAIN" ]; then
    git -C "$MAIN" worktree remove --force "$LINKED" 2>/dev/null || true
  fi
  if [ -n "${TMPROOT:-}" ] && [ -d "$TMPROOT" ]; then
    rm -rf "$TMPROOT"
  fi
  if [ -n "${TMPROOT_RAW:-}" ] && [ "$TMPROOT_RAW" != "${TMPROOT:-}" ] && [ -d "$TMPROOT_RAW" ]; then
    rm -rf "$TMPROOT_RAW"
  fi
}

# scaffold_root <root> : drop a copy of the statusline script under the root's
# .gaia/statusline/ and create the .gaia/local/cache/shared and .gaia/local dirs.
# The resolver library is copied too, so the fixtures exercise the shipped
# main-root resolution rather than silently taking the no-library fallback.
scaffold_root() {
  local r="$1"
  mkdir -p "$r/.gaia/statusline" "$r/.gaia/scripts" \
           "$r/.gaia/local/cache/shared" "$r/.gaia/local"
  cp "$STATUSLINE_SRC" "$r/.gaia/statusline/gaia-statusline.sh"
  cp "$RESOLVER_SRC" "$r/.gaia/scripts/main-root-lib.sh"
}

# write_cache <root> <serenaLangDrift-json-or-ABSENT>
write_cache() {
  local r="$1" drift="$2"
  if [ "$drift" = "ABSENT" ]; then
    printf '{"outdatedCount":0,"gaiaHasUpdate":false}\n' > "$r/.gaia/local/cache/shared/update-check.json"
  else
    printf '{"outdatedCount":0,"gaiaHasUpdate":false,"serenaLangDrift":%s}\n' "$drift" \
      > "$r/.gaia/local/cache/shared/update-check.json"
  fi
}

# write_setup <root> <complete|null|none>
write_setup() {
  local r="$1" mode="$2"
  case "$mode" in
    complete) printf '{"completed_at":"2026-01-01T00:00:00Z"}\n' > "$r/.gaia/local/setup-state.json" ;;
    null)     printf '{"completed_at":null}\n' > "$r/.gaia/local/setup-state.json" ;;
    none)     rm -f "$r/.gaia/local/setup-state.json" ;;
  esac
}

# render <root> : pipe a minimal Claude Code JSON payload into the fixture's
# statusline with the fake HOME; combined output lands in $output via `run`.
render() {
  run env HOME="$FAKE_HOME" bash -c 'printf "%s" "{}" | bash "$1"' _ "$1/.gaia/statusline/gaia-statusline.sh"
}

@test "UAT-013 statusline: serenaLangDrift [python, go], setup complete -> full segment" {
  local r="$TMPROOT/r013"
  scaffold_root "$r"
  write_cache "$r" '["python","go"]'
  write_setup "$r" complete
  render "$r"
  [ "$status" -eq 0 ]
  assert_contains 'Run /gaia-serena-sync (Serena missing: python, go)'
}

@test "UAT-014 statusline: serenaLangDrift [go] -> segment names only go, never python" {
  local r="$TMPROOT/r014"
  scaffold_root "$r"
  write_cache "$r" '["go"]'
  write_setup "$r" complete
  render "$r"
  [ "$status" -eq 0 ]
  assert_contains 'Run /gaia-serena-sync (Serena missing: go)'
  refute_contains 'python'
}

@test "UAT-015 statusline: empty array and absent field both render no segment" {
  local r_empty="$TMPROOT/r015empty"
  scaffold_root "$r_empty"
  write_cache "$r_empty" '[]'
  write_setup "$r_empty" complete
  render "$r_empty"
  [ "$status" -eq 0 ]
  refute_contains "$SEGMENT"

  local r_absent="$TMPROOT/r015absent"
  scaffold_root "$r_absent"
  write_cache "$r_absent" ABSENT
  write_setup "$r_absent" complete
  render "$r_absent"
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
  MAIN="$TMPROOT/main"
  mkdir -p "$MAIN"
  git -C "$MAIN" init -q
  git -C "$MAIN" commit --allow-empty -q -m "init"
  LINKED="$TMPROOT/linked"
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
  local r_none="$TMPROOT/r017none"
  scaffold_root "$r_none"
  write_cache "$r_none" '["go"]'
  write_setup "$r_none" none
  render "$r_none"
  [ "$status" -eq 0 ]
  refute_contains "$SEGMENT"

  # (b) setup-state.json present but completed_at is null.
  local r_null="$TMPROOT/r017null"
  scaffold_root "$r_null"
  write_cache "$r_null" '["go"]'
  write_setup "$r_null" null
  render "$r_null"
  [ "$status" -eq 0 ]
  refute_contains "$SEGMENT"
}
