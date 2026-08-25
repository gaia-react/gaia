#!/usr/bin/env bats

# Tests for .claude/hooks/block-main-destructive-git.sh.
#
# The hook blocks commits to main/master, force-push to main/master, and any
# plain `git push` originating from main/master (PR-only flow). It fires only on
# a real `git` INVOCATION in command position; command text that merely
# mentions `git commit` / `git push` (a grep pattern, an echo string, an
# argument to another program) does not trip it. Foreign-repo commands pass via
# the shared repo-scope helper.
#
# Each test drives the hook as the harness does: a PreToolUse JSON payload on
# stdin, run with the repo as the working directory (the hook resolves the
# current branch from cwd and loads .claude/hooks/lib/repo-scope.sh relative to
# cwd). The hook always exits 0; allow vs deny is carried in stdout.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABS="$HOOKS_SRC/block-main-destructive-git.sh"

  REPO=$(mktemp -d -t block-main-test-XXXXXX)
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false
  echo "# readme" > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit --quiet -m "init"

  # The hook sources the repo-scope helper relative to cwd; give the tmp repo
  # a real copy so the foreign-repo bypass resolves.
  mkdir -p "$REPO/.claude/hooks/lib"
  cp "$HOOKS_SRC/lib/repo-scope.sh" "$REPO/.claude/hooks/lib/repo-scope.sh"

  # A second, distinct repo for the foreign-repo case.
  FOREIGN=$(mktemp -d -t block-main-foreign-XXXXXX)
  git -C "$FOREIGN" init --quiet --initial-branch=main
  git -C "$FOREIGN" config user.email "test@example.com"
  git -C "$FOREIGN" config user.name "Test"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO" || true
  [ -n "${FOREIGN:-}" ] && rm -rf "$FOREIGN" || true
  return 0
}

on_main() { git -C "$REPO" checkout --quiet main; }
on_feature() { git -C "$REPO" checkout --quiet -B feature; }

# Run the hook with a given command, from inside the home repo.
run_hook() {
  local cmd="$1"
  local json
  json=$(jq -n --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}')
  invoke_hook_in "$REPO" "$json" "$HOOK_ABS"
}



# --- denied ---

@test "git commit on main is denied" {
  on_main
  run_hook 'git commit -m "x"'
  assert_denied_by_json
}

@test "plain git push from main is denied" {
  on_main
  run_hook 'git push'
  assert_denied_by_json
}

@test "git push origin main (refspec) is denied from a feature branch" {
  on_feature
  run_hook 'git push origin main'
  assert_denied_by_json
}

@test "force-push to main is denied from a feature branch" {
  on_feature
  run_hook 'git push --force origin main'
  assert_denied_by_json
}

@test "home-repo git -C commit on main is denied" {
  on_main
  run_hook "git -C $REPO commit -m \"x\""
  assert_denied_by_json
}

# --- allowed ---

@test "git commit on a feature branch is allowed" {
  on_feature
  run_hook 'git commit -m "x"'
  assert_allowed_by_json
}

@test "git push origin feature from a feature branch is allowed" {
  on_feature
  run_hook 'git push origin feature'
  assert_allowed_by_json
}

@test "plain git push from a feature branch is allowed" {
  on_feature
  run_hook 'git push'
  assert_allowed_by_json
}

@test "foreign-repo commit is allowed even though it targets main" {
  on_main
  run_hook "git -C $FOREIGN commit -m \"x\""
  assert_allowed_by_json
}

@test "a non-git command is ignored" {
  on_main
  run_hook 'pnpm run build'
  assert_allowed_by_json
}

# --- setup standdown: the .gaia/local/setup-in-progress sentinel suspends ---
# enforcement for /setup-gaia's greenfield finalize commit+push, then resumes.

@test "setup sentinel allows git commit on main" {
  on_main
  mkdir -p "$REPO/.gaia/local"
  touch "$REPO/.gaia/local/setup-in-progress"
  run_hook 'git commit -m "x"'
  assert_allowed_by_json
}

@test "setup sentinel allows git push origin main from main" {
  on_main
  mkdir -p "$REPO/.gaia/local"
  touch "$REPO/.gaia/local/setup-in-progress"
  run_hook 'git push origin main'
  assert_allowed_by_json
}

@test "enforcement resumes once the setup sentinel is removed" {
  on_main
  mkdir -p "$REPO/.gaia/local"
  touch "$REPO/.gaia/local/setup-in-progress"
  run_hook 'git commit -m "x"'
  assert_allowed_by_json
  rm -f "$REPO/.gaia/local/setup-in-progress"
  run_hook 'git commit -m "x"'
  assert_denied_by_json
}

@test "setup sentinel is a total standdown: force-push to main is allowed" {
  on_main
  mkdir -p "$REPO/.gaia/local"
  touch "$REPO/.gaia/local/setup-in-progress"
  run_hook 'git push --force origin main'
  assert_allowed_by_json
}

@test "a stale setup sentinel self-heals: enforcement resumes without removal" {
  on_main
  mkdir -p "$REPO/.gaia/local"
  touch "$REPO/.gaia/local/setup-in-progress"
  # Age the sentinel past the freshness window. A leftover from a setup that
  # crashed before cleanup must NOT keep main-branch protection suspended.
  touch -t 200001010000 "$REPO/.gaia/local/setup-in-progress"
  run_hook 'git commit -m "x"'
  assert_denied_by_json
}

# --- command-position anchoring: the words appear, but git is not the program ---

@test "grep for the text 'git commit' is allowed on main" {
  on_main
  run_hook 'grep -n -e git commit app/foo.ts'
  assert_allowed_by_json
}

