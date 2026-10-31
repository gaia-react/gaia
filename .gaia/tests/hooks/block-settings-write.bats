#!/usr/bin/env bats

# Tests for .claude/hooks/block-settings-write.sh.
#
# `.claude/settings.json` registers every GAIA hook and permission rule. This
# guard asks the operator (never denies) when a Bash or Monitor command writes
# it through a redirect, tee, sponge, sed -i, or a cp/mv destination, and stays
# silent for reads, other files and the edit tools (a permissions.ask rule
# covers those). The decision is JSON on stdout carrying "ask" (mechanism 3 in
# helpers/run-hook.sh); the hook always exits 0 except when a library is
# missing.
#
# Run under bash 5: `bash .gaia/scripts/bats5.sh .gaia/tests/hooks/block-settings-write.bats`.
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  . "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/tests/helpers/path.sh"
  HOOKS_SOURCE_DIRECTORY=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABSOLUTE_PATH="$HOOKS_SOURCE_DIRECTORY/block-settings-write.sh"
  GUARDED_PATHS=(
    ".claude/settings.json"
    "./.claude/settings.json"
    "/Users/you/app/.claude/settings.json"
    "frontend/.claude/settings.json"
    ".claude/worktrees/w1/.claude/settings.json"
    "~/.claude/settings.json"
  )
  # Each shape holds the literal PATH, replaced by the guarded path.
  WRITE_SHAPES=(
    "sed -i 's/a/b/' PATH"
    "sed -i '' 's/a/b/' PATH"
    "echo '{}' > PATH"
    "echo '{}' >> PATH"
    "echo x | tee PATH"
    "echo x | tee -a PATH"
    "jq . x.json | sponge PATH"
    "cp /tmp/src.json PATH"
    "mv /tmp/src.json PATH"
    "jq '.a = 1' PATH > /tmp/tmp.json && mv /tmp/tmp.json PATH"
  )
}

run_hook_command() {
  local tool_name="$1" command_line="$2"
  local json
  json=$(jq -n --arg tool_name "$tool_name" --arg command "$command_line" '{tool_name: $tool_name, tool_input: {command: $command}}')
  invoke_hook "$json" "$HOOK_ABSOLUTE_PATH"
}

# Asserts the run is a well-formed ask carrying the full reason.
assert_settings_ask() {
  local needle
  [ "$status" -eq 0 ] || return 1
  jq -e -s 'length == 1' <<<"$output" >/dev/null || return 1
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"' <<<"$output" >/dev/null || return 1
  jq -e '.hookSpecificOutput.permissionDecision == "ask"' <<<"$output" >/dev/null || return 1
  for needle in '.claude/settings.json' 'asks on the target alone' 'Approve only a change you meant' 'do not retry this write by another route'; do
    jq -e --arg needle "$needle" '.hookSpecificOutput.permissionDecisionReason | contains($needle)' <<<"$output" >/dev/null || return 1
  done
}

# --- asks: the write matrix ---

@test "Bash and Monitor writes of a settings.json path ask, for every path and shape" {
  local tool_name guarded_path shape command_line
  for tool_name in Bash Monitor; do
    for guarded_path in "${GUARDED_PATHS[@]}"; do
      for shape in "${WRITE_SHAPES[@]}"; do
        command_line="${shape//PATH/$guarded_path}"
        run_hook_command "$tool_name" "$command_line"
        if ! assert_settings_ask; then
          printf 'did not ask: tool=%s path=%s shape=%s\n' "$tool_name" "$guarded_path" "$shape" >&2
          return 1
        fi
      done
    done
  done
}

@test "the manifest-write exemption marker does not exempt a settings write" {
  local tool_name
  for tool_name in Bash Monitor; do
    run_hook_command "$tool_name" "GAIA_MANIFEST_WRITE=1 cp /tmp/src.json .claude/settings.json"
    if ! assert_settings_ask; then
      printf 'did not ask: tool=%s\n' "$tool_name" >&2
      return 1
    fi
  done
}

@test "the guard never denies" {
  local tool_name guarded_path shape command_line
  for tool_name in Bash Monitor; do
    for guarded_path in "${GUARDED_PATHS[@]}"; do
      for shape in "${WRITE_SHAPES[@]}"; do
        command_line="${shape//PATH/$guarded_path}"
        run_hook_command "$tool_name" "$command_line"
        [ "$status" -eq 0 ] || return 1
        if grep -qF -- '"deny"' <<<"$output"; then
          printf 'denied: tool=%s path=%s shape=%s\n' "$tool_name" "$guarded_path" "$shape" >&2
          return 1
        fi
        grep -qF -- '"permissionDecision": "ask"' <<<"$output" || return 1
      done
    done
  done
}

