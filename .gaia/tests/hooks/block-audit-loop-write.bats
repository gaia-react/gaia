#!/usr/bin/env bats

# Tests for .claude/hooks/block-audit-loop-write.sh.
#
# The protected folder (<main>/.gaia/local/protected/, holding the audit loop
# state and the checkpoint override) is written only by hooks and by a human.
# This guard denies Claude's Edit / Write / MultiEdit calls that resolve into it
# (including through a linked worktree's `.gaia/local` symlink and a `..`
# segment) and Bash / Monitor commands that redirect into it or name it
# alongside a write, move or delete verb, while allowing reads, quoted notes
# that mention it redirected elsewhere, and the audit loop scripts, which never
# name the folder. A path segment that merely ends in `audit-loop` (a worktree
# named like `spec-091-audit-loop`) or merely starts with `protected` does not
# arm it.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOKS_SOURCE_DIRECTORY=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  # HOOK_UNDER_TEST lets a mutation proof point the suite at a scratch copy.
  HOOK_ABSOLUTE_PATH="${HOOK_UNDER_TEST:-$HOOKS_SOURCE_DIRECTORY/block-audit-loop-write.sh}"

  FIX=$(cd "$(mktemp -d "$BATS_TEST_TMPDIR/fix.XXXXXX")" && pwd -P)
  MAIN="$FIX/main"
  WORKTREE="$FIX/wt"
  mkdir -p "$MAIN"
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
  mkdir -p "$MAIN/.gaia/local/protected/audit-loop/feat"
  git -C "$MAIN" worktree add -q "$WORKTREE" -b feat
  mkdir -p "$WORKTREE/.gaia"
  ln -s "$MAIN/.gaia/local" "$WORKTREE/.gaia/local"
  STATE="$MAIN/.gaia/local/protected/audit-loop/feat/x.json"
  WORKTREE_STATE="$WORKTREE/.gaia/local/protected/audit-loop/feat/x.json"
  NEW_STATE="$MAIN/.gaia/local/protected/new-state.json"
  WORKTREE_NEW_STATE="$WORKTREE/.gaia/local/protected/new-state.json"
  FOLDER="$MAIN/.gaia/local/protected"
  WORKTREE_FOLDER="$WORKTREE/.gaia/local/protected"
  OLD_STATE="$MAIN/.gaia/local/audit-loop/feat/x.json"
  OLD_OVERRIDE="$MAIN/.gaia/local/checkpoint-override.json"
  mkdir -p "$MAIN/.gaia/local/cache/shared/context"
  CONTEXT_FILE_NAME=0a1b2c3d-0000-4000-8000-000000000001.json
  CONTEXT_FILE="$MAIN/.gaia/local/cache/shared/context/$CONTEXT_FILE_NAME"
  WORKTREE_CONTEXT_FILE="$WORKTREE/.gaia/local/cache/shared/context/$CONTEXT_FILE_NAME"
  printf '{"version":1}' >"$CONTEXT_FILE"
  OVERRIDE="$MAIN/.gaia/local/protected/checkpoint-override.json"
  WORKTREE_OVERRIDE="$WORKTREE/.gaia/local/protected/checkpoint-override.json"
  ASK_RECORDER="$MAIN/.claude/hooks/audit-loop-ask-grant.sh"
  GRANT_RECORDER="$MAIN/.claude/hooks/audit-loop-grant.sh"
}

edit_payload() {
  jq -n --arg tool_name "$1" --arg file_path "$2" --arg cwd "$3" '{tool_name: $tool_name, cwd: $cwd, tool_input: {file_path: $file_path}}'
}

command_payload() {
  jq -n --arg tool_name "$1" --arg command "$2" --arg cwd "$3" '{tool_name: $tool_name, cwd: $cwd, tool_input: {command: $command}}'
}

run_edit() {
  invoke_hook "$(edit_payload "$1" "$2" "${3:-$MAIN}")" "$HOOK_ABSOLUTE_PATH"
}

run_bash() {
  invoke_hook "$(command_payload Bash "$1" "${2:-$MAIN}")" "$HOOK_ABSOLUTE_PATH"
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
  run_edit Write "$WORKTREE_STATE" "$WORKTREE"
  assert_denied_by_json
}

@test "Write through the worktree symlink with a .. segment is denied" {
  mkdir -p "$MAIN/.gaia/local/runs"
  run_edit Write "$WORKTREE/.gaia/local/runs/../protected/audit-loop/feat/x.json" "$WORKTREE"
  assert_denied_by_json
}

@test "Write with a .. segment that resolves into the directory is denied" {
  run_edit Write "$MAIN/.gaia/local/runs/../protected/audit-loop/feat/x.json"
  assert_denied_by_json
}

@test "Write to a not-yet-existing nested state path is denied" {
  run_edit Write "$MAIN/.gaia/local/protected/audit-loop/new/branch/y.json"
  assert_denied_by_json
}

@test "Write to a relative path resolved against cwd is denied" {
  run_edit Write ".gaia/local/protected/audit-loop/feat/x.json" "$MAIN"
  assert_denied_by_json
}

@test "Write elsewhere is allowed" {
  run_edit Write "$MAIN/.gaia/local/runs/feat/notes.json"
  assert_allowed_by_json
  [ -z "$output" ]
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
  run_bash "rm -rf $MAIN/.gaia/local/protected/audit-loop"
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
  run_bash "printf '{}' > $WORKTREE_STATE" "$WORKTREE"
  assert_denied_by_json
}

@test "Bash rm through the worktree spelling is denied" {
  run_bash "rm -f $WORKTREE_STATE" "$WORKTREE"
  assert_denied_by_json
}

@test "Bash mv through the worktree spelling is denied" {
  run_bash "mv $WORKTREE_STATE /tmp/y" "$WORKTREE"
  assert_denied_by_json
}

@test "Bash redirect with no space before the target is denied" {
  run_bash "echo x >$STATE"
  assert_denied_by_json
}

@test "Monitor with a deny-worthy command is denied" {
  invoke_hook "$(command_payload Monitor "rm -f $STATE" "$MAIN")" "$HOOK_ABSOLUTE_PATH"
  assert_denied_by_json
}

@test "deny reason names the human recovery and the checkpoint page" {
  run_bash "rm $STATE"
  assert_denied_by_json
  grep -qF -- 'The branch checkpoint' <<<"$output"
  grep -qF -- 'outside Claude Code' <<<"$output"
}

