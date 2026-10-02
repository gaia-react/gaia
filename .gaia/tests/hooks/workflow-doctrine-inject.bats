#!/usr/bin/env bats

# .claude/hooks/workflow-doctrine-inject.sh: injects the execution doctrine
# through hookSpecificOutput.additionalContext when a session works on a branch
# (non-default branch in the main checkout, or any linked worktree), at
# SessionStart and mid-session, and never for a session on the default branch
# in the main checkout.
#
# Every fixture repo carries its own copy of the hook, its libraries, and a
# fixture doctrine file, so the suite never reads the real doctrine. HOOK_SOURCE_PATH
# points the suite at another copy of the hook (a mutated scratch copy proves
# the cases can go red); it defaults to the real hook.
#
# Each negative case runs in the same fixture as a positive control that
# differs by one variable. The hook runs under /bin/bash, the shell whose cost
# budget it is held to.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/tests/hooks/workflow-doctrine-inject.bats < /dev/null

bats_require_minimum_version 1.5.0

setup() {
  # Isolate the rates state and the price feed (token-rates-hermetic.bats).
  export GAIA_RATES_STATE_DIRECTORY="$BATS_TEST_TMPDIR/rates-state"
  export GAIA_RATES_FEED_DISABLE=1
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  unset GITHUB_ACTIONS CLAUDE_CODE_SESSION_ID
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com
  export GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com
  HOOK_SOURCE_PATH="${HOOK_SOURCE_PATH:-$REPO_ROOT/.claude/hooks/workflow-doctrine-inject.sh}"
  REPO="$TEMPORARY_DIRECTORY/repo"
  HOOK="$REPO/.claude/hooks/workflow-doctrine-inject.sh"
  DOCTRINE_PATH="$REPO/.claude/doctrine/execution.md"
  mkdir -p "$TEMPORARY_DIRECTORY/norepo"
  cd "$TEMPORARY_DIRECTORY/norepo" || return 1
  make_repo
}

make_repo() {
  mkdir -p "$REPO/.claude/hooks" "$REPO/.claude/doctrine" "$REPO/.gaia/scripts"
  cp "$HOOK_SOURCE_PATH" "$HOOK"
  chmod 755 "$HOOK"
  cp -R "$REPO_ROOT/.claude/hooks/lib" "$REPO/.claude/hooks/lib"
  local library_file
  for library_file in usage-lib.sh main-root-lib.sh branch-name-lib.sh; do
    cp "$REPO_ROOT/.gaia/scripts/$library_file" "$REPO/.gaia/scripts/$library_file"
  done
  printf 'Fixture doctrine line one.\nIt says "quoted" and back\\slash and\ttab.\nLast line.\n' >"$DOCTRINE_PATH"
  git -C "$REPO" init -q -b main
  git -C "$REPO" commit -q --allow-empty -m init
}

# Payload builders: <sid> ... <cwd>
session_start_payload() { jq -nc --arg session_id "$1" --arg session_source "$2" --arg working_directory "$3" '{hook_event_name:"SessionStart",session_id:$session_id,source:$session_source,cwd:$working_directory}'; }
post_tool_bash_payload() {
  jq -nc --arg session_id "$1" --arg command_text "$2" --arg working_directory "$3" \
    '{hook_event_name:"PostToolUse",session_id:$session_id,tool_name:"Bash",tool_input:{command:$command_text},tool_response:{},cwd:$working_directory}'
}
post_tool_enter_worktree_payload() {
  jq -nc --arg session_id "$1" --arg working_directory "$2" --arg worktree_path "${3:-}" \
    '{hook_event_name:"PostToolUse",session_id:$session_id,tool_name:"EnterWorktree",tool_input:{},tool_response:(if $worktree_path == "" then {} else {worktreePath:$worktree_path} end),cwd:$working_directory}'
}

run_hook() { run --separate-stderr /bin/bash "$HOOK" <<<"$1"; }

marker() { printf '%s/.gaia/local/cache/doctrine-injected.%s' "$REPO" "$1"; }

