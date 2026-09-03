#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/check-hook-command-rooting.sh.
#
# .claude/settings.json registers every hook as a command string that
# /bin/sh runs against the Bash tool's current working directory, which
# persists for the whole session. A command naming its script by a
# repo-relative path therefore resolves against wherever the session last
# stood, so a single `cd` unregisters the layer: the script is not found,
# /bin/sh exits 127, and per wiki/concepts/Claude Hooks.md only exit 2
# blocks. 127 is neither 0 nor 2, so the tool call proceeds and the guard
# layer fails OPEN. That is #1740, observed end to end.
#
# This suite IS the gate for the registration file: nothing else in the
# repo asserts that a hook command resolves independently of cwd, so the
# "real repo" test below is what actually fails a build when an unrooted
# registration lands (same shape as check-wiki-state-collision.bats).
#
# What the check can and cannot do is a decided residual, not an
# oversight. It reads the file, so it catches an unrooted registration in
# the file. It cannot catch a root that fails to resolve at runtime,
# because nothing at the registration site can fail closed: a hook that is
# not found exits 127 and 127 does not block. The static check is the only
# instrument that can hold the class down, and it holds down the half that
# lives in the file.
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/check-hook-command-rooting.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CHECK="$SCRIPT_DIR/check-hook-command-rooting.sh"
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  # shellcheck source=.gaia/scripts/check-hook-command-rooting.sh
  source "$CHECK"
  FIXTURE_DIRS=()
}

teardown() {
  local d
  for d in "${FIXTURE_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  return 0
}

# fixture_with <command-json-array-of-strings> -> echoes a repo root whose
# .claude/settings.json registers exactly those commands, one hook each.
fixture_with() {
  local commands_json="$1" dir
  dir="$(mktemp -d)"
  FIXTURE_DIRS+=("$dir")
  mkdir -p "$dir/.claude"
  jq -n --argjson cmds "$commands_json" '{
    hooks: {
      PreToolUse: [ { matcher: "Bash",
                      hooks: [ $cmds[] | { type: "command", command: . } ] } ]
    }
  }' > "$dir/.claude/settings.json"
  printf '%s\n' "$dir"
}

@test "the sanctioned rooted form passes" {
  local root
  root="$(fixture_with '["\"$(git rev-parse --show-toplevel 2>/dev/null || printf %s \"${CLAUDE_PROJECT_DIR:-.}\")/.claude/hooks/block-rm-rf.sh\""]')"
  run gaia_check_hook_command_rooting "$root"
  [ "$status" -eq 0 ]
}

@test "a plain absolute path passes" {
  local root
  root="$(fixture_with '["/opt/gaia/.claude/hooks/block-rm-rf.sh"]')"
  run gaia_check_hook_command_rooting "$root"
  [ "$status" -eq 0 ]
}

@test "a bare repo-relative command is caught" {
  local root
  root="$(fixture_with '[".claude/hooks/block-rm-rf.sh"]')"
  run gaia_check_hook_command_rooting "$root"
  [ "$status" -ne 0 ]
  grep -qF -- "block-rm-rf.sh" <<<"$output"
}

@test "a repo-relative command behind an interpreter word is caught" {
  local root
  root="$(fixture_with '["bash .gaia/statusline/gaia-statusline.sh"]')"
  run gaia_check_hook_command_rooting "$root"
  [ "$status" -ne 0 ]
  grep -qF -- "gaia-statusline.sh" <<<"$output"
}

@test "one unrooted command among rooted ones is still caught" {
  local root
  root="$(fixture_with '["\"$(git rev-parse --show-toplevel)/.claude/hooks/a.sh\"", ".claude/hooks/b.sh", "/abs/.claude/hooks/c.sh"]')"
  run gaia_check_hook_command_rooting "$root"
  [ "$status" -ne 0 ]
  grep -qF -- "b.sh" <<<"$output"
  grep -qF -- "a.sh" <<<"$output" && return 1
  true
}

@test "an empty command set is reported as a failure, never as a pass" {
  local dir
  dir="$(mktemp -d)"
  FIXTURE_DIRS+=("$dir")
  mkdir -p "$dir/.claude"
  printf '%s\n' '{"hooks":{}}' > "$dir/.claude/settings.json"
  run gaia_check_hook_command_rooting "$dir"
  [ "$status" -ne 0 ]
}

@test "a missing settings.json is a usage failure, not a pass" {
  local dir
  dir="$(mktemp -d)"
  FIXTURE_DIRS+=("$dir")
  run gaia_check_hook_command_rooting "$dir"
  [ "$status" -ne 0 ]
}

# Coverage is per element: the set is derived from the artifact that owns
# it (.claude/settings.json) rather than restated here, every derived
# command is asserted, and a derivation that comes back short of what the
# file holds fails instead of silently driving a subset.
@test "real repo: every registered command in settings.json is rooted" {
  local settings derived_count file_count
  settings="$REPO_ROOT/.claude/settings.json"
  [ -f "$settings" ]

  # What the derivation found...
  derived_count="$(gaia_hook_command_rooting_commands "$settings" | grep -c .)"
  # ...against what the file actually holds, counted independently.
  file_count="$(jq '[(.hooks // {} | .[][].hooks[].command), (.statusLine.command // empty)] | length' "$settings")"

  [ "$derived_count" -eq "$file_count" ]
  [ "$derived_count" -gt 0 ]

  run gaia_check_hook_command_rooting "$REPO_ROOT"
  [ "$status" -eq 0 ]
}
