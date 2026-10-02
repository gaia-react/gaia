#!/usr/bin/env bats
#
# Bats suite for .claude/hooks/capture-gh-artifact.sh, the PostToolUse hook
# that drops a breadcrumb when `gh pr create` succeeds. Every test runs the
# hook with cwd = a tmp git repo, never the real repo root, and points
# GAIA_GH_ARTIFACT_CACHE_DIR at a per-test tmp dir so no test ever touches the
# real .gaia/local/cache/.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  . "$REPO_ROOT/.gaia/tests/helpers/path.sh"
  HOOK_ABSOLUTE_PATH="$REPO_ROOT/.claude/hooks/capture-gh-artifact.sh"
  LIBRARY_SOURCE="$REPO_ROOT/.gaia/scripts/gh-artifact-lib.sh"
  AUDIT_KEY_LIBRARY_SOURCE="$REPO_ROOT/.gaia/scripts/audit-key-lib.sh"

  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"

  CACHE="$BATS_TEST_TMPDIR/cache"
  mkdir -p "$CACHE"
  export GAIA_GH_ARTIFACT_CACHE_DIR="$CACHE"
  # This suite runs the REAL hook, so the PR-to-branch edge would be written
  # into the real tree's ledger from every case. The seam keeps the existing
  # breadcrumb cases exactly as they were; the edge cases unset it.
  export GAIA_USAGE_HOOKS_DISABLE=1
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  return 0
}

# Scaffolds a tmp git repo with the real lib copied in at its repo-relative
# path, so the hook's `source .gaia/scripts/gh-artifact-lib.sh` resolves.
# Also copies audit-key-lib.sh beside it: gaia_gh_artifact_path sources it via
# BASH_SOURCE (the same idiom gaia_gh_artifact_cache_dir uses for
# main-root-lib.sh), so without its sibling present the hook's own internal
# source would fail and no breadcrumb would ever be written, breaking every
# "writes the breadcrumb" test below for a reason unrelated to what they mean
# to exercise. Sets $REPO.
build_repo() {
  REPO="$("$HELPERS/tmp-git-repo.sh")"
  mkdir -p "$REPO/.gaia/scripts"
  cp "$LIBRARY_SOURCE" "$REPO/.gaia/scripts/gh-artifact-lib.sh"
  cp "$AUDIT_KEY_LIBRARY_SOURCE" "$REPO/.gaia/scripts/audit-key-lib.sh"
}

# run_hook <command> [stdout] [session_id]
run_hook() {
  local command="$1" tool_output="${2:-}" session_id="${3:-S1}" input
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use "$session_id" Bash "$command" "$tool_output")
  invoke_hook "$input" "$HOOK_ABSOLUTE_PATH"
}

# run_hook_raw <json> - for payloads the helper's required-param mock cannot
# express (an empty session_id).
run_hook_raw() {
  local input="$1"
  invoke_hook "$input" "$HOOK_ABSOLUTE_PATH"
}

# breadcrumb_path <branch>: the exact keyed filename the hook (and the real
# gaia_gh_artifact_path) computes for <branch>. Sources the REAL, repo-level
# audit-key-lib.sh (not $REPO's copy) purely to compute the expected value
# with the same gaia_key_slug the production code calls, rather than keeping
# a second, potentially-drifting copy of the encoding rule in this test file.
breadcrumb_path() {
  local branch="$1"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/.gaia/scripts/audit-key-lib.sh"
  printf '%s/gh-artifact-pr.%s.json' "$CACHE" "$(gaia_key_slug "$branch")"
}

# any_breadcrumb_exists: true iff ANY gh-artifact-pr*.json breadcrumb sits in
# $CACHE, regardless of its branch-slug. The "should not write" tests below
# assert no breadcrumb was written at all, not merely that one specific keyed
# name is absent, so this is a stronger and simpler check than reconstructing
# an exact expected filename for every negative case (several of which never
# check out a named branch at all).
any_breadcrumb_exists() {
  compgen -G "$CACHE/gh-artifact-pr*.json" >/dev/null 2>&1
}

# ---------- It writes the breadcrumb when it should ----------