# Exit 0, empty stderr, exactly one JSON value, hookEventName echoes the input
# event; leaves the decoded additionalContext bytes in $TEMPORARY_DIRECTORY/ctx.
assert_envelope() {
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(jq -s length <<<"$output")" = 1 ]
  [ "$(jq -r .hookSpecificOutput.hookEventName <<<"$output")" = "$1" ]
  jq -j .hookSpecificOutput.additionalContext <<<"$output" >"$TEMPORARY_DIRECTORY/ctx"
}

# Context is the fixture doctrine byte for byte, with no key line.
assert_injects() {
  assert_envelope "$1"
  cmp "$TEMPORARY_DIRECTORY/ctx" "$DOCTRINE_PATH"
}

# Context is one key line starting with <prefix>, then the doctrine byte for byte.
assert_injects_keyed() {
  assert_envelope "$1"
  local first
  first="$(head -n 1 "$TEMPORARY_DIRECTORY/ctx")"
  case "$first" in "$2"*) ;; *) echo "first line '$first' lacks prefix '$2'" >&2; return 1 ;; esac
  tail -n +2 "$TEMPORARY_DIRECTORY/ctx" >"$TEMPORARY_DIRECTORY/rest"
  cmp "$TEMPORARY_DIRECTORY/rest" "$DOCTRINE_PATH"
}