# --- redirect target, not redirect anywhere ---

# A note that quotes a guarded path as text and is redirected elsewhere is the
# shape an audit member stages a findings sidecar with.
@test "printf of quoted text naming each guarded path, redirected to a /tmp file, is allowed" {
  local checked=0 guarded_path
  for guarded_path in "$STATE" "$CONTEXT_FILE" "$OVERRIDE" "$NEW_STATE"; do
    run_bash "printf '%s\n' 'the hook trusts $guarded_path as written' > $BATS_TEST_TMPDIR/note.txt"
    assert_allowed_by_json
    [ -z "$output" ]
    checked=$((checked + 1))
  done
  [ "$checked" -eq 4 ]
}

@test "a double-quoted note naming the state path with a write verb as text, redirected to /tmp, is allowed" {
  run_bash "printf '%s\n' \"never rm or mv $STATE by hand\" >> $BATS_TEST_TMPDIR/note.txt"
  assert_allowed_by_json
  [ -z "$output" ]
}

@test "Bash redirect into the quoted state path is denied" {
  run_bash "printf '{}' > \"$STATE\""
  assert_denied_by_json
}

@test "Bash redirect into the state path after a quoted note is denied" {
  run_bash "printf '%s' 'a > b' > $STATE"
  assert_denied_by_json
}

@test "Bash write inside a quoted command substitution is denied" {
  run_bash "x=\"\$(printf '{}' > $STATE)\""
  assert_denied_by_json
}

@test "Bash write after a heredoc whose body has an apostrophe is denied" {
  run_bash "cat <<EOF > $BATS_TEST_TMPDIR/n
don't
EOF
echo x > $STATE"
  assert_denied_by_json
}

# An apostrophe in a comment is not a quote: read as one it would swallow the
# write between two comments.
@test "Bash rm of the state path between two comments with apostrophes is denied" {
  run_bash "echo hi # don't
rm $STATE # it's gone"
  assert_denied_by_json
}

@test "Bash rm -f of the state path after a comment line with an apostrophe is denied" {
  run_bash "# don't do this lightly
rm -f $STATE
# it's fine now"
  assert_denied_by_json
}

@test "Bash redirect into the state path between comment lines with apostrophes is denied" {
  run_bash "# don't do this lightly
echo '{}' > $STATE
# it's fine now"
  assert_denied_by_json
}

# A redirect target built from a variable or a glob can land on the path the
# command names elsewhere.
@test "Bash redirect into a variable holding the state directory is denied" {
  run_bash "D=$MAIN/.gaia/local/protected/audit-loop/feat; echo x > \"\$D/x.json\""
  assert_denied_by_json
}

@test "Bash redirect in a loop over a glob of the state directory is denied" {
  run_bash "for f in $MAIN/.gaia/local/protected/audit-loop/feat/*.json; do echo '{}' > \"\$f\"; done"
  assert_denied_by_json
}

