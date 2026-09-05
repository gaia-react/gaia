#!/usr/bin/env bats

# Tests for .claude/hooks/block-fourth-audit-round.sh.
#
# The guard denies the FOURTH Code Audit Team dispatch wave in one session on
# one branch: a round is identified by the acting tree's HEAD tree SHA, and a
# dispatch whose tree is already recorded is the same wave (a parallel
# sibling, or the hardened single re-dispatch of a no-op'd member) rather than
# a new one. The counter is session-keyed and main-anchored, exactly like
# block-spec-plan-chain.sh's sentinel, and this suite's structure mirrors
# block-spec-plan-chain.bats for that reason: same helpers, same
# assert_denied_by_json / assert_allowed_by_json mechanism
# (helpers/run-hook.sh), same tmp-git-repo.sh fixture.
#
# The hook path is overridable (GAIA_ROUND_CAP_HOOK) so a red fixture can be
# proven against a broken COPY of the hook without ever touching the live one,
# which stays registered and active for the whole session this suite runs in.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  GAIA_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  HOOK_ABS="${GAIA_ROUND_CAP_HOOK:-$GAIA_ROOT/.claude/hooks/block-fourth-audit-round.sh}"
  AUDIT_CI_YML="$GAIA_ROOT/.gaia/audit-ci.yml"
  HELPERS="$BATS_TEST_DIRNAME/helpers"

  # A real git repo: the hook resolves the counter's root against the main
  # checkout (gaia_resolve_main_root), so every path below runs inside one.
  REPO=$(bash "$HELPERS/tmp-git-repo.sh")
  cd "$REPO" || return 1

  SESSION="sess-round-cap-1"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
}

# --- payload builders ---------------------------------------------------------

current_tree() {
  git -C "$REPO" rev-parse 'HEAD^{tree}'
}

current_branch() {
  git -C "$REPO" branch --show-current
}

counter_path() {
  printf '%s/.gaia/local/cache/audit-rounds-%s.json' "$REPO" "${1:-$SESSION}"
}

# dispatch_member SUBAGENT_TYPE [SESSION] [CALLER_AGENT_TYPE]
# CALLER_AGENT_TYPE, when given, is the TOP-LEVEL agent_type field
# block-selfheal-paths.sh reads (the dispatching agent's own identity), never
# tool_input.agent_type, which does not exist.
dispatch_member() {
  local sub="$1" sid="${2:-$SESSION}" caller="${3:-}"
  local payload
  if [ -n "$caller" ]; then
    payload=$(jq -n --arg s "$sid" --arg sub "$sub" --arg cwd "$REPO" --arg caller "$caller" \
      '{session_id: $s, hook_event_name: "PreToolUse", tool_name: "Agent",
        cwd: $cwd, agent_type: $caller, tool_input: {subagent_type: $sub}}')
  else
    payload=$(jq -n --arg s "$sid" --arg sub "$sub" --arg cwd "$REPO" \
      '{session_id: $s, hook_event_name: "PreToolUse", tool_name: "Agent",
        cwd: $cwd, tool_input: {subagent_type: $sub}}')
  fi
  invoke_hook "$payload" "$HOOK_ABS"
}

run_bash_tool() {
  local cmd="$1" sid="${2:-$SESSION}"
  local payload
  payload=$(jq -n --arg s "$sid" --arg c "$cmd" --arg cwd "$REPO" \
    '{session_id: $s, hook_event_name: "PreToolUse", tool_name: "Bash",
      cwd: $cwd, tool_input: {command: $c}}')
  invoke_hook "$payload" "$HOOK_ABS"
}

run_session_start() {
  local src="$1" sid="${2:-$SESSION}"
  local payload
  payload=$(jq -n --arg s "$sid" --arg src "$src" \
    '{session_id: $s, hook_event_name: "SessionStart", source: $src}')
  invoke_hook "$payload" "$HOOK_ABS"
}

# seed_counter SESSION BRANCH TREE...
# Writes a counter file directly, bypassing the hook, so a test can start from
# "three rounds already spent" without three real commits.
seed_counter() {
  local sid="$1" branch="$2"
  shift 2
  local trees_json
  trees_json=$(printf '%s\n' "$@" | jq -R . | jq -s .)
  mkdir -p "$REPO/.gaia/local/cache"
  jq -n --arg sid "$sid" --arg branch "$branch" --argjson trees "$trees_json" \
    '{schema: 1, session_id: $sid, updated_at: "2020-01-01T00:00:00Z",
      branches: {($branch): {trees: $trees}}}' \
    > "$(counter_path "$sid")"
}