@test "echo of 'git push origin main' is allowed on main" {
  on_main
  run_hook 'echo "git push origin main"'
  assert_allowed_by_json
}

@test "echo 'git commit' piped to grep is allowed on main" {
  on_main
  run_hook 'echo git commit && grep -n foo bar'
  assert_allowed_by_json
}

# --- command-position anchoring still catches real invocations ---

@test "git commit after an unrelated piped command is denied on main" {
  on_main
  run_hook 'echo hi | git commit -m "x"'
  assert_denied_by_json
}

@test "git push origin main after && is denied" {
  on_feature
  run_hook 'true && git push origin main'
  assert_denied_by_json
}

# --- an unparseable repo-scope.sh degrades, it does not deny ---
#
# The repo-scope load sits under this hook's `set -euo pipefail`, so before the
# fix an unparseable copy abandoned the shell ahead of the `type
# cmd_targets_foreign_repo` check on the next line, exiting 2 -- the PreToolUse
# deny code -- for every git command the hook matches. It denies on bash 5 as
# well as on 3.2, so neither case below needs a /bin/bash pin to have teeth.
#
# The pair discriminates: the allow case alone is satisfied by a hook that
# stopped enforcing, so the deny twin proves the degrade kept the main-branch
# floor. Without cmd_targets_foreign_repo the foreign-repo carve-out does not
# fire, which is the fail-closed direction this hook documents at :21-24.

# Overwrites <path> with an unresolved-merge-conflict body: the file opens and
# reads fine, so an existence test passes it, and bash cannot parse it.
write_conflicted_lib() {
  { printf '<<<<<<< HEAD\n'; printf 'x() { :; }\n'; printf '=======\n'
    printf 'y() { :; }\n'; printf '>>>>>>> other\n'; } > "$1"
}

@test "repo-scope.sh holding conflict markers: an ordinary git command is still allowed" {
  on_feature
  write_conflicted_lib "$REPO/.claude/hooks/lib/repo-scope.sh"
  run_hook 'git status'
  assert_allowed_by_json
}

@test "repo-scope.sh holding conflict markers: a commit on main is still denied" {
  on_main
  write_conflicted_lib "$REPO/.claude/hooks/lib/repo-scope.sh"
  run_hook 'git commit -m "x"'
  assert_denied_by_json
}

@test "repo-scope.sh absent entirely: a commit on main is still denied" {
  on_main
  rm -f "$REPO/.claude/hooks/lib/repo-scope.sh"
  run_hook 'git commit -m "x"'
  assert_denied_by_json
}

# --- an unparseable main-root-lib.sh degrades, it does not deny ---
#
# The second load in this hook resolves .gaia/scripts/main-root-lib.sh off
# BASH_SOURCE, so expressing the unparseable case needs a COPY of the hook in a
# tree the test controls; running the real $HOOK_ABS would always resolve the
# real checkout's libs. Pinned to stock /bin/bash: the `|| true` arm this load
# already carried survives on bash 5 and is abandoned ahead of on 3.2, so only
# a /bin/bash run tells the fix apart from the arm it replaced. On a bash-5
# /bin/bash (Linux CI) these pass either way.

stage_hook_tree() {
  STAGED_ROOT="$BATS_TEST_TMPDIR/staged"
  rm -rf "$STAGED_ROOT"
  mkdir -p "$STAGED_ROOT/.claude/hooks/lib" "$STAGED_ROOT/.gaia/scripts"
  cp "$HOOK_ABS" "$STAGED_ROOT/.claude/hooks/"
  cp "$HOOKS_SRC/lib/repo-scope.sh" "$STAGED_ROOT/.claude/hooks/lib/"
  cp "${HOOKS_SRC%/.claude/hooks}/.gaia/scripts/main-root-lib.sh" "$STAGED_ROOT/.gaia/scripts/"
  git -C "$STAGED_ROOT" init --quiet --initial-branch=main
  git -C "$STAGED_ROOT" config user.email "test@example.com"
  git -C "$STAGED_ROOT" config user.name "Test"
  git -C "$STAGED_ROOT" config commit.gpgsign false
  echo "# readme" > "$STAGED_ROOT/README.md"
  git -C "$STAGED_ROOT" add README.md
  git -C "$STAGED_ROOT" commit --quiet -m init
  STAGED_HOOK="$STAGED_ROOT/.claude/hooks/block-main-destructive-git.sh"
}

# run_staged <command> [interpreter]
run_staged() {
  local json interp="${2:-}"
  json=$(jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}')
  run bash -c 'cd "$1" && printf %s "$2" | $4 "$3"' _ "$STAGED_ROOT" "$json" "$STAGED_HOOK" "$interp"
}

@test "control: the staged hook denies a commit on main under stock /bin/bash" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  stage_hook_tree
  run_staged 'git commit -m "x"' /bin/bash
  assert_denied_by_json
}

@test "main-root-lib.sh holding conflict markers: a commit on main is still denied, on stock /bin/bash" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  stage_hook_tree
  write_conflicted_lib "$STAGED_ROOT/.gaia/scripts/main-root-lib.sh"
  run_staged 'git commit -m "x"' /bin/bash
  assert_denied_by_json
}

@test "main-root-lib.sh holding conflict markers: an ordinary git command is still allowed, on stock /bin/bash" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  stage_hook_tree
  git -C "$STAGED_ROOT" checkout --quiet -B feature
  write_conflicted_lib "$STAGED_ROOT/.gaia/scripts/main-root-lib.sh"
  run_staged 'git status' /bin/bash
  assert_allowed_by_json
}