@test "the Bash deny text names the trigger and an allowed spelling" {
  run_bash "echo x > $STATE"
  assert_denied_by_json
  grep -qF -- 'redirects into it' <<<"$output"
  grep -qF -- 'only as quoted text' <<<"$output"
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
  run_bash "ls $MAIN/.gaia/local/protected/audit-loop/"
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

@test "rm of a file under a worktree whose name ends in audit-loop is allowed" {
  run_bash "rm -f $FIX/spec-091-audit-loop/notes.txt"
  assert_allowed_by_json
}

@test "a redirect into a worktree whose name ends in audit-loop is allowed" {
  run_bash "echo x > $FIX/spec-091-audit-loop/app/file.ts"
  assert_allowed_by_json
}

@test "the state path inside a worktree named like audit-loop is still denied" {
  run_bash "rm -f $FIX/spec-091-audit-loop/.gaia/local/protected/audit-loop/feat/x.json"
  assert_denied_by_json
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
  invoke_hook "$(jq -n --arg file_path "$STATE" '{tool_name: "Read", tool_input: {file_path: $file_path}}')" "$HOOK_ABSOLUTE_PATH"
  assert_allowed_by_json
}

# --- jq absent ---

# A fresh `bash -c` with a scrubbed PATH: under stock bash 3.2 a command-scoped
# PATH does not drop an already-hashed jq.
run_without_jq() {
  local payload="$1" hook="${2:-$HOOK_ABSOLUTE_PATH}" bin="$FIX/nojq-bin" tool_name
  mkdir -p "$bin"
  for tool_name in bash cat dirname tr; do
    ln -sf "$(command -v "$tool_name")" "$bin/$tool_name"
  done
  run /bin/bash -c 'PATH="$1"; printf %s "$2" | /bin/bash "$3"' _ "$bin" "$payload" "$hook"
}

@test "jq absent: a Write to the state path is refused" {
  run_without_jq "$(edit_payload Write "$STATE" "$MAIN")"
  [ "$status" -eq 2 ]
  grep -qF -- 'BLOCKED' <<<"$output"
}

@test "jq absent: a command that rewrites the state path is refused" {
  run_without_jq "$(command_payload Bash "rm $STATE" "$MAIN")"
  [ "$status" -eq 2 ]
}

@test "jq absent: installing jq is allowed" {
  run_without_jq "$(command_payload Bash "brew install jq" "$MAIN")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- gate inputs: context readings, override, recorder execution ---

# Every deny names the guard and carries both answer channels; the class
# fragment tells the four messages apart.
assert_denied_class() {
  assert_denied_by_json
  grep -qF -- 'block-audit-loop-write.sh' <<<"$output"
  grep -qF -- 'AskUserQuestion' <<<"$output"
  grep -qF -- 'audit-grant' <<<"$output"
  grep -qF -- "$1" <<<"$output"
}

run_monitor() {
  invoke_hook "$(command_payload Monitor "$1" "${2:-$MAIN}")" "$HOOK_ABSOLUTE_PATH"
}

# scratch_hook <sed-script>: write a mutated copy of the hook under test into a
# scratch tree that still resolves its library and main-root lib, print its
# path, and fail when the mutation changed nothing (a twin that mutates no line
# proves nothing).
scratch_hook() {
  local root="$BATS_TEST_TMPDIR/scratch-hook"
  mkdir -p "$root/.claude/hooks" "$root/.gaia"
  ln -sfn "$HOOKS_SOURCE_DIRECTORY/lib" "$root/.claude/hooks/lib"
  ln -sfn "$HOOKS_SOURCE_DIRECTORY/../../.gaia/scripts" "$root/.gaia/scripts"
  sed -E "$1" "$HOOK_ABSOLUTE_PATH" >"$root/.claude/hooks/block-audit-loop-write.sh"
  if cmp -s "$HOOK_ABSOLUTE_PATH" "$root/.claude/hooks/block-audit-loop-write.sh"; then
    return 1
  fi
  printf '%s' "$root/.claude/hooks/block-audit-loop-write.sh"
}

# --- context readings: edit tools ---

@test "Write to a context file is denied naming the guard" {
  run_edit Write "$CONTEXT_FILE"
  assert_denied_class 'context readings'
}

@test "Edit of a context file is denied" {
  run_edit Edit "$CONTEXT_FILE"
  assert_denied_class 'context readings'
}

@test "Write to a not-yet-existing context file is denied" {
  run_edit Write "$MAIN/.gaia/local/cache/shared/context/0a1b2c3d-0000-4000-8000-000000000002.json"
  assert_denied_class 'context readings'
}

@test "Write to a context file through the worktree symlink spelling is denied" {
  run_edit Write "$WORKTREE_CONTEXT_FILE" "$WORKTREE"
  assert_denied_class 'context readings'
}

@test "Edit of a context file through the worktree symlink spelling is denied" {
  run_edit Edit "$WORKTREE_CONTEXT_FILE" "$WORKTREE"
  assert_denied_class 'context readings'
}

@test "Write to a context file with a .. segment is denied" {
  run_edit Write "$MAIN/.gaia/local/cache/../cache/shared/context/$CONTEXT_FILE_NAME"
  assert_denied_class 'context readings'
}

# --- context readings: Bash natural spellings ---

@test "Bash redirect into a context file is denied" {
  run_bash "printf x > $CONTEXT_FILE"
  assert_denied_class 'context readings'
}

@test "Bash mv of a context file is denied" {
  run_bash "mv $CONTEXT_FILE /tmp/x"
  assert_denied_class 'context readings'
}

@test "Bash rm -f of a context file is denied" {
  run_bash "rm -f $CONTEXT_FILE"
  assert_denied_class 'context readings'
}

@test "Bash rm of the context directory itself is denied" {
  run_bash "rm -rf $MAIN/.gaia/local/cache/shared/context"
  assert_denied_class 'context readings'
}

@test "Bash redirect into a context file through the worktree spelling is denied" {
  run_bash "printf x > $WORKTREE_CONTEXT_FILE" "$WORKTREE"
  assert_denied_class 'context readings'
}

@test "Bash mv of a context file through the worktree spelling is denied" {
  run_bash "mv $WORKTREE_CONTEXT_FILE /tmp/x" "$WORKTREE"
  assert_denied_class 'context readings'
}

@test "Bash rm -f of a context file through the worktree spelling is denied" {
  run_bash "rm -f $WORKTREE_CONTEXT_FILE" "$WORKTREE"
  assert_denied_class 'context readings'
}

@test "Monitor writing a context file is denied" {
  run_monitor "rm -f $CONTEXT_FILE"
  assert_denied_class 'context readings'
}

@test "Bash cat of a context file is allowed" {
  run_bash "cat $CONTEXT_FILE"
  assert_allowed_by_json
  [ -z "$output" ]
}

@test "Bash jq read of a context file is allowed" {
  run_bash "jq . $CONTEXT_FILE"
  assert_allowed_by_json
  [ -z "$output" ]
}

@test "Write to a sibling cache file is allowed" {
  run_edit Write "$MAIN/.gaia/local/cache/shared/update-check.json"
  assert_allowed_by_json
  [ -z "$output" ]
}

@test "a process outside the tool path still writes a context file" {
  run bash -c 'printf "{\"version\":1,\"n\":2}" > "$1.tmp" && mv "$1.tmp" "$1"' _ "$CONTEXT_FILE"
  [ "$status" -eq 0 ]
  grep -qF -- '"n":2' "$CONTEXT_FILE"
}

# --- override file: edit tools and Bash ---

@test "Write creating the override file is denied with the human-only message" {
  [ ! -e "$OVERRIDE" ]
  run_edit Write "$OVERRIDE"
  assert_denied_class 'only a human edits the override'
}

@test "Edit of the override file is denied" {
  printf '{}' >"$OVERRIDE"
  run_edit Edit "$OVERRIDE"
  assert_denied_class 'only a human edits the override'
}

@test "Write creating the override file through the worktree spelling is denied" {
  run_edit Write "$WORKTREE_OVERRIDE" "$WORKTREE"
  assert_denied_class 'only a human edits the override'
}

@test "Bash redirect creating the override file is denied" {
  run_bash "echo '{}' > $OVERRIDE"
  assert_denied_class 'only a human edits the override'
}

@test "Bash redirect creating the override file through the worktree spelling is denied" {
  run_bash "echo '{}' > $WORKTREE_OVERRIDE" "$WORKTREE"
  assert_denied_class 'only a human edits the override'
}

@test "Bash rm of the override file is denied" {
  run_bash "rm -f $OVERRIDE"
  assert_denied_class 'only a human edits the override'
}

@test "Bash mv onto the override file is denied" {
  run_bash "mv /tmp/s.json $OVERRIDE"
  assert_denied_class 'only a human edits the override'
}

@test "Monitor creating the override file is denied" {
  run_monitor "echo '{}' > $OVERRIDE"
  assert_denied_class 'only a human edits the override'
}

@test "Bash cat of the override file is allowed" {
  printf '{}' >"$OVERRIDE"
  run_bash "cat $OVERRIDE"
  assert_allowed_by_json
  [ -z "$output" ]
}

@test "Bash jq read of the override file is allowed" {
  printf '{}' >"$OVERRIDE"
  run_bash "jq . $OVERRIDE"
  assert_allowed_by_json
  [ -z "$output" ]
}

@test "Write to .claude/settings.json is allowed" {
  run_edit Write "$MAIN/.claude/settings.json"
  assert_allowed_by_json
  [ -z "$output" ]
}

@test "Write to .claude/settings.local.json is allowed" {
  run_edit Write "$MAIN/.claude/settings.local.json"
  assert_allowed_by_json
  [ -z "$output" ]
}

@test "Bash redirect into .claude/settings.json is allowed" {
  run_bash "echo '{}' > $MAIN/.claude/settings.json"
  assert_allowed_by_json
  [ -z "$output" ]
}

# .gaia/local/settings.json holds GAIA's per-machine opt-ins (the statusline
# left-side choice), which /setup-gaia writes, so the guard must not match it.
@test "Write to the opt-ins file .gaia/local/settings.json is allowed" {
  run_edit Write "$MAIN/.gaia/local/settings.json"
  assert_allowed_by_json
  [ -z "$output" ]
}

@test "Write to the opt-ins file through the worktree spelling is allowed" {
  run_edit Write "$WORKTREE/.gaia/local/settings.json" "$WORKTREE"
  assert_allowed_by_json
  [ -z "$output" ]
}

@test "Bash redirect into the opt-ins file .gaia/local/settings.json is allowed" {
  run_bash "echo '{}' > $MAIN/.gaia/local/settings.json"
  assert_allowed_by_json
  [ -z "$output" ]
}

# --- recorder execution ---

# Each execution form is denied before it runs, and the state is untouched.
assert_recorder_denied() {
  cp "$STATE" "$BATS_TEST_TMPDIR/state.before"
  run_bash "$1"
  assert_denied_class 'run only as hooks'
  cmp "$STATE" "$BATS_TEST_TMPDIR/state.before"
}

@test "a forged payload piped to the ask recorder through bash is denied" {
  printf '{"seed":1}' >"$STATE"
  assert_recorder_denied "printf '%s' '{\"tool_name\":\"AskUserQuestion\"}' | bash $ASK_RECORDER"
}

@test "a forged payload piped to the ask recorder as the command word is denied" {
  printf '{"seed":1}' >"$STATE"
  assert_recorder_denied "printf x | $ASK_RECORDER"
}

@test "bash running the grant recorder with a payload redirect is denied" {
  printf '{"seed":1}' >"$STATE"
  assert_recorder_denied "bash .claude/hooks/audit-loop-grant.sh < payload.json"
}

@test "the grant recorder as the command word with a payload redirect is denied" {
  printf '{"seed":1}' >"$STATE"
  assert_recorder_denied ".claude/hooks/audit-loop-grant.sh < payload.json"
}

@test "sourcing the grant recorder is denied" {
  printf '{"seed":1}' >"$STATE"
  assert_recorder_denied "source .claude/hooks/audit-loop-grant.sh"
}

@test "dot-sourcing the grant recorder is denied" {
  printf '{"seed":1}' >"$STATE"
  assert_recorder_denied ". .claude/hooks/audit-loop-grant.sh"
}

@test "sh running the grant recorder after && is denied" {
  printf '{"seed":1}' >"$STATE"
  assert_recorder_denied "true && sh $GRANT_RECORDER"
}

@test "exec of the ask recorder is denied" {
  printf '{"seed":1}' >"$STATE"
  assert_recorder_denied "exec $ASK_RECORDER"
}

@test "bash with flags running the grant recorder is denied" {
  printf '{"seed":1}' >"$STATE"
  assert_recorder_denied "bash -eu -o pipefail $GRANT_RECORDER"
}

@test "a quoted recorder path with an env prefix is denied" {
  printf '{"seed":1}' >"$STATE"
  assert_recorder_denied "FOO=1 \"$ASK_RECORDER\" < /dev/null"
}

@test "the recorder after a newline is denied" {
  printf '{"seed":1}' >"$STATE"
  assert_recorder_denied "echo hi
bash $GRANT_RECORDER"
}

# A checkout path with a space: the quoted recorder path is one shell word, so
# splitting before the quotes are read would hand the guard `.../My` instead.
@test "bash running the quoted grant recorder under a spaced checkout path is denied" {
  printf '{"seed":1}' >"$STATE"
  assert_recorder_denied "bash \"$FIX/My Repo/.claude/hooks/audit-loop-grant.sh\" < p.json"
}

@test "the quoted grant recorder under a spaced checkout path as the command word is denied" {
  printf '{"seed":1}' >"$STATE"
  assert_recorder_denied "\"$FIX/My Repo/.claude/hooks/audit-loop-grant.sh\" < p.json"
}

@test "bash running the quoted ask recorder under a spaced checkout path is denied" {
  printf '{"seed":1}' >"$STATE"
  assert_recorder_denied "bash \"$FIX/My Repo/.claude/hooks/audit-loop-ask-grant.sh\" < p.json"
}

@test "the quoted ask recorder under a spaced checkout path as the command word is denied" {
  printf '{"seed":1}' >"$STATE"
  assert_recorder_denied "\"$FIX/My Repo/.claude/hooks/audit-loop-ask-grant.sh\" < p.json"
}

@test "git add of the quoted recorder under a spaced checkout path is allowed" {
  run_bash "git -C \"$FIX/My Repo\" add -- \"$FIX/My Repo/.claude/hooks/audit-loop-grant.sh\""
  assert_allowed_by_json
  [ -z "$output" ]
}

@test "Monitor piping a forged payload to the ask recorder is denied" {
  run_monitor "printf '%s' '{}' | bash $ASK_RECORDER"
  assert_denied_class 'run only as hooks'
}

@test "Monitor running the grant recorder with a payload redirect is denied" {
  run_monitor "bash .claude/hooks/audit-loop-grant.sh < payload.json"
  assert_denied_class 'run only as hooks'
}

@test "git add naming the grant recorder is allowed" {
  run_bash "git -C $MAIN add -- .claude/hooks/audit-loop-grant.sh"
  assert_allowed_by_json
  [ -z "$output" ]
}

@test "git add naming the ask recorder is allowed" {
  run_bash "git -C $MAIN add -- .claude/hooks/audit-loop-ask-grant.sh"
  assert_allowed_by_json
  [ -z "$output" ]
}

@test "git diff naming the grant recorder is allowed" {
  run_bash "git -C $MAIN diff -- .claude/hooks/audit-loop-grant.sh"
  assert_allowed_by_json
  [ -z "$output" ]
}

@test "git grep -l naming the grant recorder is allowed" {
  run_bash "git -C $MAIN grep -l 'audit-loop-grant.sh' -- '*.bats'"
  assert_allowed_by_json
  [ -z "$output" ]
}

@test "git log naming the ask recorder is allowed" {
  run_bash "git -C $MAIN log --oneline -- .claude/hooks/audit-loop-ask-grant.sh"
  assert_allowed_by_json
  [ -z "$output" ]
}

@test "shellcheck of the ask recorder is allowed" {
  run_bash "shellcheck .claude/hooks/audit-loop-ask-grant.sh"
  assert_allowed_by_json
  [ -z "$output" ]
}

@test "bash -n of the grant recorder is allowed" {
  run_bash "bash -n .claude/hooks/audit-loop-grant.sh"
  assert_allowed_by_json
  [ -z "$output" ]
}

@test "cat of the grant recorder is allowed" {
  run_bash "cat .claude/hooks/audit-loop-grant.sh"
  assert_allowed_by_json
  [ -z "$output" ]
}

@test "grep for the recorder name is allowed" {
  run_bash "grep -n audit-loop-ask-grant.sh .claude/settings.json"
  assert_allowed_by_json
  [ -z "$output" ]
}

@test "a Bash command naming a worktree directory called spec-093-audit-loop-unit is allowed" {
  run_bash "git -C $FIX/spec-093-audit-loop-unit status --short"
  assert_allowed_by_json
  [ -z "$output" ]
}

# --- deny text, every class ---

@test "the deny text of every class carries both answer channels and names the guard" {
  local checked=0 payload
  for payload in \
    "$(edit_payload Write "$STATE" "$MAIN")" \
    "$(edit_payload Write "$CONTEXT_FILE" "$MAIN")" \
    "$(edit_payload Write "$OVERRIDE" "$MAIN")" \
    "$(edit_payload Write "$NEW_STATE" "$MAIN")" \
    "$(command_payload Bash "bash $ASK_RECORDER" "$MAIN")"; do
    invoke_hook "$payload" "$HOOK_ABSOLUTE_PATH"
    assert_denied_by_json
    grep -qF -- 'block-audit-loop-write.sh' <<<"$output"
    grep -qF -- 'AskUserQuestion' <<<"$output"
    grep -qF -- 'audit-grant' <<<"$output"
    checked=$((checked + 1))
  done
  [ "$checked" -eq 5 ]
}

# --- red twins: the new arms are what deny ---

@test "red twin: without the execution rule a piped forgery to the recorder is allowed" {
  local twin
  twin=$(scratch_hook '/^    runs_recorder "\$command_line" && deny recorder$/d')
  invoke_hook "$(command_payload Bash "printf x | bash $ASK_RECORDER" "$MAIN")" "$twin"
  assert_allowed_by_json
  # The unmutated hook denies the same payload.
  run_bash "printf x | bash $ASK_RECORDER"
  assert_denied_by_json
}

@test "red twin: a rule widened to any command naming the recorder denies git add" {
  local twin
  twin=$(scratch_hook 's/^    runs_recorder "\$command_line" && deny recorder$/    case "$command_line" in *audit-loop-grant.sh* | *audit-loop-ask-grant.sh*) deny recorder ;; esac/')
  invoke_hook "$(command_payload Bash "git -C $MAIN add -- .claude/hooks/audit-loop-grant.sh" "$MAIN")" "$twin"
  assert_denied_by_json
  # The unmutated hook allows the same payload.
  run_bash "git -C $MAIN add -- .claude/hooks/audit-loop-grant.sh"
  assert_allowed_by_json
}

@test "red twin: without the widened pre-filter a context redirect and an override redirect are allowed" {
  local twin
  twin=$(scratch_hook 's/^  \*audit-loop\* \| \*local\/protected\* \| \*cache\/shared\/context\*\) ;;$/  *audit-loop*) ;;/')
  invoke_hook "$(command_payload Bash "printf x > $CONTEXT_FILE" "$MAIN")" "$twin"
  assert_allowed_by_json
  invoke_hook "$(command_payload Bash "echo '{}' > $OVERRIDE" "$MAIN")" "$twin"
  assert_allowed_by_json
  # The unmutated hook denies both.
  run_bash "printf x > $CONTEXT_FILE"
  assert_denied_by_json
  run_bash "echo '{}' > $OVERRIDE"
  assert_denied_by_json
}

# --- jq absent, new spellings ---

@test "jq absent: a Write to a context file is refused" {
  run_without_jq "$(edit_payload Write "$CONTEXT_FILE" "$MAIN")"
  [ "$status" -eq 2 ]
}

@test "jq absent: a command that rewrites the override file is refused" {
  run_without_jq "$(command_payload Bash "echo '{}' > $OVERRIDE" "$MAIN")"
  [ "$status" -eq 2 ]
}

# --- the protected folder as a whole ---

# cell_is_denied <label>: the last invoke_hook run is a deny whose reason names
# the guard; a failing cell prints its label.
cell_is_denied() {
  local reason
  [ "$status" -eq 0 ] || {
    printf 'cell %s: status %s\n' "$1" "$status" >&2
    return 1
  }
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" || {
    printf 'cell %s: not denied: %s\n' "$1" "$output" >&2
    return 1
  }
  reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")
  case "$reason" in
    'BLOCKED: block-audit-loop-write.sh:'*) ;;
    *)
      printf 'cell %s: reason does not start with the guard name: %s\n' "$1" "$reason" >&2
      return 1
      ;;
  esac
}

