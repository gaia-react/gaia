#!/usr/bin/env bats

# Tests for .claude/hooks/block-main-destructive-git.sh. The hook's own header
# states what it blocks. It fires only on a real `git` INVOCATION in command
# position; command text that merely mentions `git commit` / `git push` (a grep
# pattern, an echo string, an argument to another program) does not trip it.
#
# Each test drives the hook as the harness does: a PreToolUse JSON payload on
# stdin, run with the repo as the working directory, which is where the hook
# resolves the current branch. The hook always exits 0; allow vs deny is carried
# in stdout.

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
  # The jq-availability arm runs ahead of the repo-scope load and refuses when
  # it cannot find its own library, so a staged tree without it answers every
  # case here with that refusal instead of the decision under test.
  cp "$HOOKS_SRC/lib/jq-availability.sh" "$REPO/.claude/hooks/lib/jq-availability.sh"

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

# `-C` after the subcommand is commit's reuse-message option, not a directory.
@test "git commit -C HEAD on main is denied" {
  on_main
  run_hook 'git commit --allow-empty -C HEAD'
  assert_denied_by_json
  run_hook 'git commit --allow-empty -m x -C HEAD'
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
  cp "$HOOKS_SRC/lib/jq-availability.sh" "$STAGED_ROOT/.claude/hooks/lib/"
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

# --- main-checkout hop guard ---
#
# A peer session moving the main checkout's HEAD off a branch another session
# holds there with an open pull request is denied. `gh` is a stub on PATH whose
# answer GH_STUB selects: `open:<n>` lists one open pull request, `none` lists
# nothing (merged, closed, never opened), `fail` exits non-zero, `hang` never
# answers, `garbage` answers with something that is not a number. The owner is
# proved by the `gh pr create` breadcrumb, written here through the same lib the
# capture hook writes it with, so the path and shape cannot drift from the
# reader's.

stub_gh() {
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  cat >"$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = "pr list" ] || exit 1
case "${GH_STUB:-none}" in
  open:*) printf '%s\n' "${GH_STUB#open:}" ;;
  none) ;;
  fail) echo "gh: authentication required" >&2; exit 4 ;;
  hang) exec sleep 30 ;;
  garbage) echo "not-a-number" ;;
esac
STUB
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
}

# hold_feature_with_pr <number>: the main checkout sits on `feature`, a second
# branch `other` exists to switch to, and `feature` has an open pull request.
hold_feature_with_pr() {
  stub_gh
  git -C "$REPO" branch --quiet other
  git -C "$REPO" checkout --quiet -B feature
  export GH_STUB="open:$1"
}

write_breadcrumb() {
  local branch="$1" sid="$2" bc_path
  # shellcheck source=/dev/null
  . "${HOOKS_SRC%/.claude/hooks}/.gaia/scripts/gh-artifact-lib.sh"
  bc_path="$(gaia_gh_artifact_path "$REPO/.gaia/local/cache" "$branch")"
  gaia_gh_artifact_write "$bc_path" 42 example/repo "$branch" "$sid"
}

# run_hop <command> [session_id] [cwd]
run_hop() {
  local json
  json=$(jq -n --arg c "$1" --arg s "${2:-sid-peer}" --arg d "${3:-$REPO}" \
    '{tool_name: "Bash", session_id: $s, cwd: $d, tool_input: {command: $c}}')
  invoke_hook_in "${3:-$REPO}" "$json" "$HOOK_ABS"
}

@test "hop guard: a peer switching the main checkout off a branch with an open PR is denied" {
  hold_feature_with_pr 42
  write_breadcrumb feature sid-owner
  run_hop 'git switch other' sid-peer
  assert_denied_by_json
  grep -qF -- "'feature'" <<<"$output"
  grep -qF -- '#42' <<<"$output"
  grep -qF -- 'worktree arm' <<<"$output"
  grep -qF -- 'with the ! prefix' <<<"$output"
}

@test "hop guard: a peer's git checkout main off a branch with an open PR is denied" {
  hold_feature_with_pr 42
  write_breadcrumb feature sid-owner
  run_hop 'git checkout main' sid-peer
  assert_denied_by_json
  run_hop 'git checkout main 2>/dev/null' sid-peer
  assert_denied_by_json
  run_hop 'git checkout main > /dev/null' sid-peer
  assert_denied_by_json
}

@test "hop guard: git checkout -b, -, and --detach in a peer-held main checkout are denied" {
  hold_feature_with_pr 42
  run_hop 'git checkout -b brand-new' sid-peer
  assert_denied_by_json
  run_hop 'git checkout -' sid-peer
  assert_denied_by_json
  run_hop 'git checkout --detach' sid-peer
  assert_denied_by_json
}

# `-C` after `switch` is force-create, not a directory, so reading it as git's
# own `-C` aimed the guard at a directory named for the branch and let it pass.
@test "hop guard: git switch -C in a peer-held main checkout is denied" {
  hold_feature_with_pr 42
  run_hop 'git switch -C other' sid-peer
  assert_denied_by_json
  run_hop 'git switch -C main main' sid-peer
  assert_denied_by_json
  local wt="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$wt"
  run_hop "git -C $REPO switch -C other" sid-peer "$wt"
  assert_denied_by_json
}

@test "hop guard: git's own options ahead of the subcommand do not hide it" {
  hold_feature_with_pr 42
  run_hop 'git -c advice.detachedHead=false switch other' sid-peer
  assert_denied_by_json
  run_hop 'git --git-dir .git checkout main' sid-peer
  assert_denied_by_json
}

