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
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
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

# A payload path can carry quotes of its own, so delivery goes through
# `invoke_hook` (helpers/run-hook.sh) rather than any local variant.
run_hook() {
  local project="$1" cwd="$2"
  local json
  json=$(jq -n --arg p "$project" --arg c "$cwd" \
    '{tool_name: "mcp__serena__activate_project", cwd: $c, tool_input: {project: $p}}')
  invoke_hook "$json" "$HOOK_ABS"
}

run_hook_other_tool() {
  local tool="$1" cwd="$2"
  local json
  json=$(jq -n --arg t "$tool" --arg c "$cwd" \
    '{tool_name: $t, cwd: $c, tool_input: {project: "gaia"}}')
  invoke_hook "$json" "$HOOK_ABS"
}



# --- NAME arm ---

@test "from a linked worktree, the bare name equal to the tree's own project_name is denied" {
  make_repo
  make_worktree "debt/1-foo" "debt/1-foo"
  run_hook "gaia" "$WT"
  assert_denied_by_json
  # The reason names the worktree's own root, the value to pass instead.
  grep -qF -- "$WT" <<<"$output" || return 1
}

@test "from a linked worktree, a name that is not the tree's project_name is allowed" {
  make_repo
  make_worktree "debt/2-foo" "debt/2-foo"
  run_hook "some-other-project" "$WT"
  assert_allowed_by_json
}

@test "from the main checkout, the bare name is allowed (the correct activation)" {
  make_repo
  make_worktree "debt/3-foo" "debt/3-foo"
  run_hook "gaia" "$REPO"
  assert_allowed_by_json
}

# --- PATH arm ---

@test "from a linked worktree, the main checkout's absolute path is denied" {
  make_repo
  make_worktree "debt/4-foo" "debt/4-foo"
  run_hook "$REPO" "$WT"
  assert_denied_by_json
  grep -qF -- "$WT" <<<"$output" || return 1
}

@test "from a linked worktree, a sibling worktree's absolute path is denied" {
  make_repo
  make_worktree "debt/5-a" "debt/5-a"
  WT_A="$WT"
  make_worktree "debt/5-b" "debt/5-b"
  run_hook "$WT_A" "$WT"
  assert_denied_by_json
}

@test "from a linked worktree, its own absolute path is allowed" {
  make_repo
  make_worktree "debt/6-foo" "debt/6-foo"
  run_hook "$WT" "$WT"
  assert_allowed_by_json
}

@test "from a linked worktree, an absolute path in a different repository is allowed" {
  make_repo
  make_worktree "debt/7-foo" "debt/7-foo"
  make_other_repo
  run_hook "$OTHER_REPO" "$WT"
  assert_allowed_by_json
}

@test "from the main checkout, a linked worktree's path is denied (the symmetric arm)" {
  make_repo
  make_worktree "debt/8-foo" "debt/8-foo"
  run_hook "$WT" "$REPO"
  assert_denied_by_json
}

# --- ignored / fail-open ---

@test "a payload for some other tool is a no-op (allowed)" {
  make_repo
  make_worktree "debt/9-foo" "debt/9-foo"
  run_hook_other_tool "mcp__serena__find_symbol" "$WT"
  assert_allowed_by_json
}