assert_silent() {
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "UAT-003: default branch in the main checkout is silent for every SessionStart source, and a feature branch injects" {
  local session_source
  for session_source in startup resume clear compact; do
    run_hook "$(session_start_payload "s-$session_source" "$session_source" "$REPO")"
    assert_silent
  done
  git -C "$REPO" checkout -q -b feat/123-example
  run_hook "$(session_start_payload s-control startup "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:feat/123-example. "
}

@test "UAT-004: a feature branch in the main checkout gets the exact branch key line, then the doctrine" {
  git -C "$REPO" checkout -q -b feat/123-example
  run_hook "$(session_start_payload s4 startup "$REPO")"
  assert_envelope SessionStart
  [ "$(head -n 1 "$TEMPORARY_DIRECTORY/ctx")" = "Branch key: branch:feat/123-example. Link its initiative once with: bash .gaia/scripts/usage.sh link branch:feat/123-example research:<topic>-<date> (or issue:<n>)" ]
  tail -n +2 "$TEMPORARY_DIRECTORY/ctx" >"$TEMPORARY_DIRECTORY/rest"
  cmp "$TEMPORARY_DIRECTORY/rest" "$DOCTRINE_PATH"
}

@test "UAT-005: every linked worktree injects; the key follows the worktree's branch" {
  git -C "$REPO" worktree add -q -b "worktree-debt+42" "$TEMPORARY_DIRECTORY/wt1"
  run_hook "$(session_start_payload s5a startup "$TEMPORARY_DIRECTORY/wt1")"
  assert_injects_keyed SessionStart "Branch key: branch:debt/42. "

  git -C "$TEMPORARY_DIRECTORY/wt1" checkout -q --detach
  run_hook "$(session_start_payload s5b startup "$TEMPORARY_DIRECTORY/wt1")"
  assert_injects_keyed SessionStart "Session key: session:s5b. "
  [ "$(head -n 1 "$TEMPORARY_DIRECTORY/ctx" | grep -c 'branch:')" = 0 ]

  git -C "$REPO" worktree add -q -b worktree-agent-abc123 "$TEMPORARY_DIRECTORY/wt2"
  run_hook "$(session_start_payload s5c startup "$TEMPORARY_DIRECTORY/wt2")"
  assert_injects_keyed SessionStart "Session key: session:s5c. "

  git -C "$REPO" checkout -q -b other
  git -C "$REPO" worktree add -q "$TEMPORARY_DIRECTORY/wt3" main
  run_hook "$(session_start_payload s5d startup "$TEMPORARY_DIRECTORY/wt3")"
  assert_injects_keyed SessionStart "Session key: session:s5d. "
}

@test "UAT-006: EnterWorktree decides from worktreePath, then payload cwd, never the process cwd" {
  git -C "$REPO" worktree add -q -b feat/9-x "$TEMPORARY_DIRECTORY/wtb"
  git -C "$REPO" worktree add -q --detach "$TEMPORARY_DIRECTORY/wtd"

  run_hook "$(post_tool_enter_worktree_payload e1 "$REPO" "$TEMPORARY_DIRECTORY/wtb")"
  assert_injects_keyed PostToolUse "Branch key: branch:feat/9-x. "

  run_hook "$(post_tool_enter_worktree_payload e2 "$TEMPORARY_DIRECTORY/wtb")"
  assert_injects_keyed PostToolUse "Branch key: branch:feat/9-x. "

  run_hook "$(post_tool_enter_worktree_payload e3 "$REPO" "$TEMPORARY_DIRECTORY/wtd")"
  assert_injects_keyed PostToolUse "Session key: session:e3. "

  run_hook "$(post_tool_enter_worktree_payload e4 "$REPO" "$REPO")"
  assert_silent
}

@test "UAT-006: a non-Bash, non-EnterWorktree PostToolUse tool is silent in a tree that would inject" {
  git -C "$REPO" checkout -q -b feat/9-x
  run_hook "$(jq -nc --arg working_directory "$REPO" '{hook_event_name:"PostToolUse",session_id:"t1",tool_name:"Read",tool_input:{},tool_response:{},cwd:$working_directory}')"
  assert_silent
  run_hook "$(post_tool_enter_worktree_payload t2 "$REPO")"
  assert_injects_keyed PostToolUse "Branch key: branch:feat/9-x. "
}

@test "EnterWorktree into a tree with no .gaia/local creates nothing there and writes the marker under the main root" {
  git -C "$REPO" worktree add -q -b feat/9-x "$TEMPORARY_DIRECTORY/wtn"
  [ ! -e "$TEMPORARY_DIRECTORY/wtn/.gaia/local" ]
  run_hook "$(post_tool_enter_worktree_payload m1 "$REPO" "$TEMPORARY_DIRECTORY/wtn")"
  assert_injects_keyed PostToolUse "Branch key: branch:feat/9-x. "
  [ ! -e "$TEMPORARY_DIRECTORY/wtn/.gaia/local" ]
  [ -f "$(marker m1)" ]
  [ "$(cat "$(marker m1)")" = "branch:feat/9-x" ]
}

@test "UAT-007: a branch-changing Bash command injects once the checkout happened, and only then" {
  git -C "$REPO" branch feat/12-x

  git -C "$REPO" checkout -q -b fix/7-x
  run_hook "$(post_tool_bash_payload b1 'git checkout -b fix/7-x' "$REPO")"
  assert_injects_keyed PostToolUse "Branch key: branch:fix/7-x. "
  git -C "$REPO" checkout -q main
  git -C "$REPO" branch -q -D fix/7-x

  git -C "$REPO" switch -q -c fix/7-x
  run_hook "$(post_tool_bash_payload b2 'git switch -c fix/7-x' "$REPO")"
  assert_injects_keyed PostToolUse "Branch key: branch:fix/7-x. "
  git -C "$REPO" checkout -q main
  git -C "$REPO" branch -q -D fix/7-x

  git -C "$REPO" switch -q -c fix/7-x
  run_hook "$(post_tool_bash_payload b3 "git -C \"$REPO\" switch -c fix/7-x" "$REPO")"
  assert_injects_keyed PostToolUse "Branch key: branch:fix/7-x. "
  git -C "$REPO" checkout -q main

  git -C "$REPO" checkout -q feat/12-x
  run_hook "$(post_tool_bash_payload b4 'git checkout feat/12-x' "$REPO")"
  assert_injects_keyed PostToolUse "Branch key: branch:feat/12-x. "
  git -C "$REPO" checkout -q main

  git -C "$REPO" switch -q feat/12-x
  run_hook "$(post_tool_bash_payload b5 'git switch feat/12-x' "$REPO")"
  assert_injects_keyed PostToolUse "Branch key: branch:feat/12-x. "
  git -C "$REPO" checkout -q main

  git -C "$REPO" checkout -q -b pr-123
  run_hook "$(post_tool_bash_payload b6 'gh pr checkout 123' "$REPO")"
  assert_injects_keyed PostToolUse "Branch key: branch:pr-123. "
  git -C "$REPO" checkout -q main

  # Same fixture, HEAD back on the default branch: nothing to inject.
  run_hook "$(post_tool_bash_payload n1 'git checkout main' "$REPO")"
  assert_silent
  run_hook "$(post_tool_bash_payload n2 'git status' "$REPO")"
  assert_silent
  run_hook "$(post_tool_bash_payload n3 'git switch -c fix/8-y' "$REPO")"
  assert_silent
  [ "$(git -C "$REPO" symbolic-ref --short HEAD)" = main ]
}

