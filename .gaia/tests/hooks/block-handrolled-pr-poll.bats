#!/usr/bin/env bats

# Tests for .claude/hooks/block-handrolled-pr-poll.sh.
#
# The hook denies a shell loop polling `gh pr view` for PR state, or
# `gh pr checks`, when the command never reads `mergeable`. Such a loop cannot
# end once the base branch has landed a conflicting change: the queued `--auto`
# merge never lands and nothing left in the loop can fire. Exit 2 = block
# (stderr shown to Claude); exit 0 = allow.
#
# The hook is a pure stdin->pattern->exit filter beyond the shared
# jq-availability arm, so each test pipes a synthetic PreToolUse payload and
# asserts on the exit code, and on the denial's own text where the message
# carries the claim.
#
# THE ALLOW CASES ARE THE LOAD-BEARING HALF HERE. This is a text heuristic over
# an unbounded surface, so its real risk is denying a legitimate command, and a
# deny-only suite would say nothing about that. The false positives pinned
# below are the specific ones the matcher was narrowed to avoid: prose
# mentioning a poll inside a `--body`, a loop enumerating pull requests by a
# field other than state, an ordinary one-shot state read, and any loop that
# already satisfies the rule by reading `mergeable`.
#
# The multi-line fixtures are not decoration. A matcher built from `^` and the
# separator punctuation alone reads a loop keyword after a newline as prose, and
# a multi-line command is the ordinary shape for a poll, so that gap would leave
# the guard inert on most real instances of exactly what it denies.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK="$HOOKS_SRC/block-handrolled-pr-poll.sh"
  SETTINGS_ABS="${HOOKS_SRC%/hooks}/settings.json"
}

# Pipe a Bash PreToolUse payload for $1 to the hook and capture status/output.
run_hook() {
  local cmd="$1" payload
  payload=$(jq -nc --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}')
  invoke_hook "$payload" "$HOOK"
}

# The same, for a Monitor payload. Monitor carries its shell command in the
# same `tool_input.command` field, so the two differ only in `tool_name`.
run_hook_monitor() {
  local cmd="$1" payload
  payload=$(jq -nc --arg c "$cmd" '{tool_name: "Monitor", tool_input: {command: $c}}')
  invoke_hook "$payload" "$HOOK"
}

# --- blocked: the shape that spins forever ------------------------------------

@test "the observed recurrence is blocked" {
  # Verbatim from gaia-react/gaia#2203: the loop substituted after the
  # worktree-isolation guard refused the documented compound form. It waits
  # only for the state to leave OPEN, so a CONFLICTING base never ends it.
  run_hook 'until [ "$(gh pr view 2203 --json state --jq .state)" != "OPEN" ]; do sleep 30; done'
  assert_blocked_by_exit
}

@test "a while loop on gh pr checks is blocked" {
  run_hook 'while ! gh pr checks 42 --required; do sleep 20; done'
  assert_blocked_by_exit
}

@test "a for loop reading .state is blocked" {
  run_hook 'for i in 1 2 3; do s=$(gh pr view 9 --json state -q .state); [ "$s" = MERGED ] && break; sleep 10; done'
  assert_blocked_by_exit
}

@test "a multi-line poll is blocked (the loop keyword follows a newline)" {
  run_hook 'gh pr merge 42 --auto
for i in 1 2 3; do
  gh pr view 42 --json state
  sleep 30
done'
  assert_blocked_by_exit
}

@test "a loop keyword after && is blocked" {
  run_hook 'gh pr merge 9 --auto && until gh pr view 9 --json state | grep -q MERGED; do sleep 5; done'
  assert_blocked_by_exit
}

@test "a poll nested inside an if is blocked" {
  # `then` opens a command position that no punctuation precedes, and a poll
  # one level inside a conditional is an ordinary spelling rather than an
  # evasive one.
  run_hook 'if true; then until gh pr view 5 --json state; do sleep 1; done; fi'
  assert_blocked_by_exit
}

