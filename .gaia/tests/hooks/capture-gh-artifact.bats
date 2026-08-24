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
  invoke_hook "$input" "$HOOK_ABS"
}

# run_hook_raw <json> - for payloads the helper's required-param mock cannot
# express (an empty session_id).
run_hook_raw() {
  local input="$1"
  invoke_hook "$input" "$HOOK_ABS"
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
  invoke_hook "$input" "$HOOK_ABS"
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

  heredoc_cmd=$'cat > /tmp/notes.txt <<EOF\ngh pr create --title x\nEOF'
  run_hook "$heredoc_cmd" "https://github.com/gaia-react/gaia/pull/712"
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

  local pad heredoc_cmd
  pad=$(printf 'x%.0s' $(seq 1 16400))
  heredoc_cmd=$'cat > /tmp/notes.txt <<EOF\n'"$pad"$'\ngh pr create --title x\nEOF'
  [ "${#heredoc_cmd}" -gt 16384 ] || return 1

  run_hook "$heredoc_cmd" "https://github.com/gaia-react/gaia/pull/712"
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

  nojq_bin="$BATS_TEST_TMPDIR/nojq-bin"
  mkdir -p "$nojq_bin"
  ln -sf "$(command -v bash)" "$nojq_bin/bash"
  ln -sf "$(command -v cat)" "$nojq_bin/cat"
  ln -sf "$(command -v git)" "$nojq_bin/git"

  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash "gh pr create --title x" \
    "https://github.com/gaia-react/gaia/pull/712")
  PATH="$nojq_bin" invoke_hook "$input" "$HOOK_ABS"
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

# ---------- library-load degradation (gaia-react/gaia#1556) ----------
# Two ways a library goes unusable, and this hook's header contract ("degrade
# silently, never write to stdout, always exit 0") must hold through both: it
# is gone, and it is present but does not parse (an unresolved merge conflict,
# a truncated write). Under `set -e` a failed `.` abandons the shell ahead of
# the ERR trap in both cases, at different cost: a file bash cannot open exits
# 1, and one it cannot parse exits 2.
#
# The two loads sit on opposite sides of the arming gate and take different
# repairs, so each gets its own case. gh-artifact-lib.sh is past the gate and
# parse-checks; verb-arming.sh runs on every Bash tool call and takes the free
# `|| true` arm instead, which closes the bash 5 half only.

# Overwrites <path> with an unresolved-merge-conflict body: the file opens and
# reads fine, so an existence test passes it, and bash cannot parse it.
write_conflicted_lib() {
  { printf '<<<<<<< HEAD\n'; printf 'x() { :; }\n'; printf '=======\n'
    printf 'y() { :; }\n'; printf '>>>>>>> other\n'; } > "$1"
}

# The verb-arming load resolves off the hook's own BASH_SOURCE, so corrupting
# it needs a COPY of the hook staged inside the tmp repo. $HOOK_ABS would
# always reach the real checkout's lib, where the case cannot be expressed.
stage_hook_repo() {
  build_repo
  mkdir -p "$REPO/.claude/hooks/lib"
  cp "$REPO_ROOT/.claude/hooks/lib/verb-arming.sh" "$REPO/.claude/hooks/lib/"
  cp "$REPO_ROOT/.claude/hooks/lib/verb-arming-walk.sh" "$REPO/.claude/hooks/lib/"
  cp "$REPO_ROOT/.claude/hooks/lib/repo-scope.sh" "$REPO/.claude/hooks/lib/"
  STAGED_HOOK="$REPO/.claude/hooks/capture-gh-artifact.sh"
  cp "$HOOK_ABS" "$STAGED_HOOK"
  chmod +x "$STAGED_HOOK"
}

# run_staged_hook <command> <stdout> [interpreter]
run_staged_hook() {
  local input interp="${3:-bash}"
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash "$1" "$2")
  run bash -c 'printf %s "$1" | "$3" "$2"' _ "$input" "$STAGED_HOOK" "$interp"
}

# The control that gives the staged cases teeth: their assertions (exit 0, no
# output, no breadcrumb) are equally satisfied by a hook that does nothing at
# all, so the same staging has to be shown recording normally first.
@test "staged hook, every lib usable: writes the breadcrumb (control)" {
  stage_hook_repo
  cd "$REPO"
  git checkout -b feat/staged --quiet

  run_staged_hook "gh pr create --title x --body y" "https://github.com/gaia-react/gaia/pull/900"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(jq -r '.number' "$(breadcrumb_path "feat/staged")")" = "900" ]
}

# Pinned to stock /bin/bash: the form this load replaced carried `|| exit 0`,
# which bash 5 reaches on an unparseable lib, so only 3.2 tells the parse check
# apart from it. On a bash-5 /bin/bash (Linux CI) this passes either way.
@test "gh-artifact-lib.sh holds conflict markers, under stock /bin/bash: exit 0, no output, no breadcrumb" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  stage_hook_repo
  cd "$REPO"
  git checkout -b feat/conflicted --quiet
  write_conflicted_lib "$REPO/.gaia/scripts/gh-artifact-lib.sh"

  run_staged_hook "gh pr create --title x --body y" "https://github.com/gaia-react/gaia/pull/901" /bin/bash
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$(breadcrumb_path "feat/conflicted")" ] && return 1
  return 0
}

# The pre-gate verb-arming load takes `|| true` rather than a parse check, so
# only the bash 5 half of the unparseable case is closed. Unpinned on purpose:
# the bare source it replaced dies on both shells, so this reds on Linux CI.
# The 3.2 half stays open by decision, not by oversight, and no case here
# asserts otherwise; the hook's own load comment names it.
@test "verb-arming.sh holds conflict markers: exit 0, no output, no breadcrumb" {
  stage_hook_repo
  cd "$REPO"
  git checkout -b feat/va-conflicted --quiet
  write_conflicted_lib "$REPO/.claude/hooks/lib/verb-arming.sh"

  run_staged_hook "gh pr create --title x --body y" "https://github.com/gaia-react/gaia/pull/902"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$(breadcrumb_path "feat/va-conflicted")" ] && return 1
  return 0
}
