#!/usr/bin/env bats

# Tests for .claude/hooks/lib/gaia-ci-defer.sh.
#
# The lib is the stand-down switch every local automatic trigger consults: when
# the acting tree's .gaia/automation.json puts a tool in `ci` mode, the local
# trigger defers to the cron-managed run instead of firing. Its failure
# direction is the dangerous one -- an unreadable config means "not managed",
# so the local trigger fires. That is correct when the config genuinely is
# absent and wrong when the config exists but was looked for in the wrong
# place, and the two are indistinguishable from the caller's side: the output
# is byte-identical to having no config at all.

setup() {
  LIB_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks/lib" && pwd)/gaia-ci-defer.sh
  REPO=$("$BATS_TEST_DIRNAME/helpers/tmp-git-repo.sh")
  mkdir -p "$REPO/.gaia"
}

teardown() {
  # `return 0` because the guard is an AND-list: with no $REPO to remove it
  # would otherwise leave teardown non-zero and fail an innocent test.
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  return 0
}

# Drive the lib the way a hook does: source it, then call the function. The
# managed arm ends in `exit 0`, so the status below is the subshell's.
defer_from() {
  local dir="$1" key="$2"
  run bash -c 'cd "$1" && . "$2" && gaia_ci_defer_if_managed "$3"' _ "$dir" "$LIB_ABS" "$key"
}

write_config() {
  printf '%s\n' "$1" > "$REPO/.gaia/automation.json"
}

@test "defers at the tree root when the tool is CI-managed" {
  write_config '{"wiki":{"mode":"ci"}}'
  defer_from "$REPO" wiki
  [ "$status" -eq 0 ]
  grep -qF -- 'wiki is CI-managed; deferring' <<<"$output"
}

# --- the non-managed arms stay silent -----------------------------------

@test "does not defer when the tool is in local mode" {
  write_config '{"wiki":{"mode":"local"}}'
  defer_from "$REPO" wiki
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "does not defer when the config names a different tool" {
  write_config '{"pnpm_audit":{"mode":"ci"}}'
  defer_from "$REPO" wiki
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "does not defer when the tree carries no config at all" {
  rm -f "$REPO/.gaia/automation.json"
  defer_from "$REPO" wiki
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "does not defer on a malformed config" {
  write_config 'not json'
  defer_from "$REPO" wiki
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