# cell_is_allowed <label>: the last run allowed with no output.
cell_is_allowed() {
  [ "$status" -eq 0 ] || {
    printf 'cell %s: status %s\n' "$1" "$status" >&2
    return 1
  }
  [ -z "$output" ] || {
    printf 'cell %s: expected silence, got: %s\n' "$1" "$output" >&2
    return 1
  }
}

# class_pin <class>: the substring only that class's message carries.
class_pin() {
  case "$1" in
    state) printf '%s' 'the audit loop state (<main>/.gaia/local/protected/audit-loop/)' ;;
    override) printf '%s' 'only a human edits the override' ;;
    folder) printf '%s' 'only hooks or a human write <main>/.gaia/local/protected/' ;;
    context) printf '%s' 'the context readings (<main>/.gaia/local/cache/shared/context/)' ;;
    recorder) printf '%s' 'run only as hooks' ;;
  esac
}

# assert_pins_only_class <class>: the last run is a deny carrying that class's
# pin and none of the other four classes' pins.
assert_pins_only_class() {
  local expected_class="$1" other_class
  assert_denied_by_json
  grep -qF -- "$(class_pin "$expected_class")" <<<"$output" || {
    printf 'class %s: its pin is missing from: %s\n' "$expected_class" "$output" >&2
    return 1
  }
  for other_class in state override folder context recorder; do
    if [ "$other_class" != "$expected_class" ]; then
      if grep -qF -- "$(class_pin "$other_class")" <<<"$output"; then
        printf 'class %s: carries the %s pin: %s\n' "$expected_class" "$other_class" "$output" >&2
        return 1
      fi
    fi
  done
  return 0
}

