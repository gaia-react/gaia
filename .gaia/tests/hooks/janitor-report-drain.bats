#!/usr/bin/env bats

# The janitor's one-line base-catch-up report is written by
# .claude/hooks/local-janitor.sh to .gaia/local/cache/shared/wiki-base-catchup.report
# when its own fast-forward of the base branch is refused. The drain hook is
# the delivery channel: a UserPromptSubmit hook's stdout is injected into the
# conversation, which a SessionStart hook's exit-0 stderr is not.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  . "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/tests/helpers/path.sh"
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HOOK_ABS="$REPO_ROOT/.claude/hooks/janitor-report-drain.sh"
  SETTINGS_ABS="$REPO_ROOT/.claude/settings.json"
  REPORT_LINE='[wiki base] fast-forward of main to origin/main refused (divergence); local base is behind. Resolve by hand; the next qualifying session retries.'
}

teardown() {
  # `return 0` because the guard is an AND-list: with no $REPO to remove it
  # would otherwise leave teardown non-zero and fail an innocent test.
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  return 0
}

seed_report() {
  mkdir -p "$1/.gaia/local/cache/shared"
  printf '%s\nsecond line that must never surface\n' "$REPORT_LINE" \
    > "$1/.gaia/local/cache/shared/wiki-base-catchup.report"
}

@test "drains the report's first line to stdout exactly once" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  seed_report "$REPO"
  input=$("$HELPERS/mock-hook-input.sh" user-prompt-submit S1)
  invoke_hook "$input" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPORT_LINE" ] || return 1
  [ -f .gaia/local/cache/shared/wiki-base-catchup.report ] && return 1

  invoke_hook "$input" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "drains the report when jq is unavailable" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  seed_report "$REPO"

  # `command -v jq` only checks that an executable NAMED jq is on PATH; a shim
  # that fails when run still satisfies it. The PATH below carries no jq at
  # all, only symlinks to the external binaries the hook needs plus bash.
  nojq_bin="$(path_allowlist bash head rm)"

  run bash -c 'PATH="$1" bash "$2" < /dev/null' _ "$nojq_bin" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  grep -qF -- '[wiki base] fast-forward of main to origin/main refused' <<<"$output" || return 1
  [ -f .gaia/local/cache/shared/wiki-base-catchup.report ] && return 1
  return 0
}

@test "no report file is a silent no-op" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  rm -f .gaia/local/cache/shared/wiki-base-catchup.report
  input=$("$HELPERS/mock-hook-input.sh" user-prompt-submit S1)
  invoke_hook "$input" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# The report is main-anchored, so the reader resolves the main root. A reader
# resolving against the process working directory answers a different tree than
# the writer from a subdirectory or an unprovisioned linked worktree.

@test "drains a report written at the main root from a subdirectory" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  seed_report "$REPO"
  mkdir -p "$REPO/sub/deeper"
  input=$("$HELPERS/mock-hook-input.sh" user-prompt-submit S1)
  invoke_hook_in "$REPO/sub/deeper" "$input" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPORT_LINE" ] || return 1
  [ -f "$REPO/.gaia/local/cache/shared/wiki-base-catchup.report" ] && return 1
  return 0
}

@test "drains a report written at the main root from a linked worktree, exactly once" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  WT="$REPO/.claude/worktrees/wt"
  git worktree add --quiet -b wt-branch "$WT" main
  seed_report "$REPO"
  input=$("$HELPERS/mock-hook-input.sh" user-prompt-submit S1)
  invoke_hook_in "$WT" "$input" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPORT_LINE" ] || return 1
  [ -f "$REPO/.gaia/local/cache/shared/wiki-base-catchup.report" ] && return 1

  invoke_hook_in "$WT" "$input" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "drains a report written at the main root from a subdirectory of a linked worktree" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  WT="$REPO/.claude/worktrees/wt"
  git worktree add --quiet -b wt-branch "$WT" main
  mkdir -p "$WT/sub/deeper"
  seed_report "$REPO"
  input=$("$HELPERS/mock-hook-input.sh" user-prompt-submit S1)
  invoke_hook_in "$WT/sub/deeper" "$input" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPORT_LINE" ] || return 1
  [ -f "$REPO/.gaia/local/cache/shared/wiki-base-catchup.report" ] && return 1
  return 0
}

# An unresolved-merge-conflict body: the file opens and reads fine, so an
# existence test passes it, and bash cannot parse it.
write_conflicted_lib() {
  { printf '<<<<<<< HEAD\n'; printf 'x() { :; }\n'; printf '=======\n'
    printf 'y() { :; }\n'; printf '>>>>>>> other\n'; } > "$1"
}

@test "main-root-lib.sh holding conflict markers: the report is still drained" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  seed_report "$REPO"

  local staged="$BATS_TEST_TMPDIR/staged"
  rm -rf "$staged"
  mkdir -p "$staged/.claude" "$staged/.gaia"
  cp -R "$REPO_ROOT/.claude/hooks" "$staged/.claude/hooks"
  cp -R "$REPO_ROOT/.gaia/scripts" "$staged/.gaia/scripts"
  write_conflicted_lib "$staged/.gaia/scripts/main-root-lib.sh"

  input=$("$HELPERS/mock-hook-input.sh" user-prompt-submit S1)
  invoke_hook_in "$REPO" "$input" "$staged/.claude/hooks/janitor-report-drain.sh"
  [ "$status" -eq 0 ]
  grep -qF -- '[wiki base] fast-forward of main to origin/main refused' <<<"$output" || return 1
  [ -f "$REPO/.gaia/local/cache/shared/wiki-base-catchup.report" ] && return 1
  return 0
}

# The hook carries no wiki-state logic: a state file many commits behind HEAD
# with no report pending prints nothing, and writes no session marker.
@test "a drifted wiki state with no report prints nothing and writes no marker" {
  REPO=$("$HELPERS/tmp-git-repo.sh" --commits 5)
  cd "$REPO"
  base=$(git rev-list --max-parents=0 HEAD)
  cat > wiki/.state.json <<EOF
{"version":1,"last_evaluated_sha":"$base","last_evaluated_at":"2026-01-01T00:00:00Z"}
EOF
  input=$("$HELPERS/mock-hook-input.sh" user-prompt-submit S1)
  invoke_hook "$input" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  drift_marker=".claude/wiki-drift""-checked"
  [ -f "$drift_marker" ] && return 1
  return 0
}

@test "the hook file is executable" {
  [ -x "$HOOK_ABS" ]
}

@test "the drain hook is registered under UserPromptSubmit" {
  hook_registered "$SETTINGS_ABS" '.hooks.UserPromptSubmit[]' 'janitor-report-drain.sh'
}

# No wiki-drift signal is injected into the conversation by any hook.

@test "no hook prints a wiki state, nudge, or end-of-session tag" {
  tag_pattern='\[wiki (state|nudge|end-of'"-session)\\]"
  run grep -rnE "$tag_pattern" "$REPO_ROOT/.claude/hooks"
  # grep exits 1 on no match; any other status is a real failure or a hit.
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "settings.json registers neither removed wiki hook" {
  drift_hook="wiki-drift""-check.sh"
  nudge_hook="wiki-commit""-nudge.sh"
  grep -qF -- "$drift_hook" "$SETTINGS_ABS" && return 1
  grep -qF -- "$nudge_hook" "$SETTINGS_ABS" && return 1
  return 0
}

@test "the Stop hook does not source the deferral library" {
  deferral_name="gaia""-ci-defer"
  grep -qF -- "$deferral_name" "$REPO_ROOT/.claude/hooks/wiki-session-stop.sh" && return 1
  return 0
}
