#!/usr/bin/env bats

# Tests for .claude/hooks/block-audit-loop-write.sh.
#
# The audit loop state directory (<main>/.gaia/local/audit-loop/) is written only
# by the audit loop hooks. This guard denies Claude's Edit / Write / MultiEdit
# calls that resolve into it (including through a linked worktree's `.gaia/local`
# symlink and a `..` segment) and Bash / Monitor commands that redirect into it
# or name it alongside a write, move or delete verb, while allowing reads,
# quoted notes that mention it redirected elsewhere, and the audit loop
# scripts, which never name the state directory. A path segment that merely ends
# in `audit-loop` (a worktree named like `spec-091-audit-loop`) does not arm it.

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
  mkdir -p "$MAIN/.gaia/local/cache/shared/context"
  CTX_NAME=0a1b2c3d-0000-4000-8000-000000000001.json
  CTX="$MAIN/.gaia/local/cache/shared/context/$CTX_NAME"
  WCTX="$WT/.gaia/local/cache/shared/context/$CTX_NAME"
  printf '{"version":1}' >"$CTX"
  OVERRIDE="$MAIN/.gaia/local/checkpoint-override.json"
  WOVERRIDE="$WT/.gaia/local/checkpoint-override.json"
  ASK_RECORDER="$MAIN/.claude/hooks/audit-loop-ask-grant.sh"
  GRANT_RECORDER="$MAIN/.claude/hooks/audit-loop-grant.sh"
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

# --- redirect target, not redirect anywhere ---

# A note that quotes a guarded path as text and is redirected elsewhere is the
# shape an audit member stages a findings sidecar with.
@test "printf of quoted text naming each guarded path, redirected to a /tmp file, is allowed" {
  local checked=0 p
  for p in "$STATE" "$CTX" "$OVERRIDE"; do
    run_bash "printf '%s\n' 'the hook trusts $p as written' > $BATS_TEST_TMPDIR/note.txt"
    assert_allowed_by_json
    [ -z "$output" ]
    checked=$((checked + 1))
  done
  [ "$checked" -eq 3 ]
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
  run_bash "D=$MAIN/.gaia/local/audit-loop/feat; echo x > \"\$D/x.json\""
  assert_denied_by_json
}