@test "writes the breadcrumb on a successful gh pr create" {
  build_repo
  cd "$REPO"
  git checkout -b feat/x --quiet

  run_hook "gh pr create --title x --body y" "https://github.com/gaia-react/gaia/pull/712"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  breadcrumb_file="$(breadcrumb_path "feat/x")"
  [ -f "$breadcrumb_file" ]
  jq -e '.number | type == "number"' "$breadcrumb_file" >/dev/null
  [ "$(jq -r '.type' "$breadcrumb_file")" = "pr" ]
  [ "$(jq -r '.number' "$breadcrumb_file")" = "712" ]
  [ "$(jq -r '.repo' "$breadcrumb_file")" = "gaia-react/gaia" ]
  [ "$(jq -r '.branch' "$breadcrumb_file")" = "feat/x" ]
  [ "$(jq -r '.session_id' "$breadcrumb_file")" = "S1" ]
  jq -e '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$breadcrumb_file" >/dev/null
  [ "$(jq -r 'keys | @csv' "$breadcrumb_file")" = '"branch","number","repo","session_id","ts","type"' ]
}

@test "a separator form (cd /tmp && gh pr create) also matches and writes" {
  build_repo
  cd "$REPO"
  git checkout -b feat/y --quiet

  run_hook "cd /tmp && gh pr create --title x" "https://github.com/gaia-react/gaia/pull/900"
  [ "$status" -eq 0 ]

  breadcrumb_file="$(breadcrumb_path "feat/y")"
  [ -f "$breadcrumb_file" ]
  [ "$(jq -r '.number' "$breadcrumb_file")" = "900" ]
}

# ---------- It does NOT write when it should not ----------

@test "gh issue create writes nothing (forensics write-allowlist stays intact)" {
  build_repo
  cd "$REPO"
  git checkout -b feat/issue --quiet

  run_hook "gh issue create --repo gaia-react/gaia --label gaia-forensics --title t --body-file f" \
    "https://github.com/gaia-react/gaia/issues/415"
  [ "$status" -eq 0 ]

  any_breadcrumb_exists && return 1
  return 0
}

@test "a non-Bash tool call: exit 0, no file" {
  build_repo
  cd "$REPO"
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Edit "gh pr create")
  invoke_hook "$input" "$HOOK_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]

  any_breadcrumb_exists && return 1
  return 0
}

@test "a prose mention with no shell separator: exit 0, no file" {
  build_repo
  cd "$REPO"
  run_hook 'git commit -m "run gh pr create next"' ""
  [ "$status" -eq 0 ]

  any_breadcrumb_exists && return 1
  return 0
}

# ---------- Shared arming decision (data proof, bound, tokenizer) ----------

@test "a real gh pr create heredoc body (cat-to-file) is proven data: no file, and the same text without it writes" {
  build_repo
  cd "$REPO"
  git checkout -b feat/heredoc --quiet

  heredoc_command=$'cat > /tmp/notes.txt <<EOF\ngh pr create --title x\nEOF'
  run_hook "$heredoc_command" "https://github.com/gaia-react/gaia/pull/712"
  [ "$status" -eq 0 ]
  any_breadcrumb_exists && return 1

  run_hook "gh pr create --title x" "https://github.com/gaia-react/gaia/pull/712"
  [ "$status" -eq 0 ]
  [ -f "$(breadcrumb_path "feat/heredoc")" ]
}

@test "the same heredoc-body payload padded past the arming bound does write" {
  build_repo
  cd "$REPO"
  git checkout -b feat/overbound --quiet

  local pad heredoc_command
  pad=$(printf 'x%.0s' $(seq 1 16400))
  heredoc_command=$'cat > /tmp/notes.txt <<EOF\n'"$pad"$'\ngh pr create --title x\nEOF'
  [ "${#heredoc_command}" -gt 16384 ] || return 1

  run_hook "$heredoc_command" "https://github.com/gaia-react/gaia/pull/712"
  [ "$status" -eq 0 ]
  [ -f "$(breadcrumb_path "feat/overbound")" ]
}

@test "a quoted verb in the first command writes (tokenizer arm; red before this change)" {
  build_repo
  cd "$REPO"
  git checkout -b feat/quoted --quiet

  run_hook 'gh pr "create" --title x' "https://github.com/gaia-react/gaia/pull/712"
  [ "$status" -eq 0 ]
  [ -f "$(breadcrumb_path "feat/quoted")" ]
}

@test "a multi-statement command still writes (no regression)" {
  build_repo
  cd "$REPO"
  git checkout -b feat/multi --quiet

  run_hook "echo start && gh pr create --title x" "https://github.com/gaia-react/gaia/pull/712"
  [ "$status" -eq 0 ]
  [ -f "$(breadcrumb_path "feat/multi")" ]
}

@test "a failed gh pr create (empty stdout): exit 0, no file" {
  build_repo
  cd "$REPO"
  run_hook "gh pr create --title x --body y" ""
  [ "$status" -eq 0 ]

  any_breadcrumb_exists && return 1
  return 0
}

