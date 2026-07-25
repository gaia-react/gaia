#!/usr/bin/env bats

# Tests for .gaia/statusline/gaia-statusline.sh state anchoring across trees.
#
# Every right-side segment reads SHARED state: the update-check cache, the debt
# count, and the setup marker are all scope "shared" in
# .gaia/state-registry.json, which means one physical copy under the MAIN
# checkout's .gaia/local. So there is no worktree gate. Each segment renders the
# same from every tree, because the state it reads IS the same. A flow that must
# run on the main checkout refuses out loud when it is invoked, which is where
# that belongs -- the statusline going dark cannot tell a developer anything.
#
# What each test varies is the SESSION's directory (the status payload's
# .workspace.current_dir), never the script's install path. Every test runs
# MAIN's copy of the script, mirroring the maintainer-wrapper case: the wrapper
# execs the shipped script from the main checkout even while the session runs in
# a worktree, so an install-path signal answers for the wrong checkout.
#
# HOME points at an empty dir so the left-side delegation is inert and the
# assertions see only the right side.

setup() {
  STATUSLINE_SRC=$(cd "$BATS_TEST_DIRNAME/../../statusline" && pwd)
  SCRIPTS_SRC=$(cd "$BATS_TEST_DIRNAME/../../scripts" && pwd)

  MAIN=$(mktemp -d -t gaia-sl-main-XXXXXX)
  git -C "$MAIN" init --quiet --initial-branch=main
  git -C "$MAIN" config user.email "test@example.com"
  git -C "$MAIN" config user.name "Test"
  git -C "$MAIN" config commit.gpgsign false

  mkdir -p "$MAIN/.gaia/statusline" "$MAIN/.gaia/scripts"
  cp "$STATUSLINE_SRC/gaia-statusline.sh" "$MAIN/.gaia/statusline/gaia-statusline.sh"
  cp "$SCRIPTS_SRC/main-root-lib.sh" "$MAIN/.gaia/scripts/main-root-lib.sh"
  echo "x" > "$MAIN/README.md"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit --quiet -m "init"

  # Main's shared state: three outdated deps, five open debt issues, setup
  # complete, no gaia-init gate file.
  mkdir -p "$MAIN/.gaia/local/cache/shared" "$MAIN/.gaia/local/debt"
  printf '{"outdatedCount":3}' > "$MAIN/.gaia/local/cache/shared/update-check.json"
  printf '{"openCount":5}' > "$MAIN/.gaia/local/debt/count.json"
  printf '{"completed_at":"2026-01-01T00:00:00Z"}' > "$MAIN/.gaia/local/setup-state.json"

  # A linked worktree off main (sibling path), deliberately UNPROVISIONED: no
  # symlinks back to main's .gaia/local. An unprovisioned tree is the honest
  # case to test, because a symlinked one would pass by coincidence -- the read
  # would land on main's file whatever root the script had derived.
  WT="${MAIN}-wt"
  git -C "$MAIN" worktree add --quiet "$WT" -b feature

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

@test "right-side indicators render when the session is in a linked worktree" {
  run_statusline "$WT"
  [ "$status" -eq 0 ]
  grep -qF -- "update-deps" <<<"$output"
  grep -qF -- "gaia-debt" <<<"$output"
}

@test "a worktree session reads main's shared state, not its own copy" {
  # The unprovisioned worktree grows its own .gaia/local holding DIFFERENT
  # numbers. Only a main-anchored read can still report main's.
  mkdir -p "$WT/.gaia/local/cache/shared" "$WT/.gaia/local/debt"
  printf '{"outdatedCount":99}' > "$WT/.gaia/local/cache/shared/update-check.json"
  printf '{"openCount":77}' > "$WT/.gaia/local/debt/count.json"
  printf '{"completed_at":"2026-01-01T00:00:00Z"}' > "$WT/.gaia/local/setup-state.json"

  run_statusline "$WT"
  [ "$status" -eq 0 ]
  grep -qF -- "(3 outdated)" <<<"$output"
  grep -qF -- "(5 issues)" <<<"$output"
  grep -qF -- "99 outdated" <<<"$output" && return 1
  grep -qF -- "77 issues" <<<"$output" && return 1
  return 0
}

@test "an incomplete setup is reported from a worktree too" {
  # The setup marker is shared, so an unset-up clone is unset-up from every
  # tree. Suppressing this segment in a worktree hid a real, blocking condition.
  printf '{"completed_at":null}' > "$MAIN/.gaia/local/setup-state.json"
  run_statusline "$WT"
  [ "$status" -eq 0 ]
  grep -qF -- "setup-gaia" <<<"$output"
}

@test "the mid-init gate still suppresses every indicator, from any tree" {
  mkdir -p "$MAIN/.claude/commands"
  printf 'x\n' > "$MAIN/.claude/commands/gaia-init.md"

  run_statusline "$MAIN"
  [ "$status" -eq 0 ]
  grep -qF -- "update-deps" <<<"$output" && return 1

  run_statusline "$WT"
  [ "$status" -eq 0 ]
  grep -qF -- "update-deps" <<<"$output" && return 1
  return 0
}

@test "a checkout with no git still renders, falling back to the install path" {
  # The resolver-failure disposition for this consumer is to degrade silently
  # (SPEC-058), and the honest fallback is this script's own checkout: a tree
  # with no git has no linked worktrees, so the install path IS the only
  # checkout. A scaffolded-but-not-yet-git-init project must not go dark.
  NOGIT=$(mktemp -d -t gaia-sl-nogit-XXXXXX)
  mkdir -p "$NOGIT/.gaia/statusline" "$NOGIT/.gaia/scripts" \
           "$NOGIT/.gaia/local/cache/shared"
  cp "$STATUSLINE_SRC/gaia-statusline.sh" "$NOGIT/.gaia/statusline/gaia-statusline.sh"
  cp "$SCRIPTS_SRC/main-root-lib.sh" "$NOGIT/.gaia/scripts/main-root-lib.sh"
  printf '{"outdatedCount":3}' > "$NOGIT/.gaia/local/cache/shared/update-check.json"
  printf '{"completed_at":"2026-01-01T00:00:00Z"}' > "$NOGIT/.gaia/local/setup-state.json"

  json=$(jq -n --arg d "$NOGIT" '{workspace: {current_dir: $d}, cwd: $d}')
  run env HOME="$TMP_HOME" bash -c "printf '%s' '$json' | bash '$NOGIT/.gaia/statusline/gaia-statusline.sh'"
  [ "$status" -eq 0 ]
  grep -qF -- "update-deps" <<<"$output"
  rm -rf "$NOGIT"
}
