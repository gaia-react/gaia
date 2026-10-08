#!/usr/bin/env bats
#
# The pre-checkout fork guard, .claude/hooks/block-fork-pr-checkout.sh: a
# PreToolUse Bash hook that denies `gh pr checkout <n>` and a `git fetch` of
# `pull/<n>/head` when gh reports pull request <n> as cross-repository, or
# cannot say. Driven directly with PreToolUse payloads and a logging gh stub
# that answers per pull request number.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/block-fork-pr-checkout.bats < /dev/null
# Assertion style: .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HOOK="$REPO_ROOT/.claude/hooks/block-fork-pr-checkout.sh"
  SETTINGS="$REPO_ROOT/.claude/settings.json"
  STUB_DIRECTORY="$BATS_TEST_TMPDIR/gh-stub"
  GH_LOG="$STUB_DIRECTORY/gh.log"
  mkdir -p "$STUB_DIRECTORY/bin"
  : >"$GH_LOG"
  # Pull request 34 is a fork and 12 is not; `$STUB_DIRECTORY/fail` makes every
  # `pr view` fail the way an unreachable API does.
  cat >"$STUB_DIRECTORY/bin/gh" <<EOF
#!/usr/bin/env bash
stub_directory="$STUB_DIRECTORY"
EOF
  cat >>"$STUB_DIRECTORY/bin/gh" <<'EOF'
printf '%s\n' "$*" >>"$stub_directory/gh.log"
if [ -f "$stub_directory/fail" ]; then
  echo "HTTP 502: Bad Gateway (https://api.github.com/graphql)" >&2
  exit 1
fi
case "$*" in
  "repo view --json nameWithOwner --jq .nameWithOwner") echo o/r ;;
  "pr view 34 --json isCrossRepository --jq .isCrossRepository") echo true ;;
  "pr view 12 --json isCrossRepository --jq .isCrossRepository") echo false ;;
  *) echo "Could not resolve to a PullRequest" >&2; exit 1 ;;
esac
EOF
  chmod +x "$STUB_DIRECTORY/bin/gh"
  MESSAGE="$(bash -c '. "$1"; printf "%s" "$GAIA_CROSS_REPO_REFUSAL_MESSAGE"' _ "$REPO_ROOT/.claude/hooks/lib/cross-repo-refusal.sh")"
}

# run_guard <command> [hook]
run_guard() {
  local payload
  payload="$(jq -n -c --arg command "$1" '{tool_name: "Bash", tool_input: {command: $command}}')"
  run env PATH="$STUB_DIRECTORY/bin:$PATH" bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$BATS_TEST_TMPDIR" "$payload" "${2:-$HOOK}"
}

reason() {
  jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output"
}

@test "UAT-010: gh pr checkout of a fork pull request is denied with the refusal" {
  run_guard 'gh pr checkout 34'
  assert_denied_by_json
  reason | grep -qF -- "$MESSAGE"
  reason | grep -qF -- 'review the harness diff by hand'
  grep -qxF -- 'pr view 34 --json isCrossRepository --jq .isCrossRepository' "$GH_LOG"
}

@test "UAT-010: git fetch of a fork pull request's head ref is denied" {
  run_guard 'git fetch origin pull/34/head:pr-34'
  assert_denied_by_json
  reason | grep -qF -- "$MESSAGE"
}

@test "git fetch through git -C, the spelling the rules prescribe, is checked too" {
  run_guard 'git -C /tmp/x fetch origin pull/34/head:pr-34'
  assert_denied_by_json
}

@test "a pull-request URL target is read for its number" {
  run_guard 'gh pr checkout https://github.com/o/r/pull/34'
  assert_denied_by_json
  grep -qxF -- 'pr view 34 --json isCrossRepository --jq .isCrossRepository' "$GH_LOG"
}

@test "a --repo placed after the target is denied, not asked about in the working directory" {
  run_guard 'gh pr checkout 12 --repo other/repo'
  assert_denied_by_json
  reason | grep -qF -- 'names another repository (--repo)'
  [ ! -s "$GH_LOG" ]
}

@test "a -R placed after the target is denied" {
  run_guard 'gh pr checkout 12 -R other/repo'
  assert_denied_by_json
  reason | grep -qF -- 'names another repository (-R)'
}

@test "a pull-request URL naming another repository is denied" {
  run_guard 'gh pr checkout https://github.com/other/repo/pull/12'
  assert_denied_by_json
  reason | grep -qF -- 'other/repo'
  ! grep -qF -- 'pr view 12' "$GH_LOG"
}

@test "a pull-request URL naming this repository is allowed" {
  run_guard 'gh pr checkout https://github.com/o/r/pull/12'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -qxF -- 'pr view 12 --json isCrossRepository --jq .isCrossRepository' "$GH_LOG"
}