@test "gh pr create whose stdout carries no parseable URL: exit 0, no file" {
  build_repo
  cd "$REPO"
  run_hook "gh pr create --title x --body y" "Creating pull request..."
  [ "$status" -eq 0 ]

  any_breadcrumb_exists && return 1
  return 0
}

@test "detached HEAD: exit 0, no file (the lib refuses an empty branch)" {
  build_repo
  cd "$REPO"
  git checkout --detach --quiet

  run_hook "gh pr create --title x --body y" "https://github.com/gaia-react/gaia/pull/712"
  [ "$status" -eq 0 ]

  any_breadcrumb_exists && return 1
  return 0
}

@test "empty session_id: exit 0, no file" {
  build_repo
  cd "$REPO"
  git checkout -b feat/nosid --quiet

  input=$(jq -n --arg t "Bash" --arg c "gh pr create --title x --body y" \
    --arg o "https://github.com/gaia-react/gaia/pull/712" \
    '{session_id: "", transcript_path: "/tmp/transcript.jsonl", cwd: ".",
      hook_event_name: "PostToolUse", tool_name: $t, tool_input: {command: $c},
      tool_response: {stdout: $o, stderr: "", interrupted: false}}')
  run_hook_raw "$input"
  [ "$status" -eq 0 ]

  any_breadcrumb_exists && return 1
  return 0
}

@test "jq absent on PATH: exit 0, no file, no output" {
  build_repo
  cd "$REPO"
  git checkout -b feat/nojq --quiet

  nojq_bin="$(path_allowlist bash cat git)"

  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash "gh pr create --title x" \
    "https://github.com/gaia-react/gaia/pull/712")
  PATH="$nojq_bin" invoke_hook "$input" "$HOOK_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  any_breadcrumb_exists && return 1
  return 0
}

@test "lib absent: exit 0, no file, no output" {
  # The hook resolves gh-artifact-lib.sh off its OWN location, so an absent lib
  # is expressed by staging a copy of the hook in a tree that does not carry
  # one. Running $HOOK_ABSOLUTE_PATH from a lib-less working directory would not express
  # it: that reaches the real checkout's lib and records normally, which is the
  # whole point of the rooting. `stage_hook_repo` is reused rather than a bare
  # tmp repo so the verb-arming load still resolves and the hook reaches the
  # gh-artifact load this case is about.
  stage_hook_repo
  rm -f "$REPO/.gaia/scripts/gh-artifact-lib.sh"
  cd "$REPO"
  git checkout -b feat/nolib --quiet

  run_staged_hook "gh pr create --title x" "https://github.com/gaia-react/gaia/pull/712"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  any_breadcrumb_exists && return 1
  return 0
}

# ---------- Injection safety ----------

@test "injection: command substitution in the repo slug never executes and writes no breadcrumb" {
  build_repo
  cd "$REPO"
  git checkout -b feat/inject --quiet

  run_hook "gh pr create --title x" 'https://github.com/o$(touch CANARY)/n/pull/1'
  [ "$status" -eq 0 ]

  [ -e "$REPO/CANARY" ] && return 1
  any_breadcrumb_exists && return 1
  [ -e "$CACHE/CANARY" ] && return 1
  return 0
}

@test "injection: a shell metacharacter in the repo slug writes no breadcrumb" {
  build_repo
  cd "$REPO"
  git checkout -b feat/inject2 --quiet

  run_hook "gh pr create --title x" "https://github.com/o;id/n/pull/1"
  [ "$status" -eq 0 ]

  any_breadcrumb_exists && return 1
  return 0
}

# ---------- Registration ----------

@test "registered in .claude/settings.json's PostToolUse Bash matcher" {
  hook_registered "$REPO_ROOT/.claude/settings.json" \
    '.hooks.PostToolUse[] | select(.matcher == "Bash")' capture-gh-artifact.sh
}

@test "the hook file is executable" {
  [ -x "$HOOK_ABSOLUTE_PATH" ]
}

# The verb-arming load resolves off the hook's own BASH_SOURCE, so corrupting
# it needs a COPY of the hook staged inside the tmp repo. $HOOK_ABSOLUTE_PATH would
# always reach the real checkout's lib, where the case cannot be expressed.
stage_hook_repo() {
  build_repo
  mkdir -p "$REPO/.claude/hooks/lib"
  cp "$REPO_ROOT/.claude/hooks/lib/verb-arming.sh" "$REPO/.claude/hooks/lib/"
  cp "$REPO_ROOT/.claude/hooks/lib/verb-arming-walk.sh" "$REPO/.claude/hooks/lib/"
  cp "$REPO_ROOT/.claude/hooks/lib/repo-scope.sh" "$REPO/.claude/hooks/lib/"
  STAGED_HOOK="$REPO/.claude/hooks/capture-gh-artifact.sh"
  cp "$HOOK_ABSOLUTE_PATH" "$STAGED_HOOK"
  chmod +x "$STAGED_HOOK"
}

