#!/usr/bin/env bats

# Tests for .claude/hooks/wiki-session-start.sh.
#
# SessionStart hook with two jobs: hand off to the bounded working-state
# janitor, then deliver the janitor's one-line base-catch-up report on stdout,
# which a SessionStart hook's plain stdout puts in front of Claude. The report
# surfaces exactly once (read, then delete), the hook writes nothing into the
# git dir, and it always exits 0.
#
# The print is the load-bearing half. If it stops happening, a refused
# fast-forward of the base branch goes unreported, with no error and nothing
# that distinguishes it from a session whose base is current. The delegation
# tests cover the other half: the janitor must run when present and must not
# be able to fail the session when it breaks.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  HOOKS_SOURCE_DIRECTORY=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  REPO_ROOT="${HOOKS_SOURCE_DIRECTORY%/.claude/hooks}"
  HOOK_ABSOLUTE_PATH="$HOOKS_SOURCE_DIRECTORY/wiki-session-start.sh"
  SETTINGS_ABSOLUTE_PATH="${HOOKS_SOURCE_DIRECTORY%/hooks}/settings.json"
  FRONTEND_SETTINGS_ABSOLUTE_PATH="$REPO_ROOT/frontend/.claude/settings.json"
  REPORT_LINE='[wiki base] fast-forward of main to origin/main refused (divergence); local base is behind. Resolve by hand; the next qualifying session retries.'
  # Selects a SessionStart group that re-runs the hook on clear or compact.
  RESET_MATCHER_REGISTRATION_FILTER='.hooks.SessionStart[] | select((.matcher // "") | test("clear|compact")) | select([.hooks[] | .command // empty] | any(contains("wiki-session-start.sh")))'
}

teardown() {
  # `return 0` because each guard is an AND-list: with no path to remove it
  # would otherwise leave teardown non-zero and fail an innocent test.
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  [ -n "${PLAIN:-}" ] && rm -rf "$PLAIN"
  return 0
}

# Drop an executable stub at PATH (repo-relative) that touches a witness file
# instead of doing the real script's work.
stub_script() {
  local relative_path="$1"
  mkdir -p "$REPO/$(dirname "$relative_path")"
  printf '#!/usr/bin/env bash\n: > "%s.ran"\n' "$REPO/$(basename "$relative_path")" > "$REPO/$relative_path"
  chmod +x "$REPO/$relative_path"
}

# install_hook: copy the hook under test into $REPO at its own repo-relative
# path, with the main-root library beside it where the hook looks for it, and
# echo the hook's path.
#
# The hook locates the janitor and the library from its OWN directory
# (`${BASH_SOURCE[0]}`) rather than from the working directory. Invoking
# $HOOK_ABSOLUTE_PATH with cwd set to $REPO therefore runs the real janitor out
# of the home checkout and never sees a stub placed in the fixture, which reads
# as a pass for the fail-open tests and as a failure for the witness tests.
# Running a copy makes the fixture the hook's own tree, so a stub is what it
# finds.
install_hook() {
  mkdir -p "$REPO/.claude/hooks" "$REPO/.gaia/scripts"
  cp "$HOOK_ABSOLUTE_PATH" "$REPO/.claude/hooks/wiki-session-start.sh"
  chmod +x "$REPO/.claude/hooks/wiki-session-start.sh"
  cp "$REPO_ROOT/.gaia/scripts/main-root-lib.sh" "$REPO/.gaia/scripts/main-root-lib.sh"
  echo "$REPO/.claude/hooks/wiki-session-start.sh"
}

# seed_report ROOT: a two-line report under ROOT; only the first line may surface.
seed_report() {
  mkdir -p "$1/.gaia/local/cache/shared"
  printf '%s\nsecond line that must never surface\n' "$REPORT_LINE" \
    > "$1/.gaia/local/cache/shared/wiki-base-catchup.report"
}