@test "Bash redirect in a loop over a glob of the state directory is denied" {
  run_bash "for f in $MAIN/.gaia/local/audit-loop/feat/*.json; do echo '{}' > \"\$f\"; done"
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

@test "rm of a file under a worktree whose name ends in audit-loop is allowed" {
  run_bash "rm -f $FIX/spec-091-audit-loop/notes.txt"
  assert_allowed_by_json
}

@test "a redirect into a worktree whose name ends in audit-loop is allowed" {
  run_bash "echo x > $FIX/spec-091-audit-loop/app/file.ts"
  assert_allowed_by_json
}

@test "the state path inside a worktree named like audit-loop is still denied" {
  run_bash "rm -f $FIX/spec-091-audit-loop/.gaia/local/audit-loop/feat/x.json"
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
  invoke_hook "$(cmd_payload Monitor "$1" "${2:-$MAIN}")" "$HOOK_ABS"
}

# scratch_hook <sed-script>: write a mutated copy of the hook under test into a
# scratch tree that still resolves its library and main-root lib, print its
# path, and fail when the mutation changed nothing (a twin that mutates no line
# proves nothing).
scratch_hook() {
  local root="$BATS_TEST_TMPDIR/scratch-hook"
  mkdir -p "$root/.claude/hooks" "$root/.gaia"
  ln -sfn "$HOOKS_SRC/lib" "$root/.claude/hooks/lib"
  ln -sfn "$HOOKS_SRC/../../.gaia/scripts" "$root/.gaia/scripts"
  sed -E "$1" "$HOOK_ABS" >"$root/.claude/hooks/block-audit-loop-write.sh"
  if cmp -s "$HOOK_ABS" "$root/.claude/hooks/block-audit-loop-write.sh"; then
    return 1
  fi
  printf '%s' "$root/.claude/hooks/block-audit-loop-write.sh"
}

# --- context readings: edit tools ---

@test "Write to a context file is denied naming the guard" {
  run_edit Write "$CTX"
  assert_denied_class 'context readings'
}

@test "Edit of a context file is denied" {
  run_edit Edit "$CTX"
  assert_denied_class 'context readings'
}

@test "Write to a not-yet-existing context file is denied" {
  run_edit Write "$MAIN/.gaia/local/cache/shared/context/0a1b2c3d-0000-4000-8000-000000000002.json"
  assert_denied_class 'context readings'
}

@test "Write to a context file through the worktree symlink spelling is denied" {
  run_edit Write "$WCTX" "$WT"
  assert_denied_class 'context readings'
}

@test "Edit of a context file through the worktree symlink spelling is denied" {
  run_edit Edit "$WCTX" "$WT"
  assert_denied_class 'context readings'
}

@test "Write to a context file with a .. segment is denied" {
  run_edit Write "$MAIN/.gaia/local/cache/../cache/shared/context/$CTX_NAME"
  assert_denied_class 'context readings'
}

# --- context readings: Bash natural spellings ---

@test "Bash redirect into a context file is denied" {
  run_bash "printf x > $CTX"
  assert_denied_class 'context readings'
}

@test "Bash mv of a context file is denied" {
  run_bash "mv $CTX /tmp/x"
  assert_denied_class 'context readings'
}

@test "Bash rm -f of a context file is denied" {
  run_bash "rm -f $CTX"
  assert_denied_class 'context readings'
}

@test "Bash rm of the context directory itself is denied" {
  run_bash "rm -rf $MAIN/.gaia/local/cache/shared/context"
  assert_denied_class 'context readings'
}

@test "Bash redirect into a context file through the worktree spelling is denied" {
  run_bash "printf x > $WCTX" "$WT"
  assert_denied_class 'context readings'
}

@test "Bash mv of a context file through the worktree spelling is denied" {
  run_bash "mv $WCTX /tmp/x" "$WT"
  assert_denied_class 'context readings'
}

@test "Bash rm -f of a context file through the worktree spelling is denied" {
  run_bash "rm -f $WCTX" "$WT"
  assert_denied_class 'context readings'
}

@test "Monitor writing a context file is denied" {
  run_monitor "rm -f $CTX"
  assert_denied_class 'context readings'
}

@test "Bash cat of a context file is allowed" {
  run_bash "cat $CTX"
  assert_allowed_by_json
  [ -z "$output" ]
}

@test "Bash jq read of a context file is allowed" {
  run_bash "jq . $CTX"
  assert_allowed_by_json
  [ -z "$output" ]
}

@test "Write to a sibling cache file is allowed" {
  run_edit Write "$MAIN/.gaia/local/cache/shared/update-check.json"
  assert_allowed_by_json
  [ -z "$output" ]
}

@test "a process outside the tool path still writes a context file" {
  run bash -c 'printf "{\"version\":1,\"n\":2}" > "$1.tmp" && mv "$1.tmp" "$1"' _ "$CTX"
  [ "$status" -eq 0 ]
  grep -qF -- '"n":2' "$CTX"
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
  run_edit Write "$WOVERRIDE" "$WT"
  assert_denied_class 'only a human edits the override'
}

@test "Bash redirect creating the override file is denied" {
  run_bash "echo '{}' > $OVERRIDE"
  assert_denied_class 'only a human edits the override'
}

@test "Bash redirect creating the override file through the worktree spelling is denied" {
  run_bash "echo '{}' > $WOVERRIDE" "$WT"
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

@test "Write to a sibling that merely shares the override file name prefix is allowed" {
  run_edit Write "$MAIN/.gaia/local/checkpoint-override.json.bak"
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
  run_edit Write "$WT/.gaia/local/settings.json" "$WT"
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
    "$(edit_payload Write "$CTX" "$MAIN")" \
    "$(edit_payload Write "$OVERRIDE" "$MAIN")" \
    "$(cmd_payload Bash "bash $ASK_RECORDER" "$MAIN")"; do
    invoke_hook "$payload" "$HOOK_ABS"
    assert_denied_by_json
    grep -qF -- 'block-audit-loop-write.sh' <<<"$output"
    grep -qF -- 'AskUserQuestion' <<<"$output"
    grep -qF -- 'audit-grant' <<<"$output"
    checked=$((checked + 1))
  done
  [ "$checked" -eq 4 ]
}

# --- red twins: the new arms are what deny ---

@test "red twin: without the execution rule a piped forgery to the recorder is allowed" {
  local twin
  twin=$(scratch_hook '/^    runs_recorder "\$cmd" && deny recorder$/d')
  invoke_hook "$(cmd_payload Bash "printf x | bash $ASK_RECORDER" "$MAIN")" "$twin"
  assert_allowed_by_json
  # The unmutated hook denies the same payload.
  run_bash "printf x | bash $ASK_RECORDER"
  assert_denied_by_json
}

@test "red twin: a rule widened to any command naming the recorder denies git add" {
  local twin
  twin=$(scratch_hook 's/^    runs_recorder "\$cmd" && deny recorder$/    case "$cmd" in *audit-loop-grant.sh* | *audit-loop-ask-grant.sh*) deny recorder ;; esac/')
  invoke_hook "$(cmd_payload Bash "git -C $MAIN add -- .claude/hooks/audit-loop-grant.sh" "$MAIN")" "$twin"
  assert_denied_by_json
  # The unmutated hook allows the same payload.
  run_bash "git -C $MAIN add -- .claude/hooks/audit-loop-grant.sh"
  assert_allowed_by_json
}

@test "red twin: without the widened pre-filter a context redirect and an override redirect are allowed" {
  local twin
  twin=$(scratch_hook 's/^  \*audit-loop\* \| \*cache\/shared\/context\* \| \*local\/checkpoint-override\.json\*\) ;;$/  *audit-loop*) ;;/')
  invoke_hook "$(cmd_payload Bash "printf x > $CTX" "$MAIN")" "$twin"
  assert_allowed_by_json
  invoke_hook "$(cmd_payload Bash "echo '{}' > $OVERRIDE" "$MAIN")" "$twin"
  assert_allowed_by_json
  # The unmutated hook denies both.
  run_bash "printf x > $CTX"
  assert_denied_by_json
  run_bash "echo '{}' > $OVERRIDE"
  assert_denied_by_json
}

# --- jq absent, new spellings ---

@test "jq absent: a Write to a context file is refused" {
  run_without_jq "$(edit_payload Write "$CTX" "$MAIN")"
  [ "$status" -eq 2 ]
}

@test "jq absent: a command that rewrites the override file is refused" {
  run_without_jq "$(cmd_payload Bash "echo '{}' > $OVERRIDE" "$MAIN")"
  [ "$status" -eq 2 ]
}
