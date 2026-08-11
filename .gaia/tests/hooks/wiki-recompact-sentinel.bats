#!/usr/bin/env bats

# Tests for .claude/hooks/wiki-recompact-sentinel.sh.
#
# PostCompact half of the two-hook hot-cache restoration handshake. A
# PostCompact command hook cannot inject its stdout into context, so it drops a
# sentinel file instead and wiki-recompact-inject.sh (UserPromptSubmit) does the
# injection on the next turn. This hook's ENTIRE observable behavior is that one
# file: it prints nothing, it decides nothing, and it always exits 0. If it
# stops writing the sentinel, the hot cache silently never comes back after a
# compaction and there is no error anywhere to notice.
#
# The sentinel and the hot cache are both resolved relative to the working
# directory, so every scenario runs in a throwaway directory via
# `invoke_hook_in`. The hook reads no stdin, so the payload passed is empty.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABS="$HOOKS_SRC/wiki-recompact-sentinel.sh"
  SETTINGS_ABS="${HOOKS_SRC%/hooks}/settings.json"
  WORK=$(mktemp -d -t gaia-recompact-sentinel-XXXXXX)
  SENTINEL="$WORK/.claude/wiki-recompact-pending"
}

teardown() {
  # `return 0` because the guard is an AND-list: with no $WORK to remove it
  # would otherwise leave teardown non-zero and fail an innocent test.
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
  return 0
}

seed_hot_cache() {
  mkdir -p "$WORK/wiki"
  printf '# Recent Context\n\nlast thread\n' > "$WORK/wiki/hot.md"
}

# --- the sentinel is dropped when there is a hot cache to restore ---

@test "a hot cache present drops the sentinel" {
  seed_hot_cache
  invoke_hook_in "$WORK" '' "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$SENTINEL" ]
}

@test "the drop is silent on stdout and stderr" {
  # PostCompact output reaches nobody useful, and a chatty hook on the
  # compaction path is pure noise. Silence is the contract.
  seed_hot_cache
  invoke_hook_in "$WORK" '' "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the sentinel is created even when .claude/ does not exist yet" {
  # A fresh clone has no .claude/ working state; the hook makes the directory
  # rather than failing into a no-op, which would lose the restoration.
  seed_hot_cache
  [ ! -d "$WORK/.claude" ]
  invoke_hook_in "$WORK" '' "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$SENTINEL" ]
}

@test "a second compaction leaves the sentinel in place" {
  seed_hot_cache
  invoke_hook_in "$WORK" '' "$HOOK_ABS"
  invoke_hook_in "$WORK" '' "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$SENTINEL" ]
}

@test "the sentinel is a marker, not a carrier: it holds no content" {
  seed_hot_cache
  invoke_hook_in "$WORK" '' "$HOOK_ABS"
  [ ! -s "$SENTINEL" ]
}

# --- no hot cache, nothing to restore, no sentinel ---

@test "no wiki/hot.md means no sentinel" {
  # Dropping one here would arm the inject hook to consume a sentinel and
  # deliver nothing, burning the single-shot handshake for no reason.
  invoke_hook_in "$WORK" '' "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$SENTINEL" ]
}

@test "a wiki/ directory with no hot.md still means no sentinel" {
  mkdir -p "$WORK/wiki"
  invoke_hook_in "$WORK" '' "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -f "$SENTINEL" ]
}

# --- fail-open: an internal failure never disrupts the compaction ---

@test "an unwritable working state directory never fails the compaction" {
  # The hook runs `set -euo pipefail` with `trap 'exit 0' ERR` precisely so a
  # failed mkdir or write costs the restoration rather than the compaction
  # event. Without a scenario that makes an internal step fail, that trap can
  # be deleted with every other test in this suite still green.
  seed_hot_cache
  chmod 555 "$WORK"
  # Under root the mode is ignored and the mkdir succeeds, which would green
  # this test without exercising the fail-open path at all. Fail loudly rather
  # than vacuously, naming the cause so the red reads as an unexercisable
  # precondition rather than a hook regression.
  if [ -w "$WORK" ]; then
    chmod 755 "$WORK"
    echo "precondition unavailable: \$WORK stayed writable at mode 555, so the fail-open path cannot be exercised (running as root?)" >&2
    return 1
  fi
  invoke_hook_in "$WORK" '' "$HOOK_ABS"
  chmod 755 "$WORK"
  # Exit status is the whole contract here. The failing mkdir writes its own
  # "Permission denied" to stderr, which bats' `run` merges into $output, so
  # asserting silence would red this test on every non-root host for a reason
  # that has nothing to do with the trap. Ordinary-path silence is pinned by
  # "the drop is silent on stdout and stderr" above.
  [ "$status" -eq 0 ]
}

# --- structural ---

@test "wiki-recompact-sentinel.sh is executable" {
  [ -x "$HOOK_ABS" ]
}

@test "settings.json registers the hook under PostCompact" {
  run jq -e '.hooks.PostCompact[] | .hooks[] | select(.command == ".claude/hooks/wiki-recompact-sentinel.sh")' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}

@test "the sentinel path matches the one wiki-recompact-inject.sh consumes" {
  # The two hooks share no library; the path is spelled out in each. A rename
  # in one alone breaks the handshake silently, with both halves still exiting
  # 0 forever.
  grep -qF -- '.claude/wiki-recompact-pending' "$HOOK_ABS"
  grep -qF -- '.claude/wiki-recompact-pending' "$HOOKS_SRC/wiki-recompact-inject.sh"
}
