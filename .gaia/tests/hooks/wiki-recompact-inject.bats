#!/usr/bin/env bats

# Tests for .claude/hooks/wiki-recompact-inject.sh.
#
# UserPromptSubmit half of the two-hook hot-cache restoration handshake, paired
# with wiki-recompact-sentinel.sh (PostCompact). Compaction drops
# hook-injected context, including the SessionStart hot cache. On the first
# prompt after a compaction this hook re-injects wiki/hot.md by writing it to
# stdout, which UserPromptSubmit adds to the model's context, then clears the
# sentinel so it fires exactly once.
#
# Three separate silent failures live here, and each has a test below: never
# firing (no injection at all), firing forever (the sentinel is never
# consumed), and consuming the sentinel without delivering. None of them is
# visible in normal use -- the hook exits 0 either way.
#
# The sentinel and the hot cache both resolve relative to the working
# directory, so every scenario runs in a throwaway directory via
# `invoke_hook_in`.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABS="$HOOKS_SRC/wiki-recompact-inject.sh"
  SETTINGS_ABS="${HOOKS_SRC%/hooks}/settings.json"
  WORK=$(mktemp -d -t gaia-recompact-inject-XXXXXX)
  SENTINEL="$WORK/.claude/wiki-recompact-pending"
  PAYLOAD='{"session_id":"S1","hook_event_name":"UserPromptSubmit","prompt":"carry on"}'
}

teardown() {
  # `return 0` because the guard is an AND-list: with no $WORK to remove it
  # would otherwise leave teardown non-zero and fail an innocent test.
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
  return 0
}

seed_hot_cache() {
  mkdir -p "$WORK/wiki"
  printf '# Recent Context\n\nthe thread we were on\n' > "$WORK/wiki/hot.md"
}

arm_sentinel() {
  mkdir -p "$WORK/.claude"
  : > "$SENTINEL"
}

# --- armed: the cache is re-injected ---

@test "an armed sentinel re-injects wiki/hot.md on stdout" {
  seed_hot_cache
  arm_sentinel
  invoke_hook_in "$WORK" "$PAYLOAD" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  grep -qF -- "the thread we were on" <<<"$output"
}

@test "the injection is labelled so the model knows what it is reading" {
  # Bare hot.md contents dropped into context read as an unexplained document.
  # The header is what marks it as restored state rather than a new
  # instruction.
  seed_hot_cache
  arm_sentinel
  invoke_hook_in "$WORK" "$PAYLOAD" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  grep -qF -- "Restored wiki hot cache after context compaction" <<<"$output"
}

@test "the sentinel is consumed by the injection" {
  seed_hot_cache
  arm_sentinel
  invoke_hook_in "$WORK" "$PAYLOAD" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -f "$SENTINEL" ]
}

@test "the injection fires exactly once per compaction" {
  # The failure this pins is re-injecting the cache on every prompt for the
  # rest of the session, which is silent, unbounded, and costs a copy of
  # hot.md per turn.
  seed_hot_cache
  arm_sentinel
  invoke_hook_in "$WORK" "$PAYLOAD" "$HOOK_ABS"
  grep -qF -- "the thread we were on" <<<"$output"

  invoke_hook_in "$WORK" "$PAYLOAD" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- unarmed: the ordinary prompt path is a silent no-op ---

@test "no sentinel is a silent no-op" {
  seed_hot_cache
  invoke_hook_in "$WORK" "$PAYLOAD" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "no sentinel and no hot cache is a silent no-op" {
  invoke_hook_in "$WORK" "$PAYLOAD" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- armed but nothing to deliver: the sentinel is still consumed ---

@test "an armed sentinel with no hot cache is consumed rather than retried" {
  # Consuming the sentinel BEFORE reading hot.md is deliberate: a single
  # failed injection must not loop forever on every subsequent prompt.
  arm_sentinel
  invoke_hook_in "$WORK" "$PAYLOAD" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$SENTINEL" ]
}

# --- degenerate payloads never block prompt submission ---

@test "malformed JSON on stdin still injects and never blocks the prompt" {
  # The hook reads no field out of the payload, so a payload shape change must
  # not cost the restoration. This is the case that would otherwise fail
  # silently for every user after an upstream schema change.
  seed_hot_cache
  arm_sentinel
  invoke_hook_in "$WORK" 'not json' "$HOOK_ABS"
  [ "$status" -eq 0 ]
  grep -qF -- "the thread we were on" <<<"$output"
}

@test "an unreadable hot cache never blocks the prompt" {
  # This is the only scenario here that exercises the ERR trap, so it must not
  # be allowed to pass vacuously: under root chmod 000 is ignored, the cat
  # succeeds, and the hook exits 0 for the ordinary reason with the fail-open
  # path never reached. Fail loudly in that case instead.
  seed_hot_cache
  arm_sentinel
  chmod 000 "$WORK/wiki/hot.md"
  if [ -r "$WORK/wiki/hot.md" ]; then
    chmod 644 "$WORK/wiki/hot.md"
    echo "precondition unavailable: hot.md stayed readable at mode 000, so the fail-open path cannot be exercised (running as root?)" >&2
    return 1
  fi
  invoke_hook_in "$WORK" "$PAYLOAD" "$HOOK_ABS"
  chmod 644 "$WORK/wiki/hot.md"
  [ "$status" -eq 0 ]
}

# --- structural ---

@test "wiki-recompact-inject.sh is executable" {
  [ -x "$HOOK_ABS" ]
}

@test "settings.json registers the hook under UserPromptSubmit" {
  run jq -e '.hooks.UserPromptSubmit[] | .hooks[] | select(.command == ".claude/hooks/wiki-recompact-inject.sh")' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}