# assert_report_prints_once HOOK: with a report seeded at $REPO, HOOK prints the
# first line and only the first line, deletes the file, and a second run prints
# nothing. Plain commands rather than `run`, so the body also works under `run`
# for the mutation case, where every line has to end the function itself.
assert_report_prints_once() {
  local captured
  seed_report "$REPO"
  captured=$(cd "$REPO" && bash "$1" < /dev/null 2>&1) || return 1
  [ "$captured" = "$REPORT_LINE" ] || return 1
  [ -f "$REPO/.gaia/local/cache/shared/wiki-base-catchup.report" ] && return 1
  captured=$(cd "$REPO" && bash "$1" < /dev/null 2>&1) || return 1
  [ -z "$captured" ] || return 1
  return 0
}

# assert_janitor_report_prints_in_same_run HOOK: a janitor stub writes the
# report during the run, so only a hook that prints AFTER the janitor shows it.
assert_janitor_report_prints_in_same_run() {
  local captured
  mkdir -p "$REPO/.claude/hooks"
  printf '#!/usr/bin/env bash\nmkdir -p "%s/.gaia/local/cache/shared"\nprintf "%%s\\n" "%s" > "%s/.gaia/local/cache/shared/wiki-base-catchup.report"\n' \
    "$REPO" "$REPORT_LINE" "$REPO" > "$REPO/.claude/hooks/local-janitor.sh"
  chmod +x "$REPO/.claude/hooks/local-janitor.sh"
  captured=$(cd "$REPO" && bash "$1" < /dev/null 2>&1) || return 1
  [ "$captured" = "$REPORT_LINE" ] || return 1
  return 0
}

# --- the report ---

@test "prints the report's first line to stdout exactly once and deletes the file" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  hook=$(install_hook)
  assert_report_prints_once "$hook"
}

@test "guard: a hook that never deletes the report fails the print-once assertion" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  hook=$(install_hook)
  grep -qF -- 'rm -f "$catchup_report"' "$hook" || return 1
  sed -e '/rm -f "\$catchup_report"/d' "$hook" > "$hook.mutated"
  mv "$hook.mutated" "$hook"
  grep -qF -- 'rm -f "$catchup_report"' "$hook" && return 1
  run assert_report_prints_once "$hook"
  [ "$status" -ne 0 ]
}

@test "no report: nothing on stdout or stderr and exit 0" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  hook=$(install_hook)
  invoke_hook_in "$REPO" '' "$hook"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a repo with no commits yet does not fail the session" {
  REPO=$(mktemp -d -t gaia-session-start-unborn-XXXXXX)
  git -C "$REPO" init --quiet --initial-branch=main
  hook=$(install_hook)
  invoke_hook_in "$REPO" '' "$hook"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "outside a git repository the hook is a silent no-op" {
  PLAIN=$(mktemp -d -t gaia-session-start-plain-XXXXXX)
  invoke_hook_in "$PLAIN" '' "$HOOK_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prints a report written at the main root from a subdirectory" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  hook=$(install_hook)
  seed_report "$REPO"
  mkdir -p "$REPO/sub/deeper"
  invoke_hook_in "$REPO/sub/deeper" '' "$hook"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPORT_LINE" ] || return 1
  [ -f "$REPO/.gaia/local/cache/shared/wiki-base-catchup.report" ] && return 1
  return 0
}

@test "prints a report written at the main root from a linked worktree, exactly once" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  hook=$(install_hook)
  WORKTREE_PATH="$REPO/.claude/worktrees/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$WORKTREE_PATH" main
  seed_report "$REPO"
  invoke_hook_in "$WORKTREE_PATH" '' "$hook"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPORT_LINE" ] || return 1
  [ -f "$REPO/.gaia/local/cache/shared/wiki-base-catchup.report" ] && return 1

  invoke_hook_in "$WORKTREE_PATH" '' "$hook"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prints a report written at the main root from a subdirectory of a linked worktree" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  hook=$(install_hook)
  WORKTREE_PATH="$REPO/.claude/worktrees/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$WORKTREE_PATH" main
  mkdir -p "$WORKTREE_PATH/sub/deeper"
  seed_report "$REPO"
  invoke_hook_in "$WORKTREE_PATH/sub/deeper" '' "$hook"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPORT_LINE" ] || return 1
  [ -f "$REPO/.gaia/local/cache/shared/wiki-base-catchup.report" ] && return 1
  return 0
}

