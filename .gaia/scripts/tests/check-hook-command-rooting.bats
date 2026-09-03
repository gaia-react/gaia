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
}

# Every fixture root below is created under $BATS_TEST_TMPDIR, which bats
# removes after each test. An earlier revision collected the roots in a
# FIXTURE_DIRS array for a teardown to delete, which cannot work: the helper
# is always called as `$(fixture_with ...)`, so its body runs in a subshell
# and the array the teardown read was always empty. Letting bats own the
# lifetime removes the class rather than repairing one instance of it.

# fixture_with <command-json-array-of-strings> -> echoes a repo root whose
# .claude/settings.json registers exactly those commands, one hook each.
fixture_with() {
  local commands_json="$1" dir
  dir="$(mktemp -d "$BATS_TEST_TMPDIR/fixture.XXXXXX")"
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

# Rule 1 alone passes both of these: the `.claude` in `./.claude/...` and in
# `x/../.claude/...` IS preceded by `/`. They are still relative, which is why
# the check carries a second rule rather than one pattern.
@test "a ./ prefixed command is caught even though its path follows a slash" {
  local root
  root="$(fixture_with '["./.claude/hooks/block-rm-rf.sh"]')"
  run gaia_check_hook_command_rooting "$root"
  [ "$status" -ne 0 ]
  grep -qF -- "block-rm-rf.sh" <<<"$output"
}

@test "a .. traversal is caught even though its path follows a slash" {
  local root
  root="$(fixture_with '["x/../.claude/hooks/block-rm-rf.sh"]')"
  run gaia_check_hook_command_rooting "$root"
  [ "$status" -ne 0 ]
  grep -qF -- "block-rm-rf.sh" <<<"$output"
}

# Rules 1 and 2 only ever look at `.claude/` and `.gaia/` occurrences, so on
# their own they pass a relative command in any other directory. These are the
# cases that make the check about anchoring rather than about two directory
# names, and the suite had none of them.
@test "a relative command outside .claude/ and .gaia/ is caught" {
  local root
  root="$(fixture_with '["tools/session-guard.sh"]')"
  run gaia_check_hook_command_rooting "$root"
  [ "$status" -ne 0 ]
  grep -qF -- "tools/session-guard.sh" <<<"$output"
}

@test "a bare relative script name with no directory at all is caught" {
  local root
  root="$(fixture_with '["hook.sh"]')"
  run gaia_check_hook_command_rooting "$root"
  [ "$status" -ne 0 ]
  grep -qF -- "hook.sh" <<<"$output"
}

# A tilde inside double quotes is NOT expanded by sh, so `"~/tools/hook.sh"`
# execs the literal path `~/tools/hook.sh` against the cwd. Verified by
# execution rather than reasoned about: a directory literally named `~` makes
# `sh -c '"~/hook.sh"'` run the script under it. The anchor list admitted this
# spelling and returned rc=0 with the verdict that every registered command
# resolves independently of cwd, which is the exact claim it falsifies.
@test "a double-quoted tilde is caught, because sh does not expand it" {
  local root
  root="$(fixture_with '["\"~/tools/hook.sh\""]')"
  run gaia_check_hook_command_rooting "$root"
  [ "$status" -ne 0 ]
  # shellcheck disable=SC2088 # "Tilde does not expand in quotes" is exactly
  # the property under test, so the warning is confirming the assertion.
  grep -qF -- "~/tools/hook.sh" <<<"$output"
}

# The bare spelling is the counterpart and must stay a pass: sh expands a
# leading unquoted `~` to $HOME, so the command names an absolute path.
@test "a bare unquoted tilde passes, because sh does expand it" {
  local root
  root="$(fixture_with '["~/tools/hook.sh"]')"
  run gaia_check_hook_command_rooting "$root"
  [ "$status" -eq 0 ]
}

@test "a command naming no path is not a finding" {
  local root
  root="$(fixture_with '["echo hi"]')"
  run gaia_check_hook_command_rooting "$root"
  [ "$status" -eq 0 ]
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
  dir="$(mktemp -d "$BATS_TEST_TMPDIR/fixture.XXXXXX")"
  mkdir -p "$dir/.claude"
  printf '%s\n' '{"hooks":{}}' > "$dir/.claude/settings.json"
  run gaia_check_hook_command_rooting "$dir"
  [ "$status" -ne 0 ]
}

@test "a missing settings.json is a usage failure, not a pass" {
  local dir
  dir="$(mktemp -d "$BATS_TEST_TMPDIR/fixture.XXXXXX")"
  run gaia_check_hook_command_rooting "$dir"
  [ "$status" -ne 0 ]
}

# Coverage is per element: the set is derived from the artifact that owns it
# (.claude/settings.json) rather than restated here, and every derived command
# is asserted.
#
# The cross-count below is narrower than it looks and the comment says so
# rather than overclaiming. Both sides build the array with the same jq
# expression, so what the pair establishes is that
# `gaia_hook_command_rooting_commands` has not drifted from the expression
# this suite pins, plus that no command is an empty string or carries an
# embedded newline. A registration shape the expression itself misses is
# invisible on BOTH sides and this pair cannot see it.
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

# The advisory note about .claude/settings.local.json is gated on that file
# actually registering hooks. The permissions-only shape is the common one
# (it is what Claude Code writes for per-machine permissions), so an
# existence-only gate would print a local hook layer into existence and send
# an operator hunting one. Both arms are pinned so a regression in either
# direction fails here rather than in someone's terminal.
@test "local settings note: printed when settings.local.json registers hooks" {
  local dir
  dir="$(fixture_with '["\"$(git rev-parse --show-toplevel)/.claude/hooks/a.sh\""]')"
  jq -n '{
    hooks: {
      PreToolUse: [ { matcher: "Bash",
                      hooks: [ { type: "command", command: ".claude/hooks/local.sh" } ] } ]
    }
  }' > "$dir/.claude/settings.local.json"

  run gaia_check_hook_command_rooting "$dir"
  [ "$status" -eq 0 ]
  case "$output" in
    *"settings.local.json also registers hooks"*) : ;;
    *) printf 'expected the local-registration note, got: %s\n' "$output" >&2; return 1 ;;
  esac
}

@test "local settings note: silent when settings.local.json registers no hooks" {
  local dir
  dir="$(fixture_with '["\"$(git rev-parse --show-toplevel)/.claude/hooks/a.sh\""]')"
  jq -n '{ permissions: { allow: ["Bash(ls:*)"] } }' \
    > "$dir/.claude/settings.local.json"

  run gaia_check_hook_command_rooting "$dir"
  [ "$status" -eq 0 ]
  case "$output" in
    *"settings.local.json also registers hooks"*)
      printf 'note printed for a permissions-only local file: %s\n' "$output" >&2
      return 1 ;;
    *) : ;;
  esac
}

@test "local settings note: silent when settings.local.json has an empty hooks event" {
  local dir
  dir="$(fixture_with '["\"$(git rev-parse --show-toplevel)/.claude/hooks/a.sh\""]')"
  # A `hooks` key that registers no command at all. Key presence alone would
  # print the note here, which is the sibling case the permissions-only test
  # does not reach.
  jq -n '{ hooks: { PreToolUse: [] } }' > "$dir/.claude/settings.local.json"

  run gaia_check_hook_command_rooting "$dir"
  [ "$status" -eq 0 ]
  case "$output" in
    *"settings.local.json also registers hooks"*)
      printf 'note printed for a hooks key registering no command: %s\n' "$output" >&2
      return 1 ;;
    *) : ;;
  esac
}