@test "a pull-request URL is denied when gh cannot name this repository" {
  : >"$STUB_DIRECTORY/fail"
  run_guard 'gh pr checkout https://github.com/o/r/pull/12'
  assert_denied_by_json
  reason | grep -qF -- 'could not say which repository'
}

@test "mutation: stopping the flag scan at the target lets a trailing --repo through, so the trailing-flag test can fail" {
  local hook_copy_directory="$BATS_TEST_TMPDIR/mutant-scan"
  mkdir -p "$hook_copy_directory"
  ln -s "$REPO_ROOT/.claude/hooks/lib" "$hook_copy_directory/lib"
  sed 's/\[ -n "\$target" \] || target="\$token"/target="$token"; break/' "$HOOK" >"$hook_copy_directory/block-fork-pr-checkout.sh"
  cmp -s "$HOOK" "$hook_copy_directory/block-fork-pr-checkout.sh" && return 1
  run_guard 'gh pr checkout 12 --repo other/repo' "$hook_copy_directory/block-fork-pr-checkout.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "mutation: without the URL repository comparison a foreign URL is allowed, so the foreign-URL test can fail" {
  local hook_copy_directory="$BATS_TEST_TMPDIR/mutant-url"
  mkdir -p "$hook_copy_directory"
  ln -s "$REPO_ROOT/.claude/hooks/lib" "$hook_copy_directory/lib"
  sed 's/if \[ "\$url_repository" != "\$current_repository" \]/if false/' "$HOOK" >"$hook_copy_directory/block-fork-pr-checkout.sh"
  cmp -s "$HOOK" "$hook_copy_directory/block-fork-pr-checkout.sh" && return 1
  run_guard 'gh pr checkout https://github.com/other/repo/pull/12' "$hook_copy_directory/block-fork-pr-checkout.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "UAT-010: gh pr checkout of a same-repo pull request is allowed" {
  run_guard 'gh pr checkout 12'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -qxF -- 'pr view 12 --json isCrossRepository --jq .isCrossRepository' "$GH_LOG"
}

@test "flags before the target do not hide it" {
  run_guard 'gh pr checkout --branch local-name 34'
  assert_denied_by_json
}

@test "UAT-010: when gh cannot answer, the checkout is denied and the reason names the failure" {
  : >"$STUB_DIRECTORY/fail"
  run_guard 'gh pr checkout 34'
  assert_denied_by_json
  reason | grep -qF -- 'cannot tell whether pull request 34 comes from a fork'
  reason | grep -qF -- 'HTTP 502: Bad Gateway'
  reason | grep -qF -- 'push the branch to origin'
}

@test "a target the guard cannot read is denied with the by-number spelling named" {
  run_guard 'gh pr checkout some-branch'
  assert_denied_by_json
  reason | grep -qF -- 'gh pr checkout <number>'
  [ ! -s "$GH_LOG" ]
}

@test "UAT-010: an unrelated Bash command is allowed without calling gh" {
  run_guard 'git status'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$GH_LOG" ]
}

# run_prefilter_probe <command> [hook]: drives the hook with jq and gh stubs
# first on PATH that each touch a sentinel, so a run that spawns either leaves
# it behind.
run_prefilter_probe() {
  local payload probe_bin="$BATS_TEST_TMPDIR/probe-bin"
  payload="$(jq -n -c --arg command "$1" '{tool_name: "Bash", tool_input: {command: $command}}')"
  PROBE_SENTINEL="$BATS_TEST_TMPDIR/probe-spawned"
  mkdir -p "$probe_bin"
  for tool in jq gh; do
    cat >"$probe_bin/$tool" <<EOF
#!/usr/bin/env bash
echo $tool >>"$PROBE_SENTINEL"
EOF
    chmod +x "$probe_bin/$tool"
  done
  run env PATH="$probe_bin:$PATH" bash -c 'printf %s "$1" | bash "$2"' _ "$payload" "${2:-$HOOK}"
}

@test "a command naming neither checkout nor pull exits before spawning jq or gh" {
  run_prefilter_probe 'ls -la'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$PROBE_SENTINEL" ]
}

@test "mutation: without the prefilter exit the same command spawns jq, so the prefilter test can fail" {
  local hook_copy_directory="$BATS_TEST_TMPDIR/no-prefilter"
  mkdir -p "$hook_copy_directory"
  ln -s "$REPO_ROOT/.claude/hooks/lib" "$hook_copy_directory/lib"
  sed '/^  \*) exit 0 ;;$/d' "$HOOK" >"$hook_copy_directory/block-fork-pr-checkout.sh"
  cmp -s "$HOOK" "$hook_copy_directory/block-fork-pr-checkout.sh" && return 1
  run_prefilter_probe 'ls -la' "$hook_copy_directory/block-fork-pr-checkout.sh"
  grep -qxF -- jq "$PROBE_SENTINEL"
}

@test "an ordinary fetch with no pull-request refspec is allowed without calling gh" {
  run_guard 'git fetch origin main'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$GH_LOG" ]
}