@test "a report the janitor writes during the run is printed in that same run" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  hook=$(install_hook)
  assert_janitor_report_prints_in_same_run "$hook"
}

@test "guard: a hook that prints before running the janitor fails the same-run assertion" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  hook=$(install_hook)
  # Move the janitor line after the print: drop it and the closing `exit 0`,
  # then re-append the janitor line and the exit.
  grep -qE '^\[ -f .*local-janitor\.sh' "$hook" || return 1
  janitor_line=$(grep -E '^\[ -f .*local-janitor\.sh' "$hook")
  sed -e '/^\[ -f .*local-janitor\.sh/d' -e '$d' "$hook" > "$hook.mutated"
  printf '%s\nexit 0\n' "$janitor_line" >> "$hook.mutated"
  mv "$hook.mutated" "$hook"
  run assert_janitor_report_prints_in_same_run "$hook"
  [ "$status" -ne 0 ]
}

# An unresolved-merge-conflict body: the file opens and reads fine, so an
# existence test passes it, and bash cannot parse it.
write_conflicted_library() {
  { printf '<<<<<<< HEAD\n'; printf 'x() { :; }\n'; printf '=======\n'
    printf 'y() { :; }\n'; printf '>>>>>>> other\n'; } > "$1"
}

@test "main-root-lib.sh holding conflict markers: the report is still printed" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  hook=$(install_hook)
  write_conflicted_library "$REPO/.gaia/scripts/main-root-lib.sh"
  seed_report "$REPO"
  invoke_hook_in "$REPO" '' "$hook"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPORT_LINE" ] || return 1
  [ -f "$REPO/.gaia/local/cache/shared/wiki-base-catchup.report" ] && return 1
  return 0
}

@test "writes nothing into the git dir" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  hook=$(install_hook)
  invoke_hook_in "$REPO" '' "$hook"
  [ "$status" -eq 0 ]
  [ -e "$REPO/.git/claude-session-start" ] && return 1
  [ -e "$REPO/.git/claude-session-wiki-dirty" ] && return 1
  return 0
}

# --- delegation to the bounded janitor ---

@test "runs the local janitor when it is present" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  stub_script ".claude/hooks/local-janitor.sh"
  hook=$(install_hook)
  invoke_hook_in "$REPO" '' "$hook"
  [ "$status" -eq 0 ]
  [ -f "$REPO/local-janitor.sh.ran" ]
}

@test "finds its janitor from its own tree, not from the working directory" {
  # The regression this pins: a janitor located from the working directory is
  # unfindable from any subdirectory, so the sweep silently stops happening.
  # Invoking from a subdirectory of $REPO must still reach the stub beside the
  # hook, which is the whole content of the rooting.
  REPO=$("$HELPERS/tmp-git-repo.sh")
  stub_script ".claude/hooks/local-janitor.sh"
  hook=$(install_hook)
  mkdir -p "$REPO/app/components"
  invoke_hook_in "$REPO/app/components" '' "$hook"
  [ "$status" -eq 0 ]
  [ -f "$REPO/local-janitor.sh.ran" ]
}