# --- passes silently ---

@test "reads and writes to other files pass silently under Bash" {
  local command_line
  for command_line in \
    "cat .claude/settings.json" \
    "jq . .claude/settings.json" \
    "cp .claude/settings.json /tmp/x" \
    "cat .claude/settings.json | tee /tmp/x" \
    "sed -n p .claude/settings.json" \
    "echo x > frontend/package.json" \
    "echo x > .claude/settings.json.bak" \
    "sed -i s/a/b/ .claude/settings.local.json" \
    "cp a .claude/settings.local.json"; do
    run_hook_command Bash "$command_line"
    if [ "$status" -ne 0 ] || [ -n "$output" ]; then
      printf 'not silent: %s\n' "$command_line" >&2
      return 1
    fi
  done
}

@test "a read and an other-file write pass silently under Monitor" {
  local command_line
  for command_line in "cat .claude/settings.json" "echo x > .claude/settings.json.bak"; do
    run_hook_command Monitor "$command_line"
    [ "$status" -eq 0 ] || return 1
    [ -z "$output" ] || return 1
  done
}

@test "an Edit payload on settings.json passes silently; the ask rule covers the file tools" {
  local json
  json=$(jq -n '{tool_name: "Edit", tool_input: {file_path: ".claude/settings.json"}}')
  invoke_hook "$json" "$HOOK_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- fail loud: a missing library refuses rather than failing open ---

@test "a missing library makes the hook exit 2, one per library" {
  local library scratch json
  json=$(jq -n --arg command 'echo x > .claude/settings.json' '{tool_name: "Bash", tool_input: {command: $command}}')
  for library in jq-availability.sh hook-payload.sh bash-write-target.sh; do
    scratch="$BATS_TEST_TMPDIR/missing-${library%.sh}"
    mkdir -p "$scratch"
    cp -R "$HOOKS_SOURCE_DIRECTORY/lib" "$scratch/lib"
    cp "$HOOK_ABSOLUTE_PATH" "$scratch/block-settings-write.sh"
    rm "$scratch/lib/$library"
    invoke_hook "$json" "$scratch/block-settings-write.sh"
    if [ "$status" -ne 2 ] || ! grep -qF -- "cannot load lib/$library" <<<"$output"; then
      printf 'did not refuse loudly without %s (status %s)\n' "$library" "$status" >&2
      return 1
    fi
  done
}

# --- guard can fail ---

@test "a hook whose path rule is broken no longer asks, so the matrix can go red" {
  local scratch="$BATS_TEST_TMPDIR/broken-predicate"
  mkdir -p "$scratch"
  cp -R "$HOOKS_SOURCE_DIRECTORY/lib" "$scratch/lib"
  sed 's#== ".claude/settings.json" ||#== ".claude/no-such.json" ||#; s#\*/.claude/settings.json\]\]#*/.claude/no-such.json]]#' \
    "$HOOK_ABSOLUTE_PATH" >"$scratch/block-settings-write.sh"
  # The copy must differ from the original in its predicate, or this proves nothing.
  grep -qF -- 'no-such.json' "$scratch/block-settings-write.sh" || return 1
  local json
  json=$(jq -n --arg command 'echo x > .claude/settings.json' '{tool_name: "Bash", tool_input: {command: $command}}')
  invoke_hook "$json" "$scratch/block-settings-write.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- jq absent ---

without_jq() {
  export PATH
  PATH="$(path_shim_without jq)"
  [ -z "$(command -v jq)" ]
  invoke_hook "$1" "$HOOK_ABSOLUTE_PATH"
}

@test "jq absent: a settings write is refused with exit 2" {
  local json
  json=$(jq -n --arg command 'echo x > .claude/settings.json' '{tool_name: "Bash", tool_input: {command: $command}}')
  without_jq "$json"
  [ "$status" -eq 2 ]
}

@test "jq absent: a command naming no settings.json exits 0" {
  local json
  json=$(jq -n --arg command 'echo hello' '{tool_name: "Bash", tool_input: {command: $command}}')
  without_jq "$json"
  [ "$status" -eq 0 ]
}
