#!/usr/bin/env bats

# Tests for .claude/hooks/block-audit-loop-write.sh.
#
# The audit loop state directory (<main>/.gaia/local/audit-loop/) is written only
# by the audit loop hooks. This guard denies Claude's Edit / Write / MultiEdit
# calls that resolve into it (including through a linked worktree's `.gaia/local`
# symlink and a `..` segment) and Bash / Monitor commands that name it alongside
# a write, move or delete spelling, while allowing reads and the audit loop
# scripts, which never name `audit-loop/`.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  # HOOK_UNDER_TEST lets a mutation proof point the suite at a scratch copy.
  HOOK_ABS="${HOOK_UNDER_TEST:-$HOOKS_SRC/block-audit-loop-write.sh}"

  FIX=$(cd "$(mktemp -d "$BATS_TEST_TMPDIR/fix.XXXXXX")" && pwd -P)
  MAIN="$FIX/main"
  WT="$FIX/wt"
  mkdir -p "$MAIN"
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
  mkdir -p "$MAIN/.gaia/local/audit-loop/feat"
  git -C "$MAIN" worktree add -q "$WT" -b feat
  mkdir -p "$WT/.gaia"
  ln -s "$MAIN/.gaia/local" "$WT/.gaia/local"
  STATE="$MAIN/.gaia/local/audit-loop/feat/x.json"
  WSTATE="$WT/.gaia/local/audit-loop/feat/x.json"
}

edit_payload() {
  jq -n --arg t "$1" --arg p "$2" --arg c "$3" '{tool_name: $t, cwd: $c, tool_input: {file_path: $p}}'
}

cmd_payload() {
  jq -n --arg t "$1" --arg c "$2" --arg d "$3" '{tool_name: $t, cwd: $d, tool_input: {command: $c}}'
}

run_edit() {
  invoke_hook "$(edit_payload "$1" "$2" "${3:-$MAIN}")" "$HOOK_ABS"
}

run_bash() {
  invoke_hook "$(cmd_payload Bash "$1" "${2:-$MAIN}")" "$HOOK_ABS"
}

# --- denied: edit tools ---

@test "Write to the main state path is denied" {
  run_edit Write "$STATE"
  assert_denied_by_json
}

@test "Edit of the main state path is denied" {
  run_edit Edit "$STATE"
  assert_denied_by_json
}

@test "MultiEdit of the main state path is denied" {
  run_edit MultiEdit "$STATE"
  assert_denied_by_json
}

@test "Write through the worktree symlink spelling is denied" {
  run_edit Write "$WSTATE" "$WT"
  assert_denied_by_json
}

@test "Write through the worktree symlink with a .. segment is denied" {
  mkdir -p "$MAIN/.gaia/local/runs"
  run_edit Write "$WT/.gaia/local/runs/../audit-loop/feat/x.json" "$WT"
  assert_denied_by_json
}

@test "Write with a .. segment that resolves into the directory is denied" {
  run_edit Write "$MAIN/.gaia/local/runs/../audit-loop/feat/x.json"
  assert_denied_by_json
}

@test "Write to a not-yet-existing nested state path is denied" {
  run_edit Write "$MAIN/.gaia/local/audit-loop/new/branch/y.json"
  assert_denied_by_json
}

@test "Write to a relative path resolved against cwd is denied" {
  run_edit Write ".gaia/local/audit-loop/feat/x.json" "$MAIN"
  assert_denied_by_json
}

@test "Write elsewhere is allowed" {
  run_edit Write "$MAIN/.gaia/local/runs/feat/notes.json"
  assert_allowed_by_json
  [ -z "$output" ]
}

@test "Write to a sibling that merely shares the prefix is allowed" {
  run_edit Write "$MAIN/.gaia/local/audit-loop-notes/x.json"
  assert_allowed_by_json
}

# --- denied: Bash natural spellings ---

@test "Bash redirect into the state path is denied" {
  run_bash "printf '{}' > $STATE"
  assert_denied_by_json
}

@test "Bash append into the state path is denied" {
  run_bash "echo x >> $STATE"
  assert_denied_by_json
}

@test "Bash rm of the state path is denied" {
  run_bash "rm $STATE"
  assert_denied_by_json
}

@test "Bash rm -f of the state path is denied" {
  run_bash "rm -f $STATE"
  assert_denied_by_json
}

@test "Bash rm -rf of the directory itself (no trailing slash) is denied" {
  run_bash "rm -rf $MAIN/.gaia/local/audit-loop"
  assert_denied_by_json
}