@test "a Bash command that does not arm starts no git process; an armed one does" {
  local real_git
  real_git="$(command -v git)"
  mkdir -p "$TEMPORARY_DIRECTORY/shim"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\nexec "%s" "$@"\n' "$TEMPORARY_DIRECTORY/git.log" "$real_git" >"$TEMPORARY_DIRECTORY/shim/git"
  chmod 755 "$TEMPORARY_DIRECTORY/shim/git"
  git -C "$REPO" branch feat/12-x
  git -C "$REPO" checkout -q feat/12-x

  local shell_command
  for shell_command in 'ls -la' 'echo checkout' 'git status' 'pnpm test'; do
    run --separate-stderr env PATH="$TEMPORARY_DIRECTORY/shim:$PATH" /bin/bash "$HOOK" <<<"$(post_tool_bash_payload "shim-$RANDOM" "$shell_command" "$REPO")"
    assert_silent
  done
  [ ! -s "$TEMPORARY_DIRECTORY/git.log" ]

  run --separate-stderr env PATH="$TEMPORARY_DIRECTORY/shim:$PATH" /bin/bash "$HOOK" <<<"$(post_tool_bash_payload shim-control 'git switch feat/12-x' "$REPO")"
  assert_injects_keyed PostToolUse "Branch key: branch:feat/12-x. "
  [ -s "$TEMPORARY_DIRECTORY/git.log" ]
}

@test "UAT-008: the marker dedupes startup and PostToolUse for one key; resume, compact, and clear always inject; a new key injects" {
  git -C "$REPO" checkout -q -b fix/7-x
  run_hook "$(session_start_payload d1 startup "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:fix/7-x. "
  [ "$(cat "$(marker d1)")" = "branch:fix/7-x" ]

  run_hook "$(post_tool_enter_worktree_payload d1 "$REPO")"
  assert_silent
  run_hook "$(post_tool_bash_payload d1 'git switch fix/7-x' "$REPO")"
  assert_silent
  run_hook "$(session_start_payload d1 startup "$REPO")"
  assert_silent

  run_hook "$(session_start_payload d1 resume "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:fix/7-x. "
  run_hook "$(session_start_payload d1 compact "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:fix/7-x. "
  run_hook "$(session_start_payload d1 clear "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:fix/7-x. "

  git -C "$REPO" checkout -q -b fix/9-z
  run_hook "$(post_tool_bash_payload d1 'git switch -c fix/9-z' "$REPO")"
  assert_injects_keyed PostToolUse "Branch key: branch:fix/9-z. "
  [ "$(cat "$(marker d1)")" = "branch:fix/9-z" ]
}

@test "UAT-008: a no-injection clear removes the marker so a later return to the branch injects" {
  git -C "$REPO" checkout -q -b fix/7-x
  run_hook "$(session_start_payload d2 startup "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:fix/7-x. "
  [ -f "$(marker d2)" ]

  git -C "$REPO" checkout -q main
  run_hook "$(session_start_payload d2 clear "$REPO")"
  assert_silent
  [ -e "$(marker d2)" ] && return 1

  git -C "$REPO" checkout -q fix/7-x
  run_hook "$(post_tool_bash_payload d2 'git switch fix/7-x' "$REPO")"
  assert_injects_keyed PostToolUse "Branch key: branch:fix/7-x. "
}