@test "a checkout only cited in a heredoc body does not arm" {
  run_guard $'cat > notes.txt <<EOF\ngh pr checkout 34\nEOF\n'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$GH_LOG" ]
}

@test "a non-Bash tool call is allowed" {
  run env PATH="$STUB_DIRECTORY/bin:$PATH" bash -c 'printf %s "$1" | bash "$2"' _ \
    '{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}' "$HOOK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a missing cross-repo library denies an armed call instead of allowing it" {
  local hook_copy_directory="$BATS_TEST_TMPDIR/no-cross-lib"
  mkdir -p "$hook_copy_directory/lib"
  cp "$HOOK" "$hook_copy_directory/block-fork-pr-checkout.sh"
  cp "$REPO_ROOT/.claude/hooks/lib/jq-availability.sh" "$REPO_ROOT/.claude/hooks/lib/verb-arming.sh" \
    "$REPO_ROOT/.claude/hooks/lib/verb-arming-walk.sh" "$REPO_ROOT/.claude/hooks/lib/hook-payload.sh" \
    "$hook_copy_directory/lib/"
  run_guard 'gh pr checkout 12' "$hook_copy_directory/block-fork-pr-checkout.sh"
  assert_denied_by_json
  reason | grep -qF -- 'cross-repo-refusal.sh'
}

@test "mutation: without the gaia_cross_repo_deny_reason call the fork checkout is allowed, so the denial test can fail" {
  local hook_copy_directory="$BATS_TEST_TMPDIR/mutant"
  mkdir -p "$hook_copy_directory"
  ln -s "$REPO_ROOT/.claude/hooks/lib" "$hook_copy_directory/lib"
  sed 's/if fork_reason=\$(gaia_cross_repo_deny_reason/if false \&\& fork_reason=$(gaia_cross_repo_deny_reason/' "$HOOK" >"$hook_copy_directory/block-fork-pr-checkout.sh"
  cmp -s "$HOOK" "$hook_copy_directory/block-fork-pr-checkout.sh" && return 1
  run_guard 'gh pr checkout 34' "$hook_copy_directory/block-fork-pr-checkout.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the guard is registered under PreToolUse for Bash in the rooted command form" {
  # Any matcher naming Bash: the merge gate it sits beside is registered under
  # a matcher shared with another tool.
  hook_registered "$SETTINGS" '.hooks.PreToolUse[] | select(.matcher | split("|") | index("Bash"))' block-fork-pr-checkout.sh
  # shellcheck disable=SC2016 # the expansion is literal text in settings.json
  jq -e --arg command '"$(git rev-parse --show-toplevel 2>/dev/null || printf %s "${CLAUDE_PROJECT_DIR:-.}")/.claude/hooks/block-fork-pr-checkout.sh"' \
    '[.hooks.PreToolUse[] | select(.matcher | split("|") | index("Bash")) | .hooks[].command] | index($command) != null' "$SETTINGS"
}

# --- the one-jq payload reader ---

@test "lib/hook-payload.sh absent: a payload the hook would deny exits 2 naming the library" {
  local hooks_directory scratch_hooks payload
  hooks_directory=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  scratch_hooks="$BATS_TEST_TMPDIR/scratch-hooks"
  mkdir -p "$scratch_hooks"
  cp -R "$hooks_directory/." "$scratch_hooks/"
  rm -f "$scratch_hooks/lib/hook-payload.sh"
  payload=$(jq -nc --arg command 'gh pr checkout 12' '{tool_name: "Bash", tool_input: {command: $command}}')
  run bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$BATS_TEST_TMPDIR" "$payload" "$scratch_hooks/block-fork-pr-checkout.sh"
  [ "$status" -eq 2 ]
  grep -qF 'BLOCKED: block-fork-pr-checkout.sh cannot load lib/hook-payload.sh' <<<"$output"
}

@test "a non-arming Bash payload spawns no jq process" {
  local hooks_directory shim_directory spawn_log real_jq payload spawn_count
  hooks_directory=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  shim_directory="$BATS_TEST_TMPDIR/jq-shim"
  spawn_log="$BATS_TEST_TMPDIR/jq-spawns"
  real_jq=$(command -v jq)
  mkdir -p "$shim_directory"
  printf '#!/bin/sh\nprintf x >>"%s"\nexec "%s" "$@"\n' "$spawn_log" "$real_jq" >"$shim_directory/jq"
  chmod +x "$shim_directory/jq"
  : >"$spawn_log"
  payload=$(jq -nc '{tool_name: "Bash", tool_input: {command: "ls -la"}}')
  run env PATH="$shim_directory:$PATH" bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$BATS_TEST_TMPDIR" "$payload" "$hooks_directory/block-fork-pr-checkout.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  spawn_count=$(wc -c <"$spawn_log" | tr -d ' ')
  [ "$spawn_count" -eq 0 ]
}