@test "Edit, Write and MultiEdit into the protected folder are denied in every spelling" {
  local tool cell cell_path cell_cwd cells=0
  local -a spellings=(
    "$STATE|$MAIN" "$OVERRIDE|$MAIN" "$NEW_STATE|$MAIN"
    "$WORKTREE_STATE|$WORKTREE" "$WORKTREE_OVERRIDE|$WORKTREE" "$WORKTREE_NEW_STATE|$WORKTREE"
  )
  for tool in Edit Write MultiEdit; do
    for cell in "${spellings[@]}"; do
      cell_path="${cell%%|*}"
      cell_cwd="${cell#*|}"
      run_edit "$tool" "$cell_path" "$cell_cwd"
      cell_is_denied "$tool $cell_path"
      cells=$((cells + 1))
    done
  done
  [ "${#spellings[@]}" -eq 6 ]
  [ "$cells" -eq 18 ]
}

@test "Write to a relative path into the protected folder is denied" {
  run_edit Write ".gaia/local/protected/new-state.json" "$MAIN"
  assert_pins_only_class folder
}

@test "Write with a .. segment that resolves into the protected folder is denied" {
  mkdir -p "$MAIN/.gaia/local/runs"
  run_edit Write "$MAIN/.gaia/local/runs/../protected/audit-loop/feat/x.json"
  assert_pins_only_class state
}

