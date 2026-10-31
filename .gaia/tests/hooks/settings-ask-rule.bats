#!/usr/bin/env bats

# Structural proxy for the runtime ask on a file-tool write of a
# `.claude/settings.json`. A bats run cannot exercise the runtime ask itself (a
# live permission probe needs Claude auth), so this suite pins what the ask
# rests on: the rule's presence and spelling, the absence of an allow rule that
# would shadow it, the settings-write guard's registration, and the generated
# package settings file a `frontend/` launch reads.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  SETTINGS="$REPO_ROOT/.claude/settings.json"
  GENERATED="$REPO_ROOT/frontend/.claude/settings.json"
  # shellcheck source=../../../.gaia/tests/helpers/hook-registration.sh
  . "$REPO_ROOT/.gaia/tests/helpers/hook-registration.sh"
}

# ask_rule_present FILE: succeeds when permissions.ask carries the rule.
ask_rule_present() {
  jq -e '.permissions.ask | index("Edit(**/.claude/settings.json)")' "$1" >/dev/null
}

# shadowing_allow_entries FILE: prints each allow entry that would shadow the
# ask rule and returns non-zero when there is one.
shadowing_allow_entries() {
  local offenders
  offenders=$(jq -r '
    ["Edit(**)", "Write(**)", "Edit(.claude/**)", "Write(.claude/**)",
     "Edit(/.claude/**)", "Write(/.claude/**)", "Edit(.claude/*)",
     "Write(.claude/*)", "Edit(.claude/settings.json)",
     "Write(.claude/settings.json)", "Edit(**/.claude/settings.json)",
     "Write(**/.claude/settings.json)"] as $bad
    | (.permissions.allow // [])[] | select(. as $e | $bad | index($e))' "$1")
  if [ -n "$offenders" ]; then
    printf '%s\n' "$offenders"
    return 1
  fi
  return 0
}

@test "root permissions.ask carries Edit(**/.claude/settings.json)" {
  ask_rule_present "$SETTINGS"
}

@test "no allow entry shadows the ask rule in the root or generated settings" {
  run shadowing_allow_entries "$SETTINGS"
  [ "$status" -eq 0 ]
  run shadowing_allow_entries "$GENERATED"
  [ "$status" -eq 0 ]
}

@test "the shadow check fails and names an Edit(.claude/**) allow entry" {
  jq '.permissions.allow += ["Edit(.claude/**)"]' "$SETTINGS" >"$BATS_TEST_TMPDIR/shadowed.json"
  run shadowing_allow_entries "$BATS_TEST_TMPDIR/shadowed.json"
  [ "$status" -ne 0 ]
  grep -qF -- "Edit(.claude/**)" <<<"$output"
}

@test "the ask-rule check fails when permissions.ask is deleted" {
  jq 'del(.permissions.ask)' "$SETTINGS" >"$BATS_TEST_TMPDIR/no-ask.json"
  run ask_rule_present "$BATS_TEST_TMPDIR/no-ask.json"
  [ "$status" -ne 0 ]
}

@test "the settings-write guard is registered on Bash|Monitor only" {
  hook_registered "$SETTINGS" '.hooks.PreToolUse[] | select(.matcher == "Bash|Monitor")' block-settings-write.sh
  run jq -e '[.hooks.PreToolUse[] | select(.matcher == "Edit|Write|MultiEdit") | .hooks[] | .command // empty] | any(contains("block-settings-write.sh"))' "$SETTINGS"
  [ "$status" -ne 0 ]
}

@test "the generated frontend settings carry the ask rule and the registration" {
  ask_rule_present "$GENERATED"
  hook_registered "$GENERATED" '.hooks.PreToolUse[] | select(.matcher == "Bash|Monitor")' block-settings-write.sh
}

# bats test_tags=whole-tree
@test "the committed tree passes the drift check" {
  run bash "$REPO_ROOT/.gaia/scripts/check-settings-drift.sh" "$REPO_ROOT"
  [ "$status" -eq 0 ]
}