@test "hop guard: a checkout aimed at a different repository's main checkout is allowed" {
  hold_feature_with_pr 42
  git -C "$FOREIGN" commit --quiet --allow-empty -m init
  git -C "$FOREIGN" branch --quiet other
  git -C "$FOREIGN" checkout --quiet -B feature
  run_hop "git -C $FOREIGN switch other" sid-peer
  assert_allowed_by_json
}

@test "hop guard: a worktree session aiming git -C at the peer-held main checkout is denied" {
  hold_feature_with_pr 42
  local wt="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$wt"
  run_hop "git -C $REPO checkout main" sid-peer "$wt"
  assert_denied_by_json
}

@test "hop guard: the session that created the PR may hop off its own branch" {
  hold_feature_with_pr 42
  write_breadcrumb feature sid-owner
  run_hop 'git switch other' sid-owner
  assert_allowed_by_json
}

@test "hop guard: the owner is matched before any gh call" {
  hold_feature_with_pr 42
  write_breadcrumb feature sid-owner
  export GH_STUB=hang
  local start=$SECONDS
  run_hop 'git switch other' sid-owner
  assert_allowed_by_json
  grep -qF -- 'timed out' <<<"$output" && return 1
  [ $((SECONDS - start)) -lt 4 ]
}

@test "hop guard: a missing breadcrumb counts as not the owner" {
  hold_feature_with_pr 42
  run_hop 'git switch other' sid-owner
  assert_denied_by_json
}

@test "hop guard: a branch whose PR is merged or closed is allowed" {
  hold_feature_with_pr 42
  export GH_STUB=none
  run_hop 'git checkout main' sid-peer
  assert_allowed_by_json
}

@test "hop guard: a gh failure fails open with one stderr line naming the cause" {
  hold_feature_with_pr 42
  export GH_STUB=fail
  run_hop 'git checkout main' sid-peer
  assert_allowed_by_json
  grep -qF -- 'could not check' <<<"$output"
  grep -qF -- 'exited 4' <<<"$output"
}

@test "hop guard: a gh answer that is not a PR number fails open" {
  hold_feature_with_pr 42
  export GH_STUB=garbage
  run_hop 'git checkout main' sid-peer
  assert_allowed_by_json
  grep -qF -- 'could not check' <<<"$output"
}

@test "hop guard: a gh call that never answers is cut off and fails open" {
  hold_feature_with_pr 42
  export GH_STUB=hang
  local start=$SECONDS
  run_hop 'git checkout main' sid-peer
  assert_allowed_by_json
  grep -qF -- 'timed out' <<<"$output"
  [ $((SECONDS - start)) -lt 20 ]
}

@test "hop guard: gh missing from PATH fails open with the named cause" {
  hold_feature_with_pr 42
  # A PATH holding every tool the hook and its libraries call, and no gh.
  local tools="$BATS_TEST_TMPDIR/tools" tool src
  mkdir -p "$tools"
  for tool in bash cat jq git sed tr dirname basename find env mkdir grep head \
      wc date sleep rm shasum sha256sum perl awk; do
    src=$(command -v "$tool" 2>/dev/null) || continue
    ln -s "$src" "$tools/$tool"
  done
  PATH="$tools" run_hop 'git checkout main' sid-peer
  assert_allowed_by_json
  grep -qF -- 'gh is not on PATH' <<<"$output"
}

@test "hop guard: an unloadable breadcrumb library fails open with the named cause" {
  stage_hook_tree
  stub_gh
  export GH_STUB=open:42
  git -C "$STAGED_ROOT" branch --quiet other
  git -C "$STAGED_ROOT" checkout --quiet -B feature
  [ ! -e "$STAGED_ROOT/.gaia/scripts/gh-artifact-lib.sh" ]
  run_staged 'git switch other'
  assert_allowed_by_json
  grep -qF -- 'gh-artifact-lib.sh did not load' <<<"$output"
}

@test "hop guard: a checkout run inside a linked worktree is allowed" {
  hold_feature_with_pr 42
  local wt="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$wt"
  run_hop 'git switch other' sid-peer "$wt"
  assert_allowed_by_json
}

@test "hop guard: path-restore forms are allowed" {
  hold_feature_with_pr 42
  run_hop 'git checkout -- README.md' sid-peer
  assert_allowed_by_json
  run_hop 'git checkout main -- README.md' sid-peer
  assert_allowed_by_json
  run_hop 'git checkout -p main' sid-peer
  assert_allowed_by_json
  run_hop 'git checkout -- main' sid-peer
  assert_allowed_by_json
  run_hop 'git checkout main README.md' sid-peer
  assert_allowed_by_json
  run_hop 'git checkout README.md' sid-peer
  assert_allowed_by_json
}

@test "hop guard: hopping off the default branch is allowed" {
  hold_feature_with_pr 42
  git -C "$REPO" checkout --quiet main
  run_hop 'git switch other' sid-peer
  assert_allowed_by_json
}

@test "hop guard: hopping off the default branch origin/HEAD names is allowed" {
  hold_feature_with_pr 42
  git -C "$REPO" checkout --quiet -B trunk
  git -C "$REPO" update-ref refs/remotes/origin/trunk HEAD
  git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
  run_hop 'git switch other' sid-peer
  assert_allowed_by_json
}

@test "hop guard: hopping off a detached HEAD is allowed" {
  hold_feature_with_pr 42
  git -C "$REPO" checkout --quiet --detach
  run_hop 'git switch other' sid-peer
  assert_allowed_by_json
}