@test "Write through the worktree symlink with a .. segment into the protected folder is denied" {
  mkdir -p "$MAIN/.gaia/local/runs"
  run_edit Write "$WORKTREE/.gaia/local/runs/../protected/audit-loop/feat/x.json" "$WORKTREE"
  assert_pins_only_class state
}

@test "Write through a symlink alias to the protected folder that never names it is denied" {
  ln -s "$FOLDER" "$FIX/vault"
  run_edit Write "$FIX/vault/audit-loop/feat/x.json"
  assert_pins_only_class state
}

@test "Write through a symlink alias to the local directory is denied with the folder message" {
  ln -s "$MAIN/.gaia/local" "$FIX/alias-local"
  run_edit Write "$FIX/alias-local/protected/new-state.json"
  assert_pins_only_class folder
}

# The tool-spelling matrix for Bash and Monitor: every target through every
# write shape.
assert_write_matrix() {
  local runner="$1" cell target cwd shape command_line cells=0
  local -a targets=(
    "$MAIN/.gaia/local/protected/audit-loop/x.json|$MAIN" "$OVERRIDE|$MAIN" "$NEW_STATE|$MAIN" "$FOLDER|$MAIN" "$FOLDER/|$MAIN"
    "$WORKTREE/.gaia/local/protected/audit-loop/x.json|$WORKTREE" "$WORKTREE_OVERRIDE|$WORKTREE" "$WORKTREE_NEW_STATE|$WORKTREE" "$WORKTREE_FOLDER|$WORKTREE" "$WORKTREE_FOLDER/|$WORKTREE"
    ".gaia/local/protected/new-state.json|$MAIN"
  )
  local -a shapes=(
    "printf x > @T@"
    "printf x >> @T@"
    "rm @T@"
    "rm -rf @T@"
    "mv $BATS_TEST_TMPDIR/a @T@"
    "cp $BATS_TEST_TMPDIR/a @T@"
    "touch @T@"
    "sed -i '' 's/a/b/' @T@"
    "printf x | tee @T@"
    "ln -s $BATS_TEST_TMPDIR/a @T@"
  )
  for cell in "${targets[@]}"; do
    target="${cell%%|*}"
    cwd="${cell#*|}"
    for shape in "${shapes[@]}"; do
      command_line="${shape//@T@/$target}"
      "$runner" "$command_line" "$cwd"
      cell_is_denied "$runner: $command_line"
      cells=$((cells + 1))
    done
  done
  [ "${#targets[@]}" -eq 11 ]
  [ "${#shapes[@]}" -eq 10 ]
  [ "$cells" -eq 110 ]
}

@test "Bash write shapes against every protected target are denied" {
  assert_write_matrix run_bash
}

@test "Monitor write shapes against every protected target are denied" {
  assert_write_matrix run_monitor
}

assert_indirect_writes_denied() {
  local runner="$1"
  "$runner" "D=$MAIN/.gaia/local/protected; echo x > \"\$D/new-state.json\"" "$MAIN"
  cell_is_denied "$runner variable indirection"
  "$runner" "for f in $MAIN/.gaia/local/protected/*.json; do echo '{}' > \"\$f\"; done" "$MAIN"
  cell_is_denied "$runner loop over a glob"
}

@test "Bash variable and loop writes into the protected folder are denied" {
  assert_indirect_writes_denied run_bash
}

@test "Monitor variable and loop writes into the protected folder are denied" {
  assert_indirect_writes_denied run_monitor
}

assert_read_matrix() {
  local runner="$1" cell target cwd reader cells=0
  local -a targets=(
    "$MAIN/.gaia/local/protected/audit-loop/x.json|$MAIN" "$OVERRIDE|$MAIN" "$NEW_STATE|$MAIN" "$FOLDER|$MAIN" "$FOLDER/|$MAIN"
    "$WORKTREE/.gaia/local/protected/audit-loop/x.json|$WORKTREE" "$WORKTREE_OVERRIDE|$WORKTREE" "$WORKTREE_NEW_STATE|$WORKTREE" "$WORKTREE_FOLDER|$WORKTREE" "$WORKTREE_FOLDER/|$WORKTREE"
    ".gaia/local/protected/new-state.json|$MAIN"
  )
  local -a readers=("cat @T@" "ls @T@" "jq . @T@")
  for cell in "${targets[@]}"; do
    target="${cell%%|*}"
    cwd="${cell#*|}"
    for reader in "${readers[@]}"; do
      "$runner" "${reader//@T@/$target}" "$cwd"
      cell_is_allowed "$runner: ${reader//@T@/$target}"
      cells=$((cells + 1))
    done
  done
  [ "${#targets[@]}" -eq 11 ]
  [ "${#readers[@]}" -eq 3 ]
  [ "$cells" -eq 33 ]
  "$runner" "ls .gaia/local/protected/ | wc -l" "$MAIN"
  cell_is_allowed "$runner: ls of the relative folder piped to wc"
}