@test "a poll inside a brace group is blocked" {
  run_hook '{ while gh pr view 5 --json state; do sleep 1; done; }'
  assert_blocked_by_exit
}

@test "a poll inside a command substitution is blocked" {
  # `done` closes on the substitution's `)` here rather than on a space or a
  # semicolon, which is what the `done` half of the pair has to admit.
  run_hook 'x=$(for i in 1 2; do gh pr view 5 --json state; done)'
  assert_blocked_by_exit
}

@test "a poll nested in another loop body is blocked" {
  run_hook 'for n in 1 2; do until gh pr view $n --json state; do sleep 1; done; done'
  assert_blocked_by_exit
}

@test "the same poll armed through Monitor is blocked" {
  # Monitor takes a raw shell command in the same field Bash does, so the loop
  # this hook exists to deny is armable through it verbatim. Binding only Bash
  # would leave the guard inert in the tool beside the one it watches.
  run_hook_monitor 'until [ "$(gh pr view 2203 --json state --jq .state)" != "OPEN" ]; do sleep 30; done'
  assert_blocked_by_exit
}

@test "a Monitor poll on gh pr checks is blocked" {
  run_hook_monitor 'while true; do gh pr checks 42; sleep 30; done'
  assert_blocked_by_exit
}

@test "a Monitor loop that reads mergeable is allowed" {
  # The stand-down has to reach Monitor too, or the tool the guard newly binds
  # is one where satisfying the rule still denies.
  run_hook_monitor 'while true; do gh pr view 9 --json state,mergeable; sleep 30; done'
  assert_allowed_by_exit
}

@test "a Monitor call carrying ws rather than a command is allowed" {
  # A WebSocket subscription is not a poll, and it carries no `command` field
  # at all, so the hook resolves the empty string and allows.
  payload=$(jq -nc '{tool_name: "Monitor", tool_input: {ws: {url: "wss://example.test/stream"}}}')
  invoke_hook "$payload" "$HOOK"
  assert_allowed_by_exit
}

@test "the denial names the shipped script, so there is an alternative to take" {
  run_hook 'until [ "$(gh pr view 5 --json state --jq .state)" != "OPEN" ]; do sleep 30; done'
  [ "$status" -eq 2 ]
  grep -qF -- '.gaia/scripts/pr-wait-merge.sh' <<<"$output"
}

@test "the denial states the failure mode, not just the refusal" {
  run_hook 'until [ "$(gh pr view 5 --json state --jq .state)" != "OPEN" ]; do sleep 30; done'
  [ "$status" -eq 2 ]
  grep -qF -- 'mergeable' <<<"$output"
  grep -qF -- 'CONFLICTING' <<<"$output"
}

@test "the denial's verdict list carries every verdict the script can print" {
  # Derived from the script's own header rather than restated here, so adding a
  # verdict without amending the denial goes red. The denial is the only
  # contract an agent reads before taking the blessed path, so a caller
  # branching on a stale list falls through silently on the missing state.
  local wait_script verdicts v
  wait_script="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/scripts/pr-wait-merge.sh"
  [ -f "$wait_script" ] || return 1
  # The header's exit table lines, e.g. "#   6   CLOSED        the pull ...".
  verdicts=$(sed -n 's/^#   [0-9]\{1,3\}   \([A-Z_]\{3,\}\).*/\1/p' "$wait_script")
  [ -n "$verdicts" ] || return 1

  # Guard the derivation against a header line that stops matching. A floor
  # would not: reformatting one verdict's line drops it from the set while a
  # `-ge <n>` still passes, and the test then greens over a denial that no
  # longer names it. Count the script's own verdict arms instead and require
  # equality, so losing one line from either side reds.
  local arms n_verdicts n_arms
  arms=$(sed -n 's/^  \([A-Z_]\{3,\}\))$/\1/p' "$wait_script")
  n_verdicts=$(printf '%s\n' "$verdicts" | grep -c .)
  n_arms=$(printf '%s\n' "$arms" | grep -c .)
  [ "$n_arms" -ge 2 ] || return 1
  [ "$n_verdicts" -eq "$((n_arms + 1))" ] || return 1

  run_hook 'until [ "$(gh pr view 5 --json state --jq .state)" != "OPEN" ]; do sleep 30; done'
  [ "$status" -eq 2 ]
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    grep -qF -- "$v" <<<"$output" || return 1
  done <<<"$verdicts"
}