@test "a missing janitor is not an error" {
  # An adopter clone, or a checkout mid-update, can be missing the script.
  # The session must start anyway.
  REPO=$("$HELPERS/tmp-git-repo.sh")
  hook=$(install_hook)
  [ ! -f "$REPO/.claude/hooks/local-janitor.sh" ]
  invoke_hook_in "$REPO" '' "$hook"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a janitor that exits non-zero never fails the session" {
  # A janitor bug must cost a sweep, not the session, and must not cost the
  # report that was already pending.
  REPO=$("$HELPERS/tmp-git-repo.sh")
  hook=$(install_hook)
  seed_report "$REPO"
  printf '#!/usr/bin/env bash\necho boom >&2\nexit 3\n' > "$REPO/.claude/hooks/local-janitor.sh"
  chmod +x "$REPO/.claude/hooks/local-janitor.sh"
  invoke_hook_in "$REPO" '' "$hook"
  [ "$status" -eq 0 ]
  grep -qF -- "$REPORT_LINE" <<<"$output" || return 1
  return 0
}

# --- structural ---

@test "wiki-session-start.sh is executable" {
  [ -x "$HOOK_ABSOLUTE_PATH" ]
}

@test "settings.json registers the hook under SessionStart startup|resume" {
  hook_registered "$SETTINGS_ABSOLUTE_PATH" '.hooks.SessionStart[] | select(.matcher == "startup|resume")' wiki-session-start.sh
}

@test "both settings files register the hook on startup and resume, never on clear or compact" {
  hook_registered "$SETTINGS_ABSOLUTE_PATH" '.hooks.SessionStart[] | select(.matcher == "startup|resume")' wiki-session-start.sh
  hook_registered "$FRONTEND_SETTINGS_ABSOLUTE_PATH" '.hooks.SessionStart[] | select(.matcher == "startup|resume")' wiki-session-start.sh
  run jq -e "$RESET_MATCHER_REGISTRATION_FILTER" "$SETTINGS_ABSOLUTE_PATH"
  [ "$status" -ne 0 ]
  run jq -e "$RESET_MATCHER_REGISTRATION_FILTER" "$FRONTEND_SETTINGS_ABSOLUTE_PATH"
  [ "$status" -ne 0 ]
}

@test "guard: a clear|compact group running the hook fails the no-reset assertion" {
  # Running the janitor and printing the report again on clear or compact would
  # re-announce a report the session already saw.
  scratch_settings="$BATS_TEST_TMPDIR/settings.json"
  jq '.hooks.SessionStart += [{matcher: "clear|compact", hooks: [{type: "command", command: "\"$(git rev-parse --show-toplevel)/.claude/hooks/wiki-session-start.sh\""}]}]' \
    "$SETTINGS_ABSOLUTE_PATH" > "$scratch_settings"
  run jq -e "$RESET_MATCHER_REGISTRATION_FILTER" "$scratch_settings"
  [ "$status" -eq 0 ]
}

# --- removed hooks stay removed ---

@test "no hook prints a wiki state, nudge, or end-of-session tag" {
  tag_pattern='\[wiki (state|nudge|end-of'"-session)\\]"
  run grep -rnE "$tag_pattern" "$REPO_ROOT/.claude/hooks"
  # grep exits 1 on no match; any other status is a real failure or a hit.
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "neither settings file registers a removed wiki hook" {
  drift_hook="wiki-drift""-check.sh"
  nudge_hook="wiki-commit""-nudge.sh"
  hot_inject_hook="wiki-hot""-inject.sh"
  session_stop_hook="wiki-session""-stop.sh"
  report_drain_hook="janitor-report""-drain.sh"
  for removed_hook in "$drift_hook" "$nudge_hook" "$hot_inject_hook" "$session_stop_hook" "$report_drain_hook"; do
    grep -qF -- "$removed_hook" "$SETTINGS_ABSOLUTE_PATH" && return 1
    grep -qF -- "$removed_hook" "$FRONTEND_SETTINGS_ABSOLUTE_PATH" && return 1
  done
  return 0
}

@test "the removed hook files are gone" {
  for removed_hook in "wiki-hot""-inject.sh" "wiki-session""-stop.sh" "janitor-report""-drain.sh" "lib/wiki-dirty""-fingerprint.sh"; do
    [ -e "$HOOKS_SOURCE_DIRECTORY/$removed_hook" ] && return 1
  done
  return 0
}
