#!/usr/bin/env bats

# Tests for .gaia/statusline/gaia-statusline.sh worktree detection.
#
# The right-side maintenance indicators render only when the session is on the
# main checkout; a linked worktree suppresses them (the flows they prod toward
# belong on main). Detection keys off the session directory carried in the
# status payload (.workspace.current_dir), NOT the script's install path: a
# maintainer wrapper execs the shipped script from the main checkout even while
# the session runs in a worktree, so a PROJECT_ROOT-based signal would leak the
# indicators into worktree sessions.
#
# Each test runs MAIN's copy of the script (so PROJECT_ROOT resolves to main,
# mirroring the wrapper case) and varies only the payload's current_dir. HOME is
# pointed at an empty dir so the left-side delegation is inert and the assertion
# sees only the right side.

setup() {
  STATUSLINE_SRC=$(cd "$BATS_TEST_DIRNAME/../../statusline" && pwd)

  MAIN=$(mktemp -d -t gaia-sl-main-XXXXXX)
  git -C "$MAIN" init --quiet --initial-branch=main
  git -C "$MAIN" config user.email "test@example.com"
  git -C "$MAIN" config user.name "Test"
  git -C "$MAIN" config commit.gpgsign false

  mkdir -p "$MAIN/.gaia/statusline"
  cp "$STATUSLINE_SRC/gaia-statusline.sh" "$MAIN/.gaia/statusline/gaia-statusline.sh"
  echo "x" > "$MAIN/README.md"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit --quiet -m "init"

  # Right-side content: one outdated-deps segment, setup marked complete, and no
  # gaia-init gate file, so the indicators are eligible to render on main.
  mkdir -p "$MAIN/.gaia/local/cache/shared"
  printf '{"outdatedCount":3}' > "$MAIN/.gaia/local/cache/shared/update-check.json"
  printf '{"completed_at":"2026-01-01T00:00:00Z"}' > "$MAIN/.gaia/local/setup-state.json"

  # A linked worktree off main (sibling path).
  git -C "$MAIN" worktree add --quiet "${MAIN}-wt" -b feature

  TMP_HOME=$(mktemp -d -t gaia-sl-home-XXXXXX)
}

teardown() {
  [ -n "${MAIN:-}" ] && rm -rf "$MAIN" "${MAIN}-wt" || true
  [ -n "${TMP_HOME:-}" ] && rm -rf "$TMP_HOME" || true
  return 0
}

# Run MAIN's copy of the script with a payload whose current_dir is $1.
run_statusline() {
  local cur="$1" json
  json=$(jq -n --arg d "$cur" '{workspace: {current_dir: $d}, cwd: $d, model: {display_name: "Test"}, context_window: {used_percentage: 10}}')
  run env HOME="$TMP_HOME" bash -c "printf '%s' '$json' | bash '$MAIN/.gaia/statusline/gaia-statusline.sh'"
}

@test "right-side indicators render when the session is on main" {
  run_statusline "$MAIN"
  [ "$status" -eq 0 ]
  grep -qF -- "update-deps" <<<"$output"
}

@test "right-side indicators are suppressed when the session is in a worktree" {
  run_statusline "${MAIN}-wt"
  [ "$status" -eq 0 ]
  ! grep -qF -- "update-deps" <<<"$output"
}