@test "Bash mv of the state path is denied" {
  run_bash "mv $STATE /tmp/y"
  assert_denied_by_json
}

@test "Bash cp onto the state path is denied" {
  run_bash "cp /tmp/y $STATE"
  assert_denied_by_json
}

@test "Bash tee into the state path is denied" {
  run_bash "jq . /tmp/y | tee $STATE"
  assert_denied_by_json
}

@test "Bash sed -i on the state path is denied" {
  run_bash "sed -i '' 's/a/b/' $STATE"
  assert_denied_by_json
}

@test "Bash python3 -c writing the state path is denied" {
  run_bash "python3 -c \"open('$STATE','w')\""
  assert_denied_by_json
}

@test "Bash redirect through the worktree spelling is denied" {
  run_bash "printf '{}' > $WSTATE" "$WT"
  assert_denied_by_json
}

@test "Bash rm through the worktree spelling is denied" {
  run_bash "rm -f $WSTATE" "$WT"
  assert_denied_by_json
}

@test "Bash mv through the worktree spelling is denied" {
  run_bash "mv $WSTATE /tmp/y" "$WT"
  assert_denied_by_json
}

@test "Bash redirect with no space before the target is denied" {
  run_bash "echo x >$STATE"
  assert_denied_by_json
}

@test "Monitor with a deny-worthy command is denied" {
  invoke_hook "$(cmd_payload Monitor "rm -f $STATE" "$MAIN")" "$HOOK_ABS"
  assert_denied_by_json
}

@test "deny reason names the human recovery and the checkpoint page" {
  run_bash "rm $STATE"
  assert_denied_by_json
  grep -qF -- 'The branch checkpoint' <<<"$output"
  grep -qF -- 'outside Claude Code' <<<"$output"
}

# --- allowed ---

@test "Bash cat of the state path is allowed" {
  run_bash "cat $STATE"
  assert_allowed_by_json
}

@test "Bash jq read of the state path is allowed" {
  run_bash "jq '.history' $STATE"
  assert_allowed_by_json
}

@test "Bash ls of the directory is allowed" {
  run_bash "ls $MAIN/.gaia/local/audit-loop/"
  assert_allowed_by_json
}

@test "Bash read with stderr folded to stdout is allowed" {
  run_bash "cat $STATE 2>&1 | head -5"
  assert_allowed_by_json
}

@test "Bash read with output to /dev/null is allowed" {
  run_bash "cat $STATE > /dev/null"
  assert_allowed_by_json
}

@test "the evaluator script is allowed" {
  run_bash "bash .gaia/scripts/audit-loop-eval.sh brief --root /x"
  assert_allowed_by_json
}

@test "the record script is allowed" {
  run_bash "bash .gaia/scripts/audit-loop-record.sh --pr 1 --values-json -"
  assert_allowed_by_json
}

@test "an unrelated rm is allowed" {
  run_bash "rm /tmp/z"
  assert_allowed_by_json
}

@test "an unrelated redirect is allowed" {
  run_bash "echo x > /tmp/z"
  assert_allowed_by_json
}

@test "a non-Bash, non-edit tool is allowed" {
  invoke_hook "$(jq -n --arg p "$STATE" '{tool_name: "Read", tool_input: {file_path: $p}}')" "$HOOK_ABS"
  assert_allowed_by_json
}

# --- jq absent ---

# A fresh `bash -c` with a scrubbed PATH: under stock bash 3.2 a command-scoped
# PATH does not drop an already-hashed jq.
run_without_jq() {
  local payload="$1" bin="$FIX/nojq-bin" t
  mkdir -p "$bin"
  for t in bash cat dirname tr; do
    ln -sf "$(command -v "$t")" "$bin/$t"
  done
  run /bin/bash -c 'PATH="$1"; printf %s "$2" | /bin/bash "$3"' _ "$bin" "$payload" "$HOOK_ABS"
}

@test "jq absent: a Write to the state path is refused" {
  run_without_jq "$(edit_payload Write "$STATE" "$MAIN")"
  [ "$status" -eq 2 ]
  grep -qF -- 'BLOCKED' <<<"$output"
}

@test "jq absent: a command that rewrites the state path is refused" {
  run_without_jq "$(cmd_payload Bash "rm $STATE" "$MAIN")"
  [ "$status" -eq 2 ]
}

@test "jq absent: installing jq is allowed" {
  run_without_jq "$(cmd_payload Bash "brew install jq" "$MAIN")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