@test "UAT-008: a no-injection resume or compact also removes the marker; startup leaves it" {
  git -C "$REPO" checkout -q -b fix/7-x
  run_hook "$(session_start_payload d3 startup "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:fix/7-x. "
  git -C "$REPO" checkout -q main

  run_hook "$(session_start_payload d3 startup "$REPO")"
  assert_silent
  [ -f "$(marker d3)" ]

  run_hook "$(session_start_payload d3 resume "$REPO")"
  assert_silent
  [ -e "$(marker d3)" ] && return 1
  true
}

@test "UAT-009: CI is silent, with a control that injects" {
  git -C "$REPO" checkout -q -b feat/123-example
  run --separate-stderr env GITHUB_ACTIONS=true /bin/bash "$HOOK" <<<"$(session_start_payload c1 startup "$REPO")"
  assert_silent
  run_hook "$(session_start_payload c1 startup "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:feat/123-example. "
}

@test "UAT-009: a cwd outside any repository is silent, with a control that injects" {
  git -C "$REPO" checkout -q -b feat/123-example
  run_hook "$(session_start_payload c2 startup "$TEMPORARY_DIRECTORY/norepo")"
  assert_silent
  run_hook "$(jq -nc '{hook_event_name:"SessionStart",session_id:"c2",source:"startup"}')"
  assert_silent
  run_hook "$(session_start_payload c2 startup "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:feat/123-example. "
}

@test "UAT-009: a missing doctrine file is silent, with a control that injects" {
  git -C "$REPO" checkout -q -b feat/123-example
  run_hook "$(session_start_payload c3 startup "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:feat/123-example. "
  mv "$DOCTRINE_PATH" "$TEMPORARY_DIRECTORY/execution.md.away"
  run_hook "$(session_start_payload c3b startup "$REPO")"
  assert_silent
}

@test "UAT-009: without jq, SessionStart injects valid JSON from the process cwd and PostToolUse is silent" {
  git -C "$REPO" checkout -q -b feat/123-example
  mkdir -p "$TEMPORARY_DIRECTORY/nojq"
  local tool_name tool_path
  for tool_name in git sed awk cat wc; do
    tool_path="$(command -v "$tool_name")"
    ln -sf "$tool_path" "$TEMPORARY_DIRECTORY/nojq/$tool_name"
  done
  [ ! -e "$TEMPORARY_DIRECTORY/nojq/jq" ]

  # shellcheck disable=SC2016  # the inner script expands in the child shell
  run --separate-stderr bash -c 'cd "$1" && PATH="$2" exec /bin/bash "$3"' _ "$REPO" "$TEMPORARY_DIRECTORY/nojq" "$HOOK" <<<"$(session_start_payload nj startup "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:feat/123-example. "
  [ ! -e "$(marker nj)" ]

  # shellcheck disable=SC2016  # the inner script expands in the child shell
  run --separate-stderr bash -c 'cd "$1" && PATH="$2" exec /bin/bash "$3"' _ "$REPO" "$TEMPORARY_DIRECTORY/nojq" "$HOOK" <<<"$(post_tool_bash_payload nj 'git switch feat/123-example' "$REPO")"
  assert_silent

  git -C "$REPO" checkout -q main
  # shellcheck disable=SC2016  # the inner script expands in the child shell
  run --separate-stderr bash -c 'cd "$1" && PATH="$2" exec /bin/bash "$3"' _ "$REPO" "$TEMPORARY_DIRECTORY/nojq" "$HOOK" <<<"$(session_start_payload nj startup "$REPO")"
  assert_silent
}

@test "UAT-010: an off-grammar branch name is never echoed and carries no key line" {
  local name
  # shellcheck disable=SC2016  # a literal $( is the point
  name="$(printf 'feat/a\140b$(x)%%')"
  git check-ref-format --branch "$name" >/dev/null
  git -C "$REPO" checkout -q -b "$name"
  run_hook "$(session_start_payload g1 startup "$REPO")"
  assert_injects SessionStart
  grep -q 'Branch key' "$TEMPORARY_DIRECTORY/ctx" && return 1
  grep -q 'usage.sh link' "$TEMPORARY_DIRECTORY/ctx" && return 1
  grep -qF '`' "$TEMPORARY_DIRECTORY/ctx" && return 1
  # shellcheck disable=SC2016  # a literal $( is the point
  grep -qF '$(' "$TEMPORARY_DIRECTORY/ctx" && return 1
  # Control: a valid name on the same fixture gets its key line.
  git -C "$REPO" checkout -q -b feat/ok
  run_hook "$(session_start_payload g2 startup "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:feat/ok. "
}