# run_staged_hook <command> <stdout> [interpreter]
run_staged_hook() {
  local input interpreter="${3:-bash}"
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash "$1" "$2")
  run bash -c 'printf %s "$1" | "$3" "$2"' _ "$input" "$STAGED_HOOK" "$interpreter"
}

# ---------- The PR-to-branch edge in the usage ledger ----------

edge_file() { printf '%s/.gaia/local/telemetry/links.jsonl' "$REPO"; }

@test "gh pr create records the pr:<N> to branch edge, normalizing a worktree branch spelling" {
  build_repo
  cd "$REPO"
  unset GAIA_USAGE_HOOKS_DISABLE
  git checkout -b worktree-debt+42-fix --quiet

  run_hook "gh pr create --title x --body y" "https://github.com/gaia-react/gaia/pull/77"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  [ "$(jq -sc '[.[] | [.kind, .child, .parent, .source]]' "$(edge_file)")" = '[["edge","pr:77","branch:debt/42-fix","gh-pr-create"]]' ]
  [ -f "$(breadcrumb_path "worktree-debt+42-fix")" ]
}

@test "gh pr create with a repo flag records no pr:<N> edge, in any flag spelling" {
  build_repo
  cd "$REPO"
  unset GAIA_USAGE_HOOKS_DISABLE
  git checkout -b feat/foreign --quiet

  run_hook "gh pr create --repo x/y --title t" "https://github.com/x/y/pull/79"
  [ "$status" -eq 0 ]
  run_hook "gh pr create -R x/y --title t" "https://github.com/x/y/pull/80"
  run_hook "gh pr create --title t --repo=x/y" "https://github.com/x/y/pull/81"
  [ ! -f "$(edge_file)" ] || ! grep -q '"pr:' "$(edge_file)"
}

@test "gh pr create with a multi-line body before a repo flag records no pr:<N> edge" {
  build_repo
  cd "$REPO"
  unset GAIA_USAGE_HOOKS_DISABLE
  git checkout -b feat/foreign-body --quiet

  run_hook $'gh pr create --title t --body "line one\nline two" --repo x/y' "https://github.com/x/y/pull/82"
  [ "$status" -eq 0 ]
  run_hook $'gh pr create --body "line one\nline two" -Rx/y' "https://github.com/x/y/pull/83"
  [ ! -f "$(edge_file)" ] || ! grep -q '"pr:' "$(edge_file)"
}

@test "an unwritable breadcrumb cache never drops the edge" {
  build_repo
  cd "$REPO"
  unset GAIA_USAGE_HOOKS_DISABLE
  git checkout -b feat/edge --quiet
  : >"$BATS_TEST_TMPDIR/not-a-dir"
  export GAIA_GH_ARTIFACT_CACHE_DIR="$BATS_TEST_TMPDIR/not-a-dir/cache"

  run_hook "gh pr create --title x --body y" "https://github.com/gaia-react/gaia/pull/78"
  [ "$status" -eq 0 ]

  [ "$(jq -sc '[.[] | [.child, .parent]]' "$(edge_file)")" = '[["pr:78","branch:feat/edge"]]' ]
  any_breadcrumb_exists && return 1
  return 0
}

@test "the test seam keeps the edge unwritten" {
  build_repo
  cd "$REPO"
  git checkout -b feat/seam --quiet

  run_hook "gh pr create --title x --body y" "https://github.com/gaia-react/gaia/pull/79"
  [ "$status" -eq 0 ]

  [ ! -e "$(edge_file)" ]
  [ -f "$(breadcrumb_path "feat/seam")" ]
}

@test "jq absent on PATH: no edge is written" {
  build_repo
  cd "$REPO"
  unset GAIA_USAGE_HOOKS_DISABLE
  git checkout -b feat/nojq-edge --quiet

  nojq_bin="$(path_allowlist bash cat git)"
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash "gh pr create --title x" \
    "https://github.com/gaia-react/gaia/pull/80")
  PATH="$nojq_bin" invoke_hook "$input" "$HOOK_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  [ ! -e "$(edge_file)" ]
}
