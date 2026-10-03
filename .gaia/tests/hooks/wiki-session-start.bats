#!/usr/bin/env bats

# Tests for .claude/hooks/wiki-session-start.sh.
#
# SessionStart hook with two jobs, both pure side effect and neither of them
# ever reported: record HEAD into $GIT_DIR/claude-session-start so the Stop
# hook can diff against the session's starting point, then hand off to the
# bounded working-state janitor. It writes nothing to stdout, decides nothing,
# and always exits 0.
#
# The stamp is the load-bearing half. If it stops being written, the Stop hook
# loses its baseline and wiki commits made during the session go undetected --
# with no error, no output, and nothing that distinguishes it from a session
# that genuinely changed no wiki page. The delegation tests below cover the
# other half: the janitor must run when present and must not be able to fail
# the session when it breaks.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  HOOKS_SOURCE_DIRECTORY=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABSOLUTE_PATH="$HOOKS_SOURCE_DIRECTORY/wiki-session-start.sh"
  SETTINGS_ABSOLUTE_PATH="${HOOKS_SOURCE_DIRECTORY%/hooks}/settings.json"
  FRONTEND_SETTINGS_ABSOLUTE_PATH="${HOOKS_SOURCE_DIRECTORY%/.claude/hooks}/frontend/.claude/settings.json"
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
# path and echo that path, for a test that drives the delegation rather than
# the stamp.
#
# The delegation tests need this and the stamp tests do not, because the hook
# locates the janitor from its OWN directory (`${BASH_SOURCE[0]}`) rather
# than from the working directory. Invoking $HOOK_ABSOLUTE_PATH with cwd set to $REPO
# therefore runs the real janitor out of the home checkout and never sees a
# stub placed in the fixture, which reads as a pass for the fail-open tests and
# as a failure for the witness tests. Running a copy makes the fixture the
# hook's own tree, so a stub is what it finds; that the copy resolves its
# delegate beside itself, in whichever tree it was invoked from, is the
# property the rooting buys and these tests are what pin it.
install_hook() {
  mkdir -p "$REPO/.claude/hooks"
  cp "$HOOK_ABSOLUTE_PATH" "$REPO/.claude/hooks/wiki-session-start.sh"
  chmod +x "$REPO/.claude/hooks/wiki-session-start.sh"
  mkdir -p "$REPO/.claude/hooks/lib"
  cp "$HOOKS_SOURCE_DIRECTORY/lib/wiki-dirty-fingerprint.sh" "$REPO/.claude/hooks/lib/wiki-dirty-fingerprint.sh"
  echo "$REPO/.claude/hooks/wiki-session-start.sh"
}

# install_hook_without_library: the same copy with no lib/ beside it, for the
# fail-open case.
install_hook_without_library() {
  mkdir -p "$REPO/.claude/hooks"
  cp "$HOOK_ABSOLUTE_PATH" "$REPO/.claude/hooks/wiki-session-start.sh"
  echo "$REPO/.claude/hooks/wiki-session-start.sh"
}

# assert_missing_library_is_silent HOOK: HOOK has no library beside it. It must
# exit 0, write nothing to stdout or stderr, and still stamp the session HEAD.
# Plain commands rather than `run`, so the body also works under `run` for the
# mutation case, where every line has to end the function itself.
assert_missing_library_is_silent() {
  local result_status=0 captured
  captured=$(cd "$REPO" && bash "$1" < /dev/null 2>&1) || result_status=$?
  [ "$result_status" -eq 0 ] || return 1
  [ -z "$captured" ] || return 1
  [ -s "$REPO/.git/claude-session-start" ] || return 1
}

# --- the HEAD stamp ---

@test "records HEAD into the git dir" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  invoke_hook_in "$REPO" '' "$HOOK_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.git/claude-session-start" ]
  head=$(git -C "$REPO" rev-parse HEAD)
  stamped=$(cat "$REPO/.git/claude-session-start")
  [ "$stamped" = "$head" ]
}

@test "the stamp is silent" {
  # SessionStart stderr is not shown and stdout is not injected, so any output
  # here is noise at best. Silence is the contract.
  REPO=$("$HELPERS/tmp-git-repo.sh")
  invoke_hook_in "$REPO" '' "$HOOK_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a later session re-stamps to the new HEAD" {
  # The stamp is a per-session baseline, not a first-run record: a stale value
  # would make the Stop hook diff against the wrong starting point.
  REPO=$("$HELPERS/tmp-git-repo.sh")
  invoke_hook_in "$REPO" '' "$HOOK_ABSOLUTE_PATH"
  first=$(cat "$REPO/.git/claude-session-start")

  echo "later" >> "$REPO/wiki/index.md"
  git -C "$REPO" add wiki/index.md
  git -C "$REPO" commit --quiet -m "second"

  invoke_hook_in "$REPO" '' "$HOOK_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
  second=$(cat "$REPO/.git/claude-session-start")
  head=$(git -C "$REPO" rev-parse HEAD)
  [ "$second" = "$head" ]
  [ "$first" = "$second" ] && return 1
  return 0
}

@test "a repo with no commits yet does not fail the session" {
  REPO=$(mktemp -d -t gaia-session-start-unborn-XXXXXX)
  git -C "$REPO" init --quiet --initial-branch=main
  invoke_hook_in "$REPO" '' "$HOOK_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "outside a git repository the hook is a silent no-op" {
  PLAIN=$(mktemp -d -t gaia-session-start-plain-XXXXXX)
  invoke_hook_in "$PLAIN" '' "$HOOK_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$PLAIN/claude-session-start" ]
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
  [ -f "$REPO/.git/claude-session-start" ]
}

