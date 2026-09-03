#!/usr/bin/env bats

# Tests for .claude/hooks/wiki-session-start.sh.
#
# SessionStart hook with two jobs, both pure side effect and neither of them
# ever reported: record HEAD into $GIT_DIR/claude-session-start so the Stop
# hook can diff against the session's starting point, then hand off to the
# bounded working-state janitors. It writes nothing to stdout, decides nothing,
# and always exits 0.
#
# The stamp is the load-bearing half. If it stops being written, the Stop hook
# loses its baseline and wiki commits made during the session go undetected --
# with no error, no output, and nothing that distinguishes it from a session
# that genuinely changed no wiki page. The delegation tests below cover the
# other half: the janitors must run when present and must not be able to fail
# the session when they break.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABS="$HOOKS_SRC/wiki-session-start.sh"
  SETTINGS_ABS="${HOOKS_SRC%/hooks}/settings.json"
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
  local rel="$1"
  mkdir -p "$REPO/$(dirname "$rel")"
  printf '#!/usr/bin/env bash\n: > "%s.ran"\n' "$REPO/$(basename "$rel")" > "$REPO/$rel"
  chmod +x "$REPO/$rel"
}

# --- the HEAD stamp ---

@test "records HEAD into the git dir" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  invoke_hook_in "$REPO" '' "$HOOK_ABS"
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
  invoke_hook_in "$REPO" '' "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a later session re-stamps to the new HEAD" {
  # The stamp is a per-session baseline, not a first-run record: a stale value
  # would make the Stop hook diff against the wrong starting point.
  REPO=$("$HELPERS/tmp-git-repo.sh")
  invoke_hook_in "$REPO" '' "$HOOK_ABS"
  first=$(cat "$REPO/.git/claude-session-start")

  echo "later" >> "$REPO/wiki/index.md"
  git -C "$REPO" add wiki/index.md
  git -C "$REPO" commit --quiet -m "second"

  invoke_hook_in "$REPO" '' "$HOOK_ABS"
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
  invoke_hook_in "$REPO" '' "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "outside a git repository the hook is a silent no-op" {
  PLAIN=$(mktemp -d -t gaia-session-start-plain-XXXXXX)
  invoke_hook_in "$PLAIN" '' "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$PLAIN/claude-session-start" ]
}

# --- delegation to the bounded janitors ---

@test "runs the local janitor when it is present" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  stub_script ".claude/hooks/local-janitor.sh"
  invoke_hook_in "$REPO" '' "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/local-janitor.sh.ran" ]
}

@test "runs the audit re-spawn prune when it is present" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  stub_script ".gaia/scripts/audit-respawn-prune.sh"
  invoke_hook_in "$REPO" '' "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/audit-respawn-prune.sh.ran" ]
}

@test "a missing janitor is not an error" {
  # An adopter clone, or a checkout mid-update, can be missing either script.
  # The session must start anyway.
  REPO=$("$HELPERS/tmp-git-repo.sh")
  [ ! -f "$REPO/.claude/hooks/local-janitor.sh" ]
  invoke_hook_in "$REPO" '' "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.git/claude-session-start" ]
}

@test "a janitor that exits non-zero never fails the session" {
  # This is the fail-open guarantee. A janitor bug must cost a sweep, not the
  # session, and must not cost the HEAD stamp either.
  REPO=$("$HELPERS/tmp-git-repo.sh")
  mkdir -p "$REPO/.claude/hooks"
  printf '#!/usr/bin/env bash\necho boom >&2\nexit 3\n' > "$REPO/.claude/hooks/local-janitor.sh"
  chmod +x "$REPO/.claude/hooks/local-janitor.sh"
  invoke_hook_in "$REPO" '' "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.git/claude-session-start" ]
}

@test "the stamp is written before the janitors run" {
  # Ordering matters: a janitor that hangs or dies must not be able to take
  # the baseline with it.
  REPO=$("$HELPERS/tmp-git-repo.sh")
  mkdir -p "$REPO/.claude/hooks"
  # `$PWD` stays unexpanded on purpose: the generated stub must evaluate it
  # when the hook runs it, not when this printf writes it, or the assertion
  # would read the bats process's cwd instead of the hook's.
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\n[ -s "$PWD/.git/claude-session-start" ] || exit 1\n: > "%s/order.ok"\n' "$REPO" \
    > "$REPO/.claude/hooks/local-janitor.sh"
  chmod +x "$REPO/.claude/hooks/local-janitor.sh"
  invoke_hook_in "$REPO" '' "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -f "$REPO/order.ok" ]
}

# --- structural ---

@test "wiki-session-start.sh is executable" {
  [ -x "$HOOK_ABS" ]
}

@test "settings.json registers the hook under SessionStart startup|resume" {
  run jq -e '.hooks.SessionStart[] | select(.matcher == "startup|resume") | .hooks[] | select(.command | endswith("/.claude/hooks/wiki-session-start.sh\""))' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}
