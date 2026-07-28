#!/usr/bin/env bats
#
# Bats suite for .claude/hooks/capture-gh-artifact.sh, the PostToolUse hook
# that drops a breadcrumb when `gh pr create` succeeds. Every test runs the
# hook with cwd = a tmp git repo, never the real repo root, and points
# GAIA_GH_ARTIFACT_CACHE_DIR at a per-test tmp dir so no test ever touches the
# real .gaia/local/cache/.

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HOOK_ABS="$REPO_ROOT/.claude/hooks/capture-gh-artifact.sh"
  LIB_SRC="$REPO_ROOT/.gaia/scripts/gh-artifact-lib.sh"
  AKL_SRC="$REPO_ROOT/.gaia/scripts/audit-key-lib.sh"

  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"

  CACHE="$BATS_TEST_TMPDIR/cache"
  mkdir -p "$CACHE"
  export GAIA_GH_ARTIFACT_CACHE_DIR="$CACHE"
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
  cp "$LIB_SRC" "$REPO/.gaia/scripts/gh-artifact-lib.sh"
  cp "$AKL_SRC" "$REPO/.gaia/scripts/audit-key-lib.sh"
}

# run_hook <command> [stdout] [session_id]
run_hook() {
  local cmd="$1" out="${2:-}" sid="${3:-S1}" input
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use "$sid" Bash "$cmd" "$out")
  run bash -c "echo '$input' | '$HOOK_ABS'"
}

# run_hook_raw <json> - for payloads the helper's required-param mock cannot
# express (an empty session_id).
run_hook_raw() {
  local input="$1"
  run bash -c "echo '$input' | '$HOOK_ABS'"
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

  bc="$(breadcrumb_path "feat/x")"
  [ -f "$bc" ]
  jq -e '.number | type == "number"' "$bc" >/dev/null
  [ "$(jq -r '.type' "$bc")" = "pr" ]
  [ "$(jq -r '.number' "$bc")" = "712" ]
  [ "$(jq -r '.repo' "$bc")" = "gaia-react/gaia" ]
  [ "$(jq -r '.branch' "$bc")" = "feat/x" ]
  [ "$(jq -r '.session_id' "$bc")" = "S1" ]
  jq -e '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$bc" >/dev/null
  [ "$(jq -r 'keys | @csv' "$bc")" = '"branch","number","repo","session_id","ts","type"' ]
}

@test "a separator form (cd /tmp && gh pr create) also matches and writes" {
  build_repo
  cd "$REPO"
  git checkout -b feat/y --quiet

  run_hook "cd /tmp && gh pr create --title x" "https://github.com/gaia-react/gaia/pull/900"
  [ "$status" -eq 0 ]

  bc="$(breadcrumb_path "feat/y")"
  [ -f "$bc" ]
  [ "$(jq -r '.number' "$bc")" = "900" ]
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
  run bash -c "echo '$input' | '$HOOK_ABS'"
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

  nojq_bin="$BATS_TEST_TMPDIR/nojq-bin"
  mkdir -p "$nojq_bin"
  ln -sf "$(command -v bash)" "$nojq_bin/bash"
  ln -sf "$(command -v cat)" "$nojq_bin/cat"
  ln -sf "$(command -v git)" "$nojq_bin/git"

  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash "gh pr create --title x" \
    "https://github.com/gaia-react/gaia/pull/712")
  PATH="$nojq_bin" run bash -c "echo '$input' | '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  any_breadcrumb_exists && return 1
  return 0
}

@test "lib absent: exit 0, no file, no output" {
  REPO="$("$HELPERS/tmp-git-repo.sh")"
  cd "$REPO"
  git checkout -b feat/nolib --quiet

  run_hook "gh pr create --title x" "https://github.com/gaia-react/gaia/pull/712"
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
  jq -r '.hooks.PostToolUse[] | select(.matcher == "Bash") | .hooks[].command' \
    "$REPO_ROOT/.claude/settings.json" | grep -qF ".claude/hooks/capture-gh-artifact.sh"
}

@test "the hook file is executable" {
  [ -x "$HOOK_ABS" ]
}