@test "a janitor that exits non-zero never fails the session" {
  # This is the fail-open guarantee. A janitor bug must cost a sweep, not the
  # session, and must not cost the HEAD stamp either.
  REPO=$("$HELPERS/tmp-git-repo.sh")
  hook=$(install_hook)
  printf '#!/usr/bin/env bash\necho boom >&2\nexit 3\n' > "$REPO/.claude/hooks/local-janitor.sh"
  chmod +x "$REPO/.claude/hooks/local-janitor.sh"
  invoke_hook_in "$REPO" '' "$hook"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.git/claude-session-start" ]
}

@test "the stamp is written before the janitor runs" {
  # Ordering matters: a janitor that hangs or dies must not be able to take
  # the baseline with it.
  REPO=$("$HELPERS/tmp-git-repo.sh")
  hook=$(install_hook)
  # `$PWD` stays unexpanded on purpose: the generated stub must evaluate it
  # when the hook runs it, not when this printf writes it, or the assertion
  # would read the bats process's cwd instead of the hook's.
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\n[ -s "$PWD/.git/claude-session-start" ] || exit 1\n: > "%s/order.ok"\n' "$REPO" \
    > "$REPO/.claude/hooks/local-janitor.sh"
  chmod +x "$REPO/.claude/hooks/local-janitor.sh"
  invoke_hook_in "$REPO" '' "$hook"
  [ "$status" -eq 0 ]
  [ -f "$REPO/order.ok" ]
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
  # Re-stamping on clear or compact would reset the Stop hook's baseline mid-session.
  scratch_settings="$BATS_TEST_TMPDIR/settings.json"
  jq '.hooks.SessionStart += [{matcher: "clear|compact", hooks: [{type: "command", command: "\"$(git rev-parse --show-toplevel)/.claude/hooks/wiki-session-start.sh\""}]}]' \
    "$SETTINGS_ABSOLUTE_PATH" > "$scratch_settings"
  run jq -e "$RESET_MATCHER_REGISTRATION_FILTER" "$scratch_settings"
  [ "$status" -eq 0 ]
}

# --- the dirty baseline for the Stop hook ---

@test "the dirty baseline is empty on a clean tree" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  invoke_hook_in "$REPO" '' "$HOOK_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$REPO/.git/claude-session-wiki-dirty" ]
  [ ! -s "$REPO/.git/claude-session-wiki-dirty" ]
}

@test "the dirty baseline is non-empty on a dirty tree and the hook stays silent" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  echo "dirty" >> "$REPO/wiki/index.md"
  invoke_hook_in "$REPO" '' "$HOOK_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -s "$REPO/.git/claude-session-wiki-dirty" ]
}

@test "the dirty baseline is written when the session starts in frontend/" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  mkdir -p "$REPO/frontend"
  echo "dirty" >> "$REPO/wiki/index.md"
  invoke_hook_in "$REPO/frontend" '' "$HOOK_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
  [ -s "$REPO/.git/claude-session-wiki-dirty" ]
}

# --- header text describes the 2.x plugin contract ---

@test "the start hook header no longer defers hot-cache restoration to the model or the plugin skill" {
  grep -qF -- 'left to the model' "$HOOK_ABSOLUTE_PATH" && return 1
  grep -qF -- 'claude-obsidian:wiki skill' "$HOOK_ABSOLUTE_PATH" && return 1
  return 0
}

@test "the stop hook header no longer describes a PostToolUse auto-commit" {
  grep -qF -- 'PostToolUse' "$HOOKS_SOURCE_DIRECTORY/wiki-session-stop.sh" && return 1
  return 0
}

# --- missing library ---

@test "start hook without its library exits 0 silently and still stamps HEAD" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  hook=$(install_hook_without_library)
  assert_missing_library_is_silent "$hook"
}

@test "guard: a start hook without the library guard writes to stderr and fails the silence assertion" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  hook=$(install_hook_without_library)
  sed -e 's|^if \[ -f "\$_hook_directory/lib/wiki-dirty-fingerprint.sh" \]; then$|if true; then|' "$hook" > "$hook.mutated"
  mv "$hook.mutated" "$hook"
  grep -qF -- 'if true; then' "$hook" || return 1
  run assert_missing_library_is_silent "$hook"
  [ "$status" -ne 0 ]
}

@test "stop hook without its library exits 0 silently despite uncommitted wiki edits" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  mkdir -p "$REPO/.claude/hooks"
  cp "$HOOKS_SOURCE_DIRECTORY/wiki-session-stop.sh" "$REPO/.claude/hooks/wiki-session-stop.sh"
  git -C "$REPO" rev-parse HEAD > "$REPO/.git/claude-session-start"
  echo "dirty" >> "$REPO/wiki/index.md"
  result_status=0
  captured=$(cd "$REPO" && bash "$REPO/.claude/hooks/wiki-session-stop.sh" < /dev/null 2>&1) || result_status=$?
  [ "$result_status" -eq 0 ]
  [ -z "$captured" ]
}