@test "UAT-010: a 128-character branch with a maximum-size doctrine stays under the payload cap and keeps its full name" {
  local name base pad
  name="feat/$(head -c 123 /dev/zero | tr '\0' a)"
  [ "${#name}" = 128 ]
  git -C "$REPO" checkout -q -b "$name"
  base="$(wc -c <"$DOCTRINE_PATH")"
  pad=$((3584 - base - 1))
  { cat "$DOCTRINE_PATH"; head -c "$pad" /dev/zero | tr '\0' x; printf '\n'; } >"$TEMPORARY_DIRECTORY/padded"
  mv "$TEMPORARY_DIRECTORY/padded" "$DOCTRINE_PATH"
  [ "$(wc -c <"$DOCTRINE_PATH")" -eq 3584 ]

  run_hook "$(session_start_payload p1 startup "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:$name. "
  [ "$(wc -c <"$TEMPORARY_DIRECTORY/ctx")" -le 4096 ]
  head -n 1 "$TEMPORARY_DIRECTORY/ctx" | grep -qF "link branch:$name research:"
}

@test "audit directive 10: a doctrine one byte over the cap is silent, never truncated" {
  local base pad
  git -C "$REPO" checkout -q -b feat/123-example
  base="$(wc -c <"$DOCTRINE_PATH")"
  pad=$((3585 - base - 1))
  { cat "$DOCTRINE_PATH"; head -c "$pad" /dev/zero | tr '\0' x; printf '\n'; } >"$TEMPORARY_DIRECTORY/padded"
  mv "$TEMPORARY_DIRECTORY/padded" "$DOCTRINE_PATH"
  [ "$(wc -c <"$DOCTRINE_PATH")" -eq 3585 ]
  run_hook "$(session_start_payload o1 startup "$REPO")"
  assert_silent

  pad=$((3584 - base - 1))
  printf 'Fixture doctrine line one.\nIt says "quoted" and back\\slash and\ttab.\nLast line.\n' >"$DOCTRINE_PATH"
  { cat "$DOCTRINE_PATH"; head -c "$pad" /dev/zero | tr '\0' x; printf '\n'; } >"$TEMPORARY_DIRECTORY/padded"
  mv "$TEMPORARY_DIRECTORY/padded" "$DOCTRINE_PATH"
  [ "$(wc -c <"$DOCTRINE_PATH")" -eq 3584 ]
  run_hook "$(session_start_payload o2 startup "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:feat/123-example. "
}

@test "a git directory not named .git still anchors the marker at the main root" {
  mv "$REPO/.git" "$TEMPORARY_DIRECTORY/sepgit"
  printf 'gitdir: %s\n' "$TEMPORARY_DIRECTORY/sepgit" >"$REPO/.git"
  git -C "$REPO" checkout -q -b feat/123-example
  run_hook "$(session_start_payload sg startup "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:feat/123-example. "
  [ -f "$(marker sg)" ]
}

@test "a reftable repository decides the same way as a files repository" {
  rm -rf "$REPO/.git"
  git -C "$REPO" init -q -b main --ref-format=reftable 2>/dev/null || skip "git lacks reftable support"
  git -C "$REPO" commit -q --allow-empty -m init
  run_hook "$(session_start_payload rt1 startup "$REPO")"
  assert_silent
  git -C "$REPO" checkout -q -b feat/123-example
  run_hook "$(session_start_payload rt2 startup "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:feat/123-example. "
}

@test "an origin/HEAD that names another branch makes main a non-default branch" {
  git -C "$REPO" branch develop
  git -C "$REPO" update-ref refs/remotes/origin/develop HEAD
  git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
  run_hook "$(session_start_payload od1 startup "$REPO")"
  assert_injects_keyed SessionStart "Branch key: branch:main. "
  git -C "$REPO" checkout -q develop
  run_hook "$(session_start_payload od2 startup "$REPO")"
  assert_silent
}