@test "the denial names the stand-down, so a genuine custom loop has a way out" {
  run_hook 'until [ "$(gh pr view 5 --json state --jq .state)" != "OPEN" ]; do sleep 30; done'
  [ "$status" -eq 2 ]
  grep -qF -- 'this guard stands down' <<<"$output"
}

# --- allowed: escape 1, the blessed path --------------------------------------

@test "the shipped script itself is allowed" {
  run_hook 'bash .gaia/scripts/pr-wait-merge.sh --pr 42'
  assert_allowed_by_exit
}

@test "a command naming the script while looping is allowed" {
  # Covers the script's own bats suite and any command quoting the denied shape
  # in a heredoc while writing about it.
  run_hook 'for f in 1 2; do gh pr view $f --json state; done # see pr-wait-merge.sh'
  assert_allowed_by_exit
}

# --- allowed: escape 2, the command already satisfies the rule ----------------

@test "a hand-written loop that reads mergeable is allowed" {
  run_hook 'until gh pr view 9 --json state,mergeable | grep -q CONFLICTING; do sleep 5; done'
  assert_allowed_by_exit
}

@test "a multi-line loop reading mergeable is allowed" {
  run_hook 'for i in 1 2; do
  gh pr view 42 --json state,mergeable
done'
  assert_allowed_by_exit
}

# --- allowed: not a poll at all -----------------------------------------------

@test "a one-shot state read is allowed" {
  run_hook 'gh pr view 42 --json state --jq .state'
  assert_allowed_by_exit
}

@test "a loop reading a field other than state is allowed" {
  run_hook 'for n in 1 2; do gh pr view $n --json title; done'
  assert_allowed_by_exit
}

@test "prose mentioning a poll inside a --body is allowed" {
  # The regression guard for the false positive the matcher was narrowed
  # against: this carries `for`, `do`, and `gh pr checks`, and is not a loop.
  run_hook 'gh pr create --body "we used to do a for loop on gh pr checks here"'
  assert_allowed_by_exit
}

@test "a loop touching no gh pr command is allowed" {
  run_hook 'for f in *.sh; do shellcheck "$f"; done'
  assert_allowed_by_exit
}

@test "an empty command is allowed" {
  run_hook ''
  assert_allowed_by_exit
}

@test "a tool call that is neither Bash nor Monitor is allowed" {
  # The fixture carries a `command` holding the denied shape verbatim, and that
  # is what makes the tool check the only thing allowing it. A payload whose
  # tool_input has no `command` at all is allowed by the empty-command arm
  # several lines further down, so it greens whatever the tool check accepts
  # and pins nothing.
  payload=$(jq -nc '{tool_name: "Read", tool_input: {command: "until [ \"$(gh pr view 1 --json state --jq .state)\" != \"OPEN\" ]; do sleep 30; done"}}')
  invoke_hook "$payload" "$HOOK"
  assert_allowed_by_exit
}

# --- registration: the hook is reached at all ---------------------------------
#
# Every test above invokes the hook by path, so all of them stay green on a
# dropped registration, with the guard inert in every real session. This is the
# only assertion that reads the file deciding whether the hook runs.

@test "the hook is registered in settings.json" {
  hook_registered "$SETTINGS_ABS" '.hooks.PreToolUse[] | select(.matcher == "Bash")' block-handrolled-pr-poll.sh
}

@test "the hook is registered for Monitor too" {
  # The tool check inside the hook reaches nothing the matchers do not deliver,
  # so the Monitor deny tests above stay green on a dropped Monitor
  # registration with the guard inert for that tool in every real session.
  hook_registered "$SETTINGS_ABS" '.hooks.PreToolUse[] | select(.matcher == "Monitor")' block-handrolled-pr-poll.sh
}