commit_change() {
  echo "change $RANDOM" >> "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit -q -m "change"
}

# roster_members: every code-audit-* member .gaia/audit-ci.yml's auditors:
# block names, derived rather than hand-listed so the roster's other members
# stay bound to this suite as the roster grows.
#
# It reconciles rather than merely reads, the form
# .gaia/tests/hooks/audit-root-resolution.bats already commits over this same
# file. A scan that recognizes one spelling of an entry answers a short read
# and a complete one identically, and the short read is the dangerous half: the
# one test that catches a narrowed member filter would stay green over the
# member it never drove. So count the entries at the list indent, count the
# `- name: X` reads, and refuse on the difference rather than returning the
# names it happened to recognize.
roster_members() {
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    /^auditors[[:space:]]*:/ { in_block = 1; next }
    /^[^[:space:]]/ { in_block = 0; next }
    !in_block { next }
    /^[[:space:]]+-([[:space:]]|$)/ {
      match($0, /^[[:space:]]+/)
      indent = RLENGTH
      if (entry_indent == 0) entry_indent = indent
      if (indent != entry_indent) next
      entries++
      if ($2 == "name:" && $3 != "" && $3 !~ /^#/) names[++n] = $3
      next
    }
    END {
      if (entries != n) {
        printf "roster_members: %s has %d auditors entr(ies) but %d readable `- name: X`; an entry this scan cannot read would silently shrink the roster\n", FILENAME, entries, n > "/dev/stderr"
        exit 1
      }
      for (i = 1; i <= n; i++) print names[i]
    }
  ' "$1"
}

# --- Deny arm: the guard's failing state, driven deliberately ----------------

@test "a fourth wave on a new tree, with three trees already spent, is denied naming the reason and the counter path" {
  seed_counter "$SESSION" "$(current_branch)" fake-tree-1 fake-tree-2 fake-tree-3
  dispatch_member "code-audit-frontend"
  assert_denied_by_json
  grep -qF -- "three Code Audit Team rounds are already spent" <<<"$output"
  grep -qF -- "$(counter_path)" <<<"$output"
}

@test "a denied wave writes nothing: the counter still holds exactly three trees and its updated_at is unchanged" {
  seed_counter "$SESSION" "$(current_branch)" fake-tree-1 fake-tree-2 fake-tree-3
  dispatch_member "code-audit-frontend"
  assert_denied_by_json
  [ "$(jq -r '.updated_at' "$(counter_path)")" = "2020-01-01T00:00:00Z" ]
  [ "$(jq -r ".branches[\"$(current_branch)\"].trees | length" "$(counter_path)")" -eq 3 ]
}

@test "the deny reason names the continuation-prompt handoff, the /clear release, and that the cap is not a merge blocker" {
  seed_counter "$SESSION" "$(current_branch)" fake-tree-1 fake-tree-2 fake-tree-3
  dispatch_member "code-audit-frontend"
  assert_denied_by_json
  grep -qF -- "continuation prompt" <<<"$output"
  grep -qF -- "/clear" <<<"$output"
  grep -qF -- "not a merge blocker" <<<"$output"
}

# --- Wave identity: the crux ---------------------------------------------------

@test "a dispatch on a tree already recorded is the same wave and is free; once HEAD moves the same session is denied" {
  local head_tree
  head_tree=$(current_tree)
  seed_counter "$SESSION" "$(current_branch)" "$head_tree" fake-tree-a fake-tree-b
  dispatch_member "code-audit-frontend"
  assert_allowed_by_json
  [ "$(jq -r '.updated_at' "$(counter_path)")" = "2020-01-01T00:00:00Z" ]

  commit_change
  dispatch_member "code-audit-frontend"
  assert_denied_by_json
}

@test "four dispatches of four distinct code-audit-* members against one HEAD leave exactly one tree recorded" {
  dispatch_member "code-audit-frontend"
  assert_allowed_by_json
  dispatch_member "code-audit-github-workflows"
  assert_allowed_by_json
  dispatch_member "code-audit-maintainer-node"
  assert_allowed_by_json
  dispatch_member "code-audit-maintainer-shell"
  assert_allowed_by_json

  [ "$(jq -r ".branches[\"$(current_branch)\"].trees | length" "$(counter_path)")" -eq 1 ]

  commit_change
  dispatch_member "code-audit-frontend"
  assert_allowed_by_json
}

@test "the hardened single re-dispatch of the same member against an unmoved HEAD is allowed and grows nothing" {
  dispatch_member "code-audit-frontend"
  assert_allowed_by_json
  dispatch_member "code-audit-frontend"
  assert_allowed_by_json
  [ "$(jq -r ".branches[\"$(current_branch)\"].trees | length" "$(counter_path)")" -eq 1 ]
}

@test "three waves with three distinct trees are each allowed and grow trees by one; the fourth distinct tree is denied" {
  dispatch_member "code-audit-frontend"
  assert_allowed_by_json
  [ "$(jq -r ".branches[\"$(current_branch)\"].trees | length" "$(counter_path)")" -eq 1 ]

  commit_change
  dispatch_member "code-audit-frontend"
  assert_allowed_by_json
  [ "$(jq -r ".branches[\"$(current_branch)\"].trees | length" "$(counter_path)")" -eq 2 ]

  commit_change
  dispatch_member "code-audit-frontend"
  assert_allowed_by_json
  [ "$(jq -r ".branches[\"$(current_branch)\"].trees | length" "$(counter_path)")" -eq 3 ]

  commit_change
  dispatch_member "code-audit-frontend"
  assert_denied_by_json
}

# --- Scope discipline ----------------------------------------------------------

@test "subagent_type general-purpose is allowed and writes nothing, even carrying a top-level agent_type: code-audit-frontend" {
  seed_counter "$SESSION" "$(current_branch)" fake-tree-1 fake-tree-2 fake-tree-3
  dispatch_member "general-purpose" "$SESSION" "code-audit-frontend"
  assert_allowed_by_json
  [ -z "$output" ]
  [ "$(jq -r '.updated_at' "$(counter_path)")" = "2020-01-01T00:00:00Z" ]
  [ "$(jq -r ".branches[\"$(current_branch)\"].trees | length" "$(counter_path)")" -eq 3 ]
}

@test "Explore and general-purpose are each allowed and each write nothing, from three-trees-spent state" {
  local sub
  for sub in Explore general-purpose; do
    seed_counter "$SESSION" "$(current_branch)" fake-tree-1 fake-tree-2 fake-tree-3
    dispatch_member "$sub"
    assert_allowed_by_json
    [ -z "$output" ]
    [ "$(jq -r ".branches[\"$(current_branch)\"].trees | length" "$(counter_path)")" -eq 3 ] || { echo "subagent_type '$sub' grew the counter" >&2; return 1; }
  done
}

@test "every code-audit-* roster member counts toward the cap, not only code-audit-frontend" {
  local members
  # Captured rather than piped into the loop: a process substitution discards
  # roster_members' exit status, which is the whole signal when an entry is
  # spelled in a way the scan cannot read.
  members=$(roster_members "$AUDIT_CI_YML") || {
    echo "roster_members could not read $AUDIT_CI_YML's auditors: block; see its message above" >&2
    return 1
  }
  [ -n "$members" ] || { echo "roster_members read nothing out of $AUDIT_CI_YML's auditors: block" >&2; return 1; }

  local m
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    seed_counter "$SESSION" "$(current_branch)" fake-tree-1 fake-tree-2 fake-tree-3
    dispatch_member "$m"
    assert_denied_by_json || { echo "subagent_type '$m' did not count toward the cap" >&2; return 1; }
  done <<<"$members"
}

# --- Per-branch and per-session partitioning -----------------------------------

@test "three trees recorded on one branch do not deny a dispatch from a different branch in the same repo" {
  dispatch_member "code-audit-frontend"
  assert_allowed_by_json
  commit_change
  dispatch_member "code-audit-frontend"
  assert_allowed_by_json
  commit_change
  dispatch_member "code-audit-frontend"
  assert_allowed_by_json
  [ "$(jq -r '.branches["main"].trees | length' "$(counter_path)")" -eq 3 ]

  git -C "$REPO" checkout -q -b branch-b
  commit_change
  dispatch_member "code-audit-frontend"
  assert_allowed_by_json

  [ "$(jq -r '.branches | keys | length' "$(counter_path)")" -eq 2 ]
  [ "$(jq -r '.branches["branch-b"].trees | length' "$(counter_path)")" -eq 1 ]
}

@test "three trees recorded for one session_id do not deny a dispatch carrying a different session_id" {
  dispatch_member "code-audit-frontend" "sess1"
  assert_allowed_by_json
  commit_change
  dispatch_member "code-audit-frontend" "sess1"
  assert_allowed_by_json
  commit_change
  dispatch_member "code-audit-frontend" "sess1"
  assert_allowed_by_json
  [ "$(jq -r '.branches["main"].trees | length' "$(counter_path "sess1")")" -eq 3 ]

  commit_change
  dispatch_member "code-audit-frontend" "sess2"
  assert_allowed_by_json

  [ -f "$(counter_path "sess1")" ]
  [ -f "$(counter_path "sess2")" ]
}

# --- Reset semantics -------------------------------------------------------------

@test "SessionStart with source clear removes the counter, and a following dispatch is allowed" {
  seed_counter "$SESSION" "$(current_branch)" fake-tree-1 fake-tree-2 fake-tree-3
  run_session_start "clear"
  [ "$status" -eq 0 ]
  [ ! -e "$(counter_path)" ]
  dispatch_member "code-audit-frontend"
  assert_allowed_by_json
}

@test "SessionStart with source resume, and separately startup, leave a three-tree counter intact and the next fourth wave still denied" {
  seed_counter "$SESSION" "$(current_branch)" fake-tree-1 fake-tree-2 fake-tree-3
  run_session_start "resume"
  [ "$status" -eq 0 ]
  [ -f "$(counter_path)" ]
  [ "$(jq -r ".branches[\"$(current_branch)\"].trees | length" "$(counter_path)")" -eq 3 ]

  run_session_start "startup"
  [ "$status" -eq 0 ]
  [ -f "$(counter_path)" ]
  [ "$(jq -r ".branches[\"$(current_branch)\"].trees | length" "$(counter_path)")" -eq 3 ]

  dispatch_member "code-audit-frontend"
  assert_denied_by_json
}

# --- Fail-open arms --------------------------------------------------------------

@test "a Bash tool call is inert regardless of session or command" {
  run_bash_tool "pnpm typecheck"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an Agent dispatch with no subagent_type is allowed silently" {
  local payload
  payload=$(jq -n --arg s "$SESSION" --arg cwd "$REPO" \
    '{session_id: $s, hook_event_name: "PreToolUse", tool_name: "Agent",
      cwd: $cwd, tool_input: {}}')
  invoke_hook "$payload" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a member dispatch with no session_id is allowed silently" {
  local payload
  payload=$(jq -n --arg cwd "$REPO" \
    '{hook_event_name: "PreToolUse", tool_name: "Agent",
      cwd: $cwd, tool_input: {subagent_type: "code-audit-frontend"}}')
  invoke_hook "$payload" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a cwd that is not a git repository is allowed silently" {
  local not_a_repo
  not_a_repo=$(mktemp -d -t gaia-round-cap-non-repo-XXXXXX)
  local payload
  payload=$(jq -n --arg s "$SESSION" --arg cwd "$not_a_repo" \
    '{session_id: $s, hook_event_name: "PreToolUse", tool_name: "Agent",
      cwd: $cwd, tool_input: {subagent_type: "code-audit-frontend"}}')
  invoke_hook "$payload" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  rm -rf "$not_a_repo"
}

@test "a session id that is not a safe filename falls through to allow and creates no file anywhere" {
  dispatch_member "code-audit-frontend" "../../etc/passwd"
  assert_allowed_by_json
  [ ! -e "$REPO/.gaia/local/cache/audit-rounds-../../etc/passwd.json" ]
  [ ! -e "/etc/passwd.json" ]
}

@test "a corrupt counter is read as empty state: the dispatch is allowed and the file is replaced by a well-formed single-tree counter" {
  mkdir -p "$REPO/.gaia/local/cache"
  printf 'not json at all' > "$(counter_path)"
  dispatch_member "code-audit-frontend"
  assert_allowed_by_json
  [ "$(jq -r '.schema' "$(counter_path)")" = "1" ]
  [ "$(jq -r ".branches[\"$(current_branch)\"].trees | length" "$(counter_path)")" -eq 1 ]
  [ "$(jq -r ".branches[\"$(current_branch)\"].trees[0]" "$(counter_path)")" = "$(current_tree)" ]
}

# --- Non-interference --------------------------------------------------------

@test "a Bash tool call running gh pr merge is inert even with three rounds already spent" {
  seed_counter "$SESSION" "$(current_branch)" fake-tree-1 fake-tree-2 fake-tree-3
  run_bash_tool "gh pr merge 123 --squash"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