@test "Bash reads of every protected target are allowed" {
  assert_read_matrix run_bash
}

@test "Monitor reads of every protected target are allowed" {
  assert_read_matrix run_monitor
}

@test "a read compounded with a write verb on a protected file is denied" {
  run_bash "cat $NEW_STATE && rm $NEW_STATE"
  assert_pins_only_class folder
}

# --- deny class dispatch ---

@test "the Edit tools dispatch each protected path to its own class" {
  local row row_class row_path checked=0
  for row in \
    "state|$STATE" \
    "state|$FOLDER/audit-loop" \
    "override|$OVERRIDE" \
    "folder|$NEW_STATE" \
    "folder|$FOLDER/audit-loop-notes.json" \
    "folder|$FOLDER/checkpoint-override.json.bak" \
    "folder|$FOLDER"; do
    row_class="${row%%|*}"
    row_path="${row#*|}"
    run_edit Write "$row_path"
    assert_pins_only_class "$row_class"
    checked=$((checked + 1))
  done
  [ "$checked" -eq 7 ]
}

@test "Bash dispatches each protected path to its own class" {
  local row row_class row_path checked=0
  for row in \
    "state|$STATE" \
    "state|$FOLDER/audit-loop" \
    "override|$OVERRIDE" \
    "folder|$NEW_STATE" \
    "folder|$FOLDER/audit-loop-notes.json" \
    "folder|$FOLDER/checkpoint-override.json.bak" \
    "folder|$FOLDER"; do
    row_class="${row%%|*}"
    row_path="${row#*|}"
    run_bash "printf x > $row_path"
    assert_pins_only_class "$row_class"
    checked=$((checked + 1))
  done
  [ "$checked" -eq 7 ]
}

assert_compound_pins() {
  local runner="$1"
  "$runner" "cat $STATE; printf x > $OVERRIDE" "$MAIN"
  assert_pins_only_class override
  "$runner" "printf x > $NEW_STATE; cat $STATE" "$MAIN"
  assert_pins_only_class folder
}

@test "Bash compound commands get the class of what is written" {
  assert_compound_pins run_bash
}

@test "Monitor compound commands get the class of what is written" {
  assert_compound_pins run_monitor
}

@test "each deny message names its location and keeps the answer channels" {
  local row row_class row_path checked=0
  for row in "state|$STATE" "override|$OVERRIDE" "folder|$NEW_STATE"; do
    row_class="${row%%|*}"
    row_path="${row#*|}"
    run_edit Write "$row_path"
    assert_pins_only_class "$row_class"
    grep -qF -- 'AskUserQuestion' <<<"$output"
    grep -qF -- 'audit-grant' <<<"$output"
    grep -qF -- 'audit-accept' <<<"$output"
    grep -qF -- '#### The branch checkpoint' <<<"$output"
    checked=$((checked + 1))
  done
  [ "$checked" -eq 3 ]
}

@test "the override message names its location and the writable opt-ins home" {
  run_edit Write "$OVERRIDE"
  assert_pins_only_class override
  grep -qF -- '<main>/.gaia/local/protected/checkpoint-override.json' <<<"$output"
  grep -qF -- '<main>/.gaia/local/settings.json' <<<"$output"
}

# --- siblings and lookalikes ---

@test "Write to a sibling that merely shares the audit-loop prefix is allowed" {
  run_edit Write "$MAIN/.gaia/local/audit-loop-notes.md"
  assert_allowed_by_json
  [ -z "$output" ]
}

@test "Write to a sibling that merely shares the protected prefix is allowed" {
  run_edit Write "$MAIN/.gaia/local/protected-notes.md"
  assert_allowed_by_json
  [ -z "$output" ]
}

assert_lookalikes_allowed() {
  local runner="$1" command_line checked=0
  for command_line in \
    "printf x > $MAIN/.gaia/local/protected-notes.md" \
    "rm $MAIN/.gaia/local/protected.bak" \
    "rm -f $FIX/notes/local/protected/x.json"; do
    "$runner" "$command_line" "$MAIN"
    cell_is_allowed "$runner: $command_line"
    checked=$((checked + 1))
  done
  [ "$checked" -eq 3 ]
  # The lookalike carries the pre-filter literal, so it reaches the path regex.
  grep -qF -- 'local/protected' <<<"$command_line"
}

@test "Bash writes to protected siblings and a lookalike in another tree are allowed" {
  assert_lookalikes_allowed run_bash
}

@test "Monitor writes to protected siblings and a lookalike in another tree are allowed" {
  assert_lookalikes_allowed run_monitor
}

@test "mkdir inside the protected folder is allowed" {
  run_bash "mkdir -p $MAIN/.gaia/local/protected/audit-loop/feat"
  assert_allowed_by_json
  [ -z "$output" ]
}

# --- old locations are neither guarded nor read ---

@test "Write to the old state location is allowed" {
  run_edit Write "$OLD_STATE"
  assert_allowed_by_json
  [ -z "$output" ]
}

@test "Write to the old override location is allowed" {
  run_edit Write "$OLD_OVERRIDE"
  assert_allowed_by_json
  [ -z "$output" ]
}

@test "Bash redirect into the old override location is allowed" {
  run_bash "printf x > $OLD_OVERRIDE"
  assert_allowed_by_json
  [ -z "$output" ]
}

# --- recorder execution reaches the guard through the audit-loop literal ---

assert_recorder_run_denied_and_staging_allowed() {
  local runner="$1" recorder_command="bash .claude/hooks/audit-loop-grant.sh"
  grep -qF -- protected <<<"$recorder_command" && return 1
  grep -qF -- 'cache/shared/context' <<<"$recorder_command" && return 1
  "$runner" "$recorder_command" "$MAIN"
  assert_pins_only_class recorder
  "$runner" "git add .claude/hooks/audit-loop-grant.sh" "$MAIN"
  cell_is_allowed "$runner: git add of the grant recorder"
}

@test "Bash running the grant recorder is denied through the audit-loop literal, and staging it is allowed" {
  assert_recorder_run_denied_and_staging_allowed run_bash
}

@test "Monitor running the grant recorder is denied through the audit-loop literal, and staging it is allowed" {
  assert_recorder_run_denied_and_staging_allowed run_monitor
}

