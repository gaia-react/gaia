#!/usr/bin/env bats
#
# Bats suite for which hooks the cost path registers. Nothing registered in
# .claude/settings.json or frontend/.claude/settings.json runs a retired tally
# hook or the old merge roll-up; the `gh pr merge` PostToolUse registration
# names pr-merge-cost.sh, and that hook invokes no script beyond the libraries
# it loads and usage-merge.sh.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/tests/hooks/cost-hook-registrations.bats

bats_require_minimum_version 1.5.0

# The retired hooks' file names are assembled from parts so no file outside the
# retired-name exclusions holds one literally.
RETIRED_REVIEW_HOOK="token-""tally-review.sh"
RETIRED_GIT_OP_HOOK="token-""tally-git-op.sh"
RETIRED_MERGE_HOOK="token-""rollup-merge.sh"

setup() {
  SOURCE_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
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

# retired_tally_hooks_present <hooks-directory>: the retired tally hook files
# found in the directory; the directory passes when this prints nothing and the
# directory itself holds hooks.
retired_tally_hooks_present() {
  [ -f "$1/pr-merge-cost.sh" ] || { printf 'no hooks read from %s\n' "$1" >&2; return 2; }
  local retired_hook
  for retired_hook in "$RETIRED_REVIEW_HOOK" "$RETIRED_GIT_OP_HOOK"; do
    [ -e "$1/$retired_hook" ] && printf '%s\n' "$retired_hook"
  done
  true
}

# retired_tally_registrations <settings-file>: the registrations naming either
# retired tally hook; the settings file passes when this prints nothing and the
# registered set it was drawn from is not empty.
retired_tally_registrations() {
  [ -n "$(registered_commands "$1")" ] || { printf 'no registrations read from %s\n' "$1" >&2; return 2; }
  registered_commands "$1" | grep -F -e "$RETIRED_REVIEW_HOOK" -e "$RETIRED_GIT_OP_HOOK" || true
}

@test "no Stop, PreToolUse or PostToolUse registration names a retired tally hook, in either settings file" {
  local settings_file
  for settings_file in "${SETTINGS_FILES[@]}"; do
    [ -f "$settings_file" ]
    [ -n "$(registered_commands "$settings_file")" ]
    [ -z "$(retired_tally_registrations "$settings_file")" ]
  done
}

@test "neither retired tally hook file exists under .claude/hooks" {
  [ -z "$(retired_tally_hooks_present "$SOURCE_ROOT/.claude/hooks")" ]
}

@test "the gh pr merge PostToolUse registration names pr-merge-cost.sh and nothing names the retired roll-up hook" {
  local settings_file
  for settings_file in "${SETTINGS_FILES[@]}"; do
    [ "$(merge_commands "$settings_file" | grep -c 'pr-merge-cost\.sh')" -eq 1 ]
    registered_commands "$settings_file" | grep -qF "$RETIRED_MERGE_HOOK" && return 1
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

@test "guards-must-fail: a scratch settings copy re-adding a retired tally review Stop entry is caught" {
  local scratch="$BATS_TEST_TMPDIR/settings.json"
  jq --arg hook "$RETIRED_REVIEW_HOOK" '.hooks.Stop[0].hooks += [{"type":"command","command":("\"$(git rev-parse --show-toplevel)/.claude/hooks/" + $hook + "\"")}]' \
    "$SOURCE_ROOT/.claude/settings.json" >"$scratch"
  [ -n "$(retired_tally_registrations "$scratch")" ]
}

@test "guards-must-fail: a scratch hooks directory holding a retired tally hook is caught" {
  local scratch="$BATS_TEST_TMPDIR/hooks" retired_hook
  for retired_hook in "$RETIRED_REVIEW_HOOK" "$RETIRED_GIT_OP_HOOK"; do
    rm -rf "$scratch"
    mkdir -p "$scratch"
    cp "$SOURCE_ROOT/.claude/hooks/pr-merge-cost.sh" "$scratch/"
    [ -z "$(retired_tally_hooks_present "$scratch")" ]
    : >"$scratch/$retired_hook"
    [ "$(retired_tally_hooks_present "$scratch")" = "$retired_hook" ]
  done
}

@test "guards-must-fail: a scratch settings copy registering the retired roll-up hook on the merge verb is caught" {
  local scratch="$BATS_TEST_TMPDIR/settings.json"
  sed "s/pr-merge-cost\\.sh/$RETIRED_MERGE_HOOK/" "$SOURCE_ROOT/.claude/settings.json" >"$scratch"
  [ "$(merge_commands "$scratch" | grep -c 'pr-merge-cost\.sh' || true)" -eq 0 ]
  registered_commands "$scratch" | grep -qF "$RETIRED_MERGE_HOOK"
}