@test "a payload whose cwd is not a repository fails open (allowed)" {
  NONREPO=$(mktemp -d -t gaia-serena-guard-nonrepo-XXXXXX)
  # An unusable payload cwd (absolute but not a checkout) falls back to the
  # hook's own process cwd, so the process itself must sit in NONREPO too --
  # otherwise the fallback would land inside whatever real repository is
  # running this suite, which is not the state under test.
  cd "$NONREPO"
  run_hook "gaia" "$NONREPO"
  assert_allowed_by_json
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

# --- library-load degradation (gaia-react/gaia#1556) ------------------------
# These run a COPY of the hook staged inside the tmp repo, so the .gaia/scripts
# it resolves off BASH_SOURCE is one the test controls. Running $HOOK_ABS would
# always resolve the real checkout's libs, where neither the absent nor the
# unparseable case can be expressed.
#
# Two ways the resolver goes unusable, and this fail-open guard must allow
# through both: it is gone, and it is present but does not parse (an unresolved
# merge conflict, a truncated write). Under `set -e` a failed `.` abandons the
# shell in both cases, at different cost: a file bash cannot open exits 1, an
# advisory that lets the activation through with a raw diagnostic on stderr,
# while one it cannot parse exits 2, the PreToolUse deny code, which turns this
# fail-open guard into one that blocks a legitimate activation.
#
# The controls are what give the two cases teeth: their assertions (exit 0, no
# deny) are equally satisfied by a hook that adjudicates nothing at all, so each
# interpreter gets a control proving the same staging still DENIES.
stage_hook_repo() {
  make_repo
  mkdir -p "$REPO/.claude/hooks" "$REPO/.gaia/scripts"
  STAGED_HOOK="$REPO/.claude/hooks/block-serena-cross-tree-activation.sh"
  cp "$HOOK_ABS" "$STAGED_HOOK"
  chmod +x "$STAGED_HOOK"
  cp "${HOOKS_SRC%/.claude/hooks}/.gaia/scripts/main-root-lib.sh" "$REPO/.gaia/scripts/"
  make_worktree "debt/lib-degrade" "debt/lib-degrade"
}

# run_staged_hook <project> <cwd> [interpreter]
run_staged_hook() {
  local json interp="${3:-bash}"
  json=$(jq -n --arg p "$1" --arg c "$2" \
    '{tool_name: "mcp__serena__activate_project", cwd: $c, tool_input: {project: $p}}')
  run bash -c 'printf %s "$1" | "$3" "$2"' _ "$json" "$STAGED_HOOK" "$interp"
}

# Overwrites <path> with an unresolved-merge-conflict body: the file opens and
# reads fine, so an existence test passes it, and bash cannot parse it.
write_conflicted_lib() {
  { printf '<<<<<<< HEAD\n'; printf 'x() { :; }\n'; printf '=======\n'
    printf 'y() { :; }\n'; printf '>>>>>>> other\n'; } > "$1"
}

@test "staged hook, resolver usable: still denies (control)" {
  stage_hook_repo
  run_staged_hook "gaia" "$WT"
  assert_denied_by_json
}

# The stock-/bin/bash control. Without it the /bin/bash-pinned case below would
# stay green if the staged hook stopped adjudicating entirely under 3.2.
@test "staged hook under stock /bin/bash, resolver usable: still denies (control)" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  stage_hook_repo
  run_staged_hook "gaia" "$WT" /bin/bash
  assert_denied_by_json
}

# Pinned to stock /bin/bash: on 3.2.57 the shell abandons on the failed source
# before the trailing `||` arm on that line runs, where 5.x reaches it, so only
# a /bin/bash run reproduces this half of the class on a stock Mac. On a bash-5
# /bin/bash (Linux CI) it passes either way.
@test "staged hook whose main-root-lib.sh is absent, under stock /bin/bash: fails open, silently" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  stage_hook_repo
  rm -f "$REPO/.gaia/scripts/main-root-lib.sh"

  run_staged_hook "gaia" "$WT" /bin/bash
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# Pinned for the same reason the absent case is, and here it is the pin rather
# than the failure mode that decides. A syntax error does abort an errexit bash
# 5, but the form this load replaced carried `|| exit 0`, which bash 5 reaches
# on an unparseable lib, so an unpinned run of this case passes against the
# pre-change spelling too and proves nothing. Measured both ways: 3.2.57 exits
# 2 on the old form and 0 on the new, 5.3.15 exits 0 on both. On a bash-5
# /bin/bash (Linux CI) this passes either way, the same honest caveat the
# absent case carries.
@test "staged hook whose main-root-lib.sh holds conflict markers, under stock /bin/bash: fails open, silently" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  stage_hook_repo
  write_conflicted_lib "$REPO/.gaia/scripts/main-root-lib.sh"

  run_staged_hook "gaia" "$WT" /bin/bash
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
