#!/usr/bin/env bats
#
# Bats suite for which hooks the cost path registers. Nothing registered in
# .claude/settings.json or frontend/.claude/settings.json runs the token-tally
# hooks or the old merge roll-up; the `gh pr merge` PostToolUse registration
# names pr-merge-cost.sh, and that hook invokes no script beyond the libraries
# it loads and usage-merge.sh.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/tests/hooks/cost-hook-registrations.bats

bats_require_minimum_version 1.5.0

setup() {
  SOURCE_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  export GAIA_RATES_STATE_DIRECTORY="$BATS_TEST_TMPDIR/rates-state" GAIA_RATES_FEED_DISABLE=1
  SETTINGS_FILES=("$SOURCE_ROOT/.claude/settings.json" "$SOURCE_ROOT/frontend/.claude/settings.json")
}

# registered_commands <settings-file>: every command string of every hook
# registration, in any event, one per line.
registered_commands() {
  jq -r '[.hooks // {} | to_entries[] | .value[] | .hooks[]? | .command // empty] | .[]' "$1"
}

# merge_commands <settings-file>: the commands of the PostToolUse registrations
# guarded by `if: Bash(gh pr merge *)`.
merge_commands() {
  jq -r '[.hooks.PostToolUse // [] | .[] | .hooks[]? | select((.if // "") == "Bash(gh pr merge *)") | .command] | .[]' "$1"
}

# retired_tally_registrations <settings-file>: the registrations naming either
# retired token-tally hook; the settings file passes when this prints nothing
# and the registered set it was drawn from is not empty.
retired_tally_registrations() {
  [ -n "$(registered_commands "$1")" ] || { printf 'no registrations read from %s\n' "$1" >&2; return 2; }
  registered_commands "$1" | grep -E 'token-tally-(review|git-op)\.sh' || true
}

@test "no Stop, PreToolUse or PostToolUse registration names a token-tally hook, in either settings file" {
  local settings_file
  for settings_file in "${SETTINGS_FILES[@]}"; do
    [ -f "$settings_file" ]
    [ -n "$(registered_commands "$settings_file")" ]
    [ -z "$(retired_tally_registrations "$settings_file")" ]
  done
}

@test "the gh pr merge PostToolUse registration names pr-merge-cost.sh and nothing names token-rollup-merge.sh" {
  local settings_file
  for settings_file in "${SETTINGS_FILES[@]}"; do
    [ "$(merge_commands "$settings_file" | grep -c 'pr-merge-cost\.sh')" -eq 1 ]
    registered_commands "$settings_file" | grep -qF 'token-rollup-merge.sh' && return 1
  done
  true
}

@test "pr-merge-cost.sh invokes only the libraries it loads and usage-merge.sh" {
  local hook="$SOURCE_ROOT/.claude/hooks/pr-merge-cost.sh" invoked expected
  invoked="$(grep -vE '^[[:space:]]*#' "$hook" | grep -oE '(^|[;&|[:space:]])(bash|\.)[[:space:]]+"[^"]+"' | grep -oE '[A-Za-z0-9_.-]+\.sh' | LC_ALL=C sort -u)"
  [ -n "$invoked" ]
  expected="$(printf '%s\n' hook-payload.sh usage-merge.sh verb-arming.sh)"
  [ "$invoked" = "$expected" ]
}

@test "guards-must-fail: a scratch settings copy re-adding a token-tally-review Stop entry is caught" {
  local scratch="$BATS_TEST_TMPDIR/settings.json"
  jq '.hooks.Stop[0].hooks += [{"type":"command","command":"\"$(git rev-parse --show-toplevel)/.claude/hooks/token-tally-review.sh\""}]' \
    "$SOURCE_ROOT/.claude/settings.json" >"$scratch"
  [ -n "$(retired_tally_registrations "$scratch")" ]
}

@test "guards-must-fail: a scratch settings copy registering token-rollup-merge.sh on the merge verb is caught" {
  local scratch="$BATS_TEST_TMPDIR/settings.json"
  sed 's/pr-merge-cost\.sh/token-rollup-merge.sh/' "$SOURCE_ROOT/.claude/settings.json" >"$scratch"
  [ "$(merge_commands "$scratch" | grep -c 'pr-merge-cost\.sh' || true)" -eq 0 ]
  registered_commands "$scratch" | grep -qF 'token-rollup-merge.sh'
}