# --- red twins: the protected arms are what deny ---

@test "red twin: without the protected pre-filter literal a redirect and a Write into the folder are allowed" {
  local twin
  twin=$(scratch_hook 's/ \*local\/protected\* \|//')
  grep -qF -- audit-loop <<<"echo '{}' > $OVERRIDE" && return 1
  grep -qF -- audit-loop <<<"$NEW_STATE" && return 1
  invoke_hook "$(command_payload Bash "echo '{}' > $OVERRIDE" "$MAIN")" "$twin"
  assert_allowed_by_json
  invoke_hook "$(edit_payload Write "$NEW_STATE" "$MAIN")" "$twin"
  assert_allowed_by_json
  # The unmutated hook denies both.
  run_bash "echo '{}' > $OVERRIDE"
  assert_denied_by_json
  run_edit Write "$NEW_STATE"
  assert_denied_by_json
}

@test "red twin: without the protected jq literal a missing jq no longer refuses a write into the folder" {
  local twin payload
  twin=$(scratch_hook "/^gaia_require_jq /s/ 'local\/protected'//")
  payload=$(edit_payload Write "$NEW_STATE" "$MAIN")
  grep -qF -- audit-loop <<<"$payload" && return 1
  run_without_jq "$payload" "$twin"
  [ "$status" -eq 0 ]
  # The unmutated hook refuses the same payload.
  run_without_jq "$payload"
  [ "$status" -eq 2 ]
}

@test "red twin: without the guarded_class folder arm a path with no resolvable checkout is allowed" {
  local twin
  mkdir -p "$FIX/nogit/.gaia/local/protected"
  . "$HOOKS_SOURCE_DIRECTORY/../../.gaia/scripts/main-root-lib.sh"
  [ -z "$(gaia_resolve_main_root "$FIX/nogit" 2>/dev/null)" ]
  twin=$(scratch_hook '/^    \*\/\.gaia\/local\/protected\/\* \| \*\/\.gaia\/local\/protected\) protected_class /d')
  invoke_hook "$(edit_payload Write "$FIX/nogit/.gaia/local/protected/new-state.json" "$FIX/nogit")" "$twin"
  assert_allowed_by_json
  # The unmutated hook denies the same payload.
  run_edit Write "$FIX/nogit/.gaia/local/protected/new-state.json" "$FIX/nogit"
  assert_denied_by_json
}

# The resolved-path case arm and the trailing guarded_class fallback each catch
# a resolved alias alone, so removing one is an equivalent mutant no test can
# see; the twin removes both.
@test "red twin: without both resolved-path arms a symlink alias into the folder is allowed" {
  local twin
  ln -s "$MAIN/.gaia/local" "$FIX/alias-local"
  twin=$(scratch_hook '/^        "\$main_root\/\.gaia\/local\/protected" \|/d;/^    class=\$\(guarded_class "\$resolved"\)$/d')
  invoke_hook "$(edit_payload Write "$FIX/alias-local/protected/new-state.json" "$MAIN")" "$twin"
  assert_allowed_by_json
  # The unmutated hook denies the same payload.
  run_edit Write "$FIX/alias-local/protected/new-state.json"
  assert_denied_by_json
}

@test "red twin: a Bash path regex that cannot match lets a protected rm through" {
  local twin
  twin=$(scratch_hook '/^    protected_names_re=/s/local\/protected/local\/protectedX/')
  invoke_hook "$(command_payload Bash "rm $NEW_STATE" "$MAIN")" "$twin"
  assert_allowed_by_json
  # The unmutated hook denies the same payload.
  run_bash "rm $NEW_STATE"
  assert_denied_by_json
}

@test "red twin: without the Edit-tool state dispatch the state path is denied with the folder message" {
  local twin
  twin=$(scratch_hook '/^    "\$2\/audit-loop" \| "\$2\/audit-loop"\/\*\) printf state ;;$/d')
  invoke_hook "$(edit_payload Write "$STATE" "$MAIN")" "$twin"
  assert_denied_by_json
  grep -qF -- "$(class_pin folder)" <<<"$output"
  grep -qF -- "$(class_pin state)" <<<"$output" && return 1
  # The unmutated hook carries the state pin.
  run_edit Write "$STATE"
  assert_pins_only_class state
}

@test "red twin: without the Bash state dispatch a state write is denied with the folder message" {
  local twin
  twin=$(scratch_hook '/^      if \[\[ "\$command_line" =~ \$state_subpath_re \]\]/,/^      fi$/d')
  invoke_hook "$(command_payload Bash "rm $STATE" "$MAIN")" "$twin"
  assert_denied_by_json
  grep -qF -- "$(class_pin folder)" <<<"$output"
  grep -qF -- "$(class_pin state)" <<<"$output" && return 1
  # The unmutated hook carries the state pin.
  run_bash "rm $STATE"
  assert_pins_only_class state
}

# --- the shared payload reader ---

@test "a missing lib/hook-payload.sh refuses a write to the state path rather than allowing the call" {
  local scratch_directory="$BATS_TEST_TMPDIR/no-payload-lib"
  mkdir -p "$scratch_directory"
  cp -R "$HOOKS_SOURCE_DIRECTORY/lib" "$scratch_directory/lib"
  rm -f "$scratch_directory/lib/hook-payload.sh"
  cp "$HOOKS_SOURCE_DIRECTORY/block-audit-loop-write.sh" "$scratch_directory/"
  invoke_hook "$(edit_payload Write "$STATE" "$MAIN")" "$scratch_directory/block-audit-loop-write.sh"
  [ "$status" -eq 2 ]
  grep -qF -- 'cannot load lib/hook-payload.sh' <<<"$output"
}

@test "an ordinary Bash call runs no jq at all" {
  local shim_directory="$BATS_TEST_TMPDIR/shim" real_jq
  real_jq=$(command -v jq)
  mkdir -p "$shim_directory"
  printf '#!/usr/bin/env bash\nprintf "jq\\n" >> "%s/calls.log"\nexec "%s" "$@"\n' "$BATS_TEST_TMPDIR" "$real_jq" >"$shim_directory/jq"
  chmod +x "$shim_directory/jq"
  PATH="$shim_directory:$PATH" invoke_hook "$(command_payload Bash "ls -la" "$MAIN")" "$HOOK_ABSOLUTE_PATH"
  assert_allowed_by_json
  [ ! -s "$BATS_TEST_TMPDIR/calls.log" ]
}
