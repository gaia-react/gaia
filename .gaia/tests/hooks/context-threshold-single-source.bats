#!/usr/bin/env bats
#
# The context checkpoint line has one tracked source,
# .gaia/scripts/context-checkpoint-lib.sh, read by both the statusline's bar
# (red from the line) and the audit-loop bound hook's context gate. Two
# halves:
#
# - Behavioral: in a scratch copy of the scripts, the statusline and the hook,
#   change GAIA_CTX_ASK_TOKENS_DEFAULT once and assert that the statusline's
#   red boundary and the hook's context decision both move with it.
# - Textual: no other tracked shell file spells the line or the yellow anchor
#   as a whole word, with a red twin proving the same grep reports a plant.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/context-threshold-single-source.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/scripts/context-checkpoint-lib.sh"
  ORIGINAL_LINE="$GAIA_CTX_ASK_TOKENS_DEFAULT"
  ORIGINAL_YELLOW="$GAIA_CTX_YELLOW_TOKENS"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/audit-loop-fixture.sh"
  alf_init
  alf_branch feat/single-source
  SID=0a1b2c3d-1111-4222-8333-444455556666
  WINDOW=1000000
  STUB_BIN="$BATS_TEST_TMPDIR/stubbin"
  mkdir -p "$STUB_BIN"
  # gh with no pull request for any branch: the hook's fork check and PR
  # lookup both proceed.
  printf '#!/bin/bash\necho "no pull requests found for branch \\"x\\"" >&2\nexit 1\n' >"$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
  build_scratch
}

# build_scratch: a scratch install of the scripts, the statusline and the hook.
build_scratch() {
  SCRATCH="$BATS_TEST_TMPDIR/scratch"
  mkdir -p "$SCRATCH/.claude/hooks" "$SCRATCH/.gaia"
  cp -R "$REPO_ROOT/.gaia/scripts" "$SCRATCH/.gaia/scripts"
  cp -R "$REPO_ROOT/.gaia/statusline" "$SCRATCH/.gaia/statusline"
  cp "$REPO_ROOT/.claude/hooks/audit-loop-bound.sh" "$SCRATCH/.claude/hooks/"
  ln -sfn "$REPO_ROOT/.claude/hooks/lib" "$SCRATCH/.claude/hooks/lib"
}

# set_line <tokens>: change the default line in the scratch lib, exactly once.
set_line() {
  local library_path="$SCRATCH/.gaia/scripts/context-checkpoint-lib.sh"
  [ "$(grep -c '^GAIA_CTX_ASK_TOKENS_DEFAULT=' "$library_path")" -eq 1 ]
  sed "s/^GAIA_CTX_ASK_TOKENS_DEFAULT=.*/GAIA_CTX_ASK_TOKENS_DEFAULT=$1/" "$library_path" >"$library_path.new"
  mv "$library_path.new" "$library_path"
  grep -qx "GAIA_CTX_ASK_TOKENS_DEFAULT=$1" "$library_path"
}

# bar_is_red <tokens>: exit_status 0 when the scratch statusline colors the bar red, 1
# when it renders another color, 2 when it renders nothing.
bar_is_red() {
  local statusline_output escape_character=$'\033'
  statusline_output="$(bash -c '. "$1/.gaia/scripts/context-checkpoint-lib.sh" && . "$1/.gaia/statusline/left-side.sh" &&
    gaia_statusline_left "$2" "" false "" "" "$3" "$4" "$5" && printf "%s" "$_GAIA_SL_LEFT"' \
    _ "$SCRATCH" "$ALF_ROOT" "$(($1 * 100 / WINDOW))" "$WINDOW" "$1")" || return 2
  [ -n "$statusline_output" ] || return 2
  if [[ $statusline_output == *"${escape_character}[01;31m"* ]]; then return 0; fi
  return 1
}

# hook_denies <tokens>: exit_status 0 when the scratch hook denies a unit dispatch at
# that reading with a context checkpoint, 1 when it allows, 2 on any other
# deny; the branch state is reset first.
hook_denies() {
  local payload hook_output
  rm -rf "$ALF_ROOT/.gaia/local/audit-loop"
  gaia_ctx_write "$ALF_ROOT" "$SID" "$(($1 * 100 / WINDOW))" "$1" "$WINDOW" "$(date +%s)"
  payload="$(jq -n -c --arg s "$SID" --arg root "$ALF_ROOT" '{session_id: $s, tool_name: "Agent", cwd: $root,
    tool_input: {subagent_type: "audit-loop-unit", prompt: ("Run one audit unit.\nWorking root: " + $root)}}')"
  hook_output="$(printf '%s' "$payload" | env PATH="$STUB_BIN:$PATH" bash "$SCRATCH/.claude/hooks/audit-loop-bound.sh")"
  if [ -z "$hook_output" ]; then return 1; fi
  jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$hook_output" | grep -q '^BLOCKED: audit checkpoint .*(context)' ||
    { printf 'denied for another reason: %s\n' "$hook_output" >&2; return 2; }
}

@test "one change to the default line moves both the statusline red boundary and the hook's context decision" {
  local probe=$((ORIGINAL_LINE * 3 / 4)) exit_status
  exit_status=0
  bar_is_red "$probe" || exit_status=$?
  [ "$exit_status" -eq 1 ]
  exit_status=0
  hook_denies "$probe" || exit_status=$?
  [ "$exit_status" -eq 1 ]
  bar_is_red "$ORIGINAL_LINE"
  hook_denies "$ORIGINAL_LINE"
  set_line $((ORIGINAL_LINE / 2))
  bar_is_red "$probe"
  hook_denies "$probe"
}

@test "no tracked shell file other than the lib spells the line or the yellow anchor as a word" {
  local hits
  hits="$(git -C "$REPO_ROOT" grep -lwE "$ORIGINAL_LINE|$ORIGINAL_YELLOW" -- '*.sh' ':!*.bats' ':!*/fixtures/*')"
  [ "$hits" = ".gaia/scripts/context-checkpoint-lib.sh" ] || { printf 'unexpected files:\n%s\n' "$hits" >&2; return 1; }
}

@test "red twin: the same grep reports a value planted in a tracked shell file" {
  local sandbox="$BATS_TEST_TMPDIR/plant" hits
  mkdir -p "$sandbox/.gaia/scripts" "$sandbox/tools"
  git -C "$sandbox" init -q
  printf 'GAIA_CTX_ASK_TOKENS_DEFAULT=%s\n' "$ORIGINAL_LINE" >"$sandbox/.gaia/scripts/context-checkpoint-lib.sh"
  printf 'X=%s\n' "$ORIGINAL_LINE" >"$sandbox/tools/planted.sh"
  printf 'Y=%s1\n' "$ORIGINAL_LINE" >"$sandbox/tools/longer.sh"
  git -C "$sandbox" add -A
  hits="$(git -C "$sandbox" grep -lwE "$ORIGINAL_LINE|$ORIGINAL_YELLOW" -- '*.sh' ':!*.bats' ':!*/fixtures/*')"
  [ "$hits" = "$(printf '.gaia/scripts/context-checkpoint-lib.sh\ntools/planted.sh')" ] ||
    { printf 'unexpected hits:\n%s\n' "$hits" >&2; return 1; }
}
