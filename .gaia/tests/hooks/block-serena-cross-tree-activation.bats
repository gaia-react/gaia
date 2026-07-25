#!/usr/bin/env bats

# Tests for .claude/hooks/block-serena-cross-tree-activation.sh.
#
# Serena is registered without --project-from-cwd, so an agent must call
# activate_project explicitly, by name or by absolute path. A bare NAME
# resolves through Serena's own machine-global registry to whichever checkout
# first registered it; .serena/project.yml is tracked, so every linked
# worktree of this clone carries the SAME name, and the registry answers with
# the main checkout regardless of which tree the session is acting in. This
# guard denies the activation call before that silent wrong-tree binding can
# happen, in both the name and the path form.
#
# Assertion style note: per .claude/rules/bats-assertions.md, non-final
# absence checks use a positive match for the bad case plus an explicit
# `return 1`, never `!`-negation.

setup() {
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABS="$HOOKS_SRC/block-serena-cross-tree-activation.sh"
  SETTINGS_ABS="${HOOKS_SRC%/hooks}/settings.json"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  [ -n "${NONREPO:-}" ] && rm -rf "$NONREPO"
  [ -n "${OTHER_REPO:-}" ] && rm -rf "$OTHER_REPO"
  return 0
}

# Canonicalize via `pwd -P` (mirrors block-worktree-path-mismatch.bats):
# macOS resolves /var -> /private/var inside `git rev-parse`, and the hook
# compares its own git-derived paths against this raw REPO value, so a
# non-canonical tmp path would desync from what the hook reports and produce
# a false mismatch that has nothing to do with the guard under test.
make_repo() {
  REPO_RAW=$(mktemp -d -t gaia-serena-guard-repo-XXXXXX)
  REPO="$(cd "$REPO_RAW" && pwd -P)"
  git -C "$REPO" init -q --initial-branch=main
  git -C "$REPO" config user.email test@example.com
  git -C "$REPO" config user.name Test
  git -C "$REPO" config commit.gpgsign false
  mkdir -p "$REPO/.serena"
  printf 'project_name: "gaia"\n' > "$REPO/.serena/project.yml"
  echo init > "$REPO/f"
  git -C "$REPO" add f .serena/project.yml
  git -C "$REPO" commit -q -m init
}

# make_worktree <rel> <branch>: a real linked worktree at
# <REPO>/.claude/worktrees/<rel>, mirroring how GAIA creates plan/debt
# worktrees. Sets WT to the worktree's absolute path.
make_worktree() {
  local rel="$1" br="$2"
  git -C "$REPO" branch "$br"
  mkdir -p "$REPO/.claude/worktrees"
  git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/$rel" "$br"
  WT="$REPO/.claude/worktrees/$rel"
}

# An unrelated git repository, used to check that a path in a different clone
# entirely is not this guard's concern.
make_other_repo() {
  local raw
  raw=$(mktemp -d -t gaia-serena-guard-other-XXXXXX)
  OTHER_REPO="$(cd "$raw" && pwd -P)"
  git -C "$OTHER_REPO" init -q --initial-branch=main
}

# Quote-safe delivery (mandatory, mirrors block-worktree-path-mismatch.bats):
# pass $json and $HOOK_ABS as positional args to an inner bash -c rather than
# re-wrapping in an outer single-quoted string, so embedded quotes in a
# payload path never terminate the wrapper early.
run_hook() {
  local project="$1" cwd="$2"
  local json
  json=$(jq -n --arg p "$project" --arg c "$cwd" \
    '{tool_name: "mcp__serena__activate_project", cwd: $c, tool_input: {project: $p}}')
  run bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$HOOK_ABS"
}

run_hook_other_tool() {
  local tool="$1" cwd="$2"
  local json
  json=$(jq -n --arg t "$tool" --arg c "$cwd" \
    '{tool_name: $t, cwd: $c, tool_input: {project: "gaia"}}')
  run bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$HOOK_ABS"
}

assert_denied() {
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output"
}

assert_allowed() {
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" && return 1
  return 0
}

# --- NAME arm ---

@test "from a linked worktree, the bare name equal to the tree's own project_name is denied" {
  make_repo
  make_worktree "debt/1-foo" "debt/1-foo"
  run_hook "gaia" "$WT"
  assert_denied
  # The reason names the worktree's own root, the value to pass instead.
  grep -qF -- "$WT" <<<"$output" || return 1
}

@test "from a linked worktree, a name that is not the tree's project_name is allowed" {
  make_repo
  make_worktree "debt/2-foo" "debt/2-foo"
  run_hook "some-other-project" "$WT"
  assert_allowed
}

@test "from the main checkout, the bare name is allowed (the correct activation)" {
  make_repo
  make_worktree "debt/3-foo" "debt/3-foo"
  run_hook "gaia" "$REPO"
  assert_allowed
}

# --- PATH arm ---

@test "from a linked worktree, the main checkout's absolute path is denied" {
  make_repo
  make_worktree "debt/4-foo" "debt/4-foo"
  run_hook "$REPO" "$WT"
  assert_denied
  grep -qF -- "$WT" <<<"$output" || return 1
}

@test "from a linked worktree, a sibling worktree's absolute path is denied" {
  make_repo
  make_worktree "debt/5-a" "debt/5-a"
  WT_A="$WT"
  make_worktree "debt/5-b" "debt/5-b"
  run_hook "$WT_A" "$WT"
  assert_denied
}

@test "from a linked worktree, its own absolute path is allowed" {
  make_repo
  make_worktree "debt/6-foo" "debt/6-foo"
  run_hook "$WT" "$WT"
  assert_allowed
}

@test "from a linked worktree, an absolute path in a different repository is allowed" {
  make_repo
  make_worktree "debt/7-foo" "debt/7-foo"
  make_other_repo
  run_hook "$OTHER_REPO" "$WT"
  assert_allowed
}

@test "from the main checkout, a linked worktree's path is denied (the symmetric arm)" {
  make_repo
  make_worktree "debt/8-foo" "debt/8-foo"
  run_hook "$WT" "$REPO"
  assert_denied
}

# --- ignored / fail-open ---

@test "a payload for some other tool is a no-op (allowed)" {
  make_repo
  make_worktree "debt/9-foo" "debt/9-foo"
  run_hook_other_tool "mcp__serena__find_symbol" "$WT"
  assert_allowed
}

@test "a payload whose cwd is not a repository fails open (allowed)" {
  NONREPO=$(mktemp -d -t gaia-serena-guard-nonrepo-XXXXXX)
  # An unusable payload cwd (absolute but not a checkout) falls back to the
  # hook's own process cwd, so the process itself must sit in NONREPO too --
  # otherwise the fallback would land inside whatever real repository is
  # running this suite, which is not the state under test.
  cd "$NONREPO"
  run_hook "gaia" "$NONREPO"
  assert_allowed
}

# --- structural ---

@test "block-serena-cross-tree-activation.sh is executable" {
  [ -x "$HOOK_ABS" ]
}

@test "settings.json is valid JSON" {
  run jq empty "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}

@test "settings.json registers the hook under the mcp__serena__activate_project matcher" {
  run jq -e '.hooks.PreToolUse[] | select(.matcher == "mcp__serena__activate_project") | .hooks[] | select(.command == ".claude/hooks/block-serena-cross-tree-activation.sh")' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}
