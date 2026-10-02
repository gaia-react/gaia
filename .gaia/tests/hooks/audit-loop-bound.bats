#!/usr/bin/env bats
#
# Tests for .claude/hooks/audit-loop-bound.sh by direct invocation with
# fixture payloads. Every case builds its repository, findings sidecars and
# state file under $BATS_TEST_TMPDIR with .gaia/tests/helpers/audit-loop-fixture.sh;
# no case calls the evaluator CLI to decide its outcome.
#
# GAIA_LOOP_BOUND_HOOK points the suite at a scratch copy of the hook, which
# is how a mutant is run against it without touching the working file.
# GAIA_TEST_HOOK_BASH names the bash that runs the hook (default: bash on PATH).
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/audit-loop-bound.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HOOK="${GAIA_LOOP_BOUND_HOOK:-$REPO_ROOT/.claude/hooks/audit-loop-bound.sh}"
  BOUND_HOOK="$HOOK"
  unset GAIA_AUDIT_CHECKPOINT_ROUND GAIA_AUDIT_GRANT_ROUNDS GAIA_AUDIT_LOOP_DEADLINE_SECONDS
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/scripts/audit-loop-eval.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/audit-loop-fixture.sh"
  alf_init
  alf_branch feat/loop
  FRONTEND_MEMBER=code-audit-frontend
  SID=sess-a
  STUB_BIN="$BATS_TEST_TMPDIR/stubbin"
  GH_STUB_STATE_DIRECTORY="$BATS_TEST_TMPDIR/gh"
  mkdir -p "$STUB_BIN" "$GH_STUB_STATE_DIRECTORY"
  # The fork query (`--json isCrossRepository`) answers from cross-repository
  # when a case writes one (`true`, `false`, or `fail` for a gh that cannot
  # answer), and otherwise `false` whenever the branch has a pull request,
  # mirroring gh's own "no pull requests found" when it has none.
  cat >"$STUB_BIN/gh" <<'EOF'
#!/bin/bash
stub_state_directory="${GH_STUB_DIRECTORY:?}"
printf '%s\n' "$*" >>"$stub_state_directory/calls.log"
case "$*" in
  *isCrossRepository*)
    if [ -f "$stub_state_directory/cross-repository" ]; then
      answer=$(cat "$stub_state_directory/cross-repository")
      [ "$answer" != fail ] || { echo "HTTP 502: Bad Gateway (https://api.github.com/graphql)" >&2; exit 1; }
      printf '%s\n' "$answer"
      exit 0
    fi
    [ -f "$stub_state_directory/branch.json" ] || { echo "no pull requests found for branch \"x\"" >&2; exit 1; }
    printf 'false\n'
    exit 0
    ;;
esac
if [ "${3-}" = "--json" ]; then
  [ -f "$stub_state_directory/branch.json" ] || { echo "no pull requests found" >&2; exit 1; }
  cat "$stub_state_directory/branch.json"
else
  [ -f "$stub_state_directory/pr-${3-}.json" ] || exit 1
  cat "$stub_state_directory/pr-${3-}.json"
fi
EOF
  chmod +x "$STUB_BIN/gh"
  CTR=0
}

# --- payloads and invocation --------------------------------------------------

# payload <member> <session> <prompt-root> <cwd> [extra-json]
payload() {
  local extra="${5-}"
  [ -n "$extra" ] || extra='{}'
  jq -n -c --arg member "$1" --arg session_id "$2" --arg root "$3" --arg cwd "$4" --argjson extra "$extra" \
    '{session_id: $session_id, hook_event_name: "PreToolUse", tool_name: "Agent", cwd: $cwd,
      tool_input: {subagent_type: $member, prompt: ("Audit the change. Working root: " + $root + ", base main")}} + $extra'
}

# run_payload <payload-json> [extra-path-dir]: run the hook in a fresh bash.
run_payload() {
  run env PATH="${2:+$2:}$STUB_BIN:$PATH" GH_STUB_DIRECTORY="$GH_STUB_STATE_DIRECTORY" \
    bash -c 'printf %s "$1" | "${GAIA_TEST_HOOK_BASH:-bash}" "$2"' _ "$1" "$HOOK"
}

# dispatch [member] [session] [root] [cwd]: a member dispatch at the fixture root.
dispatch() {
  run_payload "$(payload "${1:-$FRONTEND_MEMBER}" "${2:-$SID}" "${3:-$ALF_ROOT}" "${4:-$ALF_ROOT}")"
}

assert_allowed() {
  [ "$status" -eq 0 ] || { printf 'status %s: %s\n' "$status" "$output" >&2; return 1; }
  [ -z "$output" ] || { printf 'unexpected output: %s\n' "$output" >&2; return 1; }
}

assert_denied() {
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output"
}

# reason: the decoded deny reason of the last run.
reason() {
  jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output" ||
    { printf 'raw output: %s\n' "$output" >&2; return 1; }
}

# new_tree: commit one more change so HEAD presents a new tree.
new_tree() {
  CTR=$((CTR + 1))
  alf_set_line other.txt "$CTR" "tree $CTR"
  alf_commit "tree $CTR"
}

# state_field <jq-filter>: one read of the state file.
state_field() {
  jq -r "$1" "$ALF_STATE"
}

nrounds() {
  state_field '.history.rounds | length'
}

# build_path <dir> <omit>: a PATH directory holding the tools the hook needs, without <omit>.
build_path() {
  local path_directory="$1" omit="$2" tool tool_path
  mkdir -p "$path_directory"
  for tool in bash cat jq git gh date mktemp rm mv mkdir dirname sleep env tr find ls touch grep sed awk wc head tail sort uniq cut kill cmp pwd; do
    [ "$tool" != "$omit" ] || continue
    if [ "$tool" = gh ]; then tool_path="$STUB_BIN/gh"; else tool_path="$(command -v "$tool")" || continue; fi
    case "$tool_path" in /*) ln -sf "$tool_path" "$path_directory/$tool" ;; esac
  done
}

# scratch_hook <default-deadline>: a copy of the hook with its own default deadline.
scratch_hook() {
  local scratch_directory="$BATS_TEST_TMPDIR/scratch"
  mkdir -p "$scratch_directory/.claude/hooks"
  ln -sfn "$REPO_ROOT/.gaia" "$scratch_directory/.gaia"
  ln -sfn "$REPO_ROOT/.claude/hooks/lib" "$scratch_directory/.claude/hooks/lib"
  sed "s/^GAIA_AUDIT_LOOP_DEADLINE_DEFAULT=.*/GAIA_AUDIT_LOOP_DEADLINE_DEFAULT=$1/" "$HOOK" >"$scratch_directory/.claude/hooks/audit-loop-bound.sh"
  HOOK="$scratch_directory/.claude/hooks/audit-loop-bound.sh"
}

# linked_worktree <name> <branch>: a linked worktree on a new branch from main.
linked_worktree() {
  alf_git worktree add -q -b "$2" "$BATS_TEST_TMPDIR/$1" main || return 1
  WORKTREE_PATH="$(cd "$BATS_TEST_TMPDIR/$1" && pwd -P)"
}

# commit_in_worktree <line>: commit one change in the linked worktree $WORKTREE_PATH.
commit_in_worktree() {
  printf 'wt %s\n' "$1" >"$WORKTREE_PATH/wt.txt"
  git -C "$WORKTREE_PATH" add -A
  git -C "$WORKTREE_PATH" -c user.email=gaia-test@example.com -c user.name="GAIA Test" -c commit.gpgsign=false commit -q -m "wt $1"
}

# --- same-wave identity -------------------------------------------------------

@test "a dispatch from another session on a fifth tree is allowed and recorded" {
  alf_sequence 6 5 4 3
  [ "$(nrounds)" -eq 4 ]
  new_tree
  dispatch "$FRONTEND_MEMBER" session-b
  assert_allowed
  [ "$(nrounds)" -eq 5 ]
  [ "$(state_field '.history.rounds[4].tree')" = "$ALF_TREE" ]
  [ "$(state_field '.history.rounds | map(.tree) | unique | length')" -eq 5 ]
}

@test "the first dispatch on an absent state is round 1 with frozen defaults and a stamp" {
  dispatch
  assert_allowed
  [ "$(nrounds)" -eq 1 ]
  [ "$(state_field '.history.knobs.checkpoint_round')" -eq 6 ]
  [ "$(state_field '.history.knobs.grant_rounds')" -eq 3 ]
  [ "$(state_field '.history.rounds[0].members[0]')" = "$FRONTEND_MEMBER" ]
  [ "$(state_field '.history.rounds[0].raw_branch_slug')" = "$ALF_SLUG" ]
  [ -f "$ALF_ROOT/.gaia/local/audit-loop/feat/loop.d/round-1.stamp" ]
}

@test "a parallel member and a repeated member on the same tree join one round" {
  dispatch "$FRONTEND_MEMBER"
  assert_allowed
  dispatch code-audit-maintainer-shell session-b
  assert_allowed
  dispatch "$FRONTEND_MEMBER" session-c
  assert_allowed
  [ "$(nrounds)" -eq 1 ]
  [ "$(state_field '.history.rounds[0].members | sort | join(",")')" = "code-audit-frontend,code-audit-maintainer-shell" ]
}

# --- the allowance checkpoint -------------------------------------------------

@test "a sixth tree is denied with the checkpoint, the rounds run and both typed lines" {
  alf_sequence 6 5 4 3 2
  new_tree
  dispatch "$FRONTEND_MEMBER" session-b
  assert_denied
  denial_reason="$(reason)"
  printf '%s\n' "$denial_reason" | grep -qF -- "BLOCKED: audit checkpoint on branch feat/loop after 5 rounds (fallback)."
  printf '%s\n' "$denial_reason" | grep -qF -- "round 1: A=6 verdict=continue"
  printf '%s\n' "$denial_reason" | grep -qF -- "round 5: A=2 verdict=continue"
  printf '%s\n' "$denial_reason" | grep -qxF -- "Grant (type exactly as the whole prompt): $(gaia_loop_grant_line 3)"
  printf '%s\n' "$denial_reason" | grep -qxF -- "Accept (type exactly as the whole prompt): $(gaia_loop_accept_line)"
  printf '%s\n' "$denial_reason" | grep -qF -- "Interactive run: on the main thread of this session, ask this question with AskUserQuestion exactly as printed"
  printf '%s\n' "$denial_reason" | grep -qF -- "Unattended run (a /gaia-debt drain): never ask; stop, leave the PR open, print the typed grant line above, and print no continuation prompt."
  printf '%s\n' "$denial_reason" | grep -qF -- "or CI" && return 1
  printf '%s\n' "$denial_reason" | grep -qF -- "never types or simulates"
  printf '%s\n' "$denial_reason" | grep -qF -- "already-audited tree is still allowed"
  printf '%s\n' "$denial_reason" | grep -qF -- "State file: $ALF_STATE"
  [ "$(nrounds)" -eq 5 ]
}

@test "an already-audited tree stays allowed at the checkpoint, from another session and with an agent_id" {
  alf_sequence 6 5 4 3 2
  run_payload "$(payload "$FRONTEND_MEMBER" session-z "$ALF_ROOT" "$ALF_ROOT" '{"agent_id":"agent-9","agent_type":"code-audit-frontend"}')"
  assert_allowed
  dispatch code-audit-maintainer-node session-q
  assert_allowed
  [ "$(nrounds)" -eq 5 ]
  [ "$(state_field '.history.rounds[4].members | length')" -eq 2 ]
}

@test "a new session cannot reset a checkpoint: the deny repeats with a fresh pinned checkpoint and no round" {
  alf_sequence 6 5 4 3 2
  new_tree
  dispatch "$FRONTEND_MEMBER" session-b
  assert_denied
  dispatch "$FRONTEND_MEMBER" session-c
  assert_denied
  [ "$(state_field '[.history.checkpoints[] | select(.at_round == 5)] | length')" -eq 2 ]
  [ "$(state_field '.history.checkpoints[0].session_id')" = session-b ]
  [ "$(state_field '.history.checkpoints[1].session_id')" = session-c ]
  [ "$(state_field '.history.checkpoints[0].nonce')" != "$(state_field '.history.checkpoints[1].nonce')" ]
  [ "$(nrounds)" -eq 5 ]
}

# --- the evidence verdicts, through the hook ----------------------------------

# stalled_denied: the last-built sequence is stalled at round 3.
stalled_denied() {
  new_tree
  dispatch
  assert_denied
  reason | grep -qF -- "(rubric:stalled)"
  [ "$(state_field '.history.checkpoints[0].reason')" = rubric:stalled ]
  [ "$(state_field '.history.checkpoints[0].at_round')" -eq 3 ]
  [ "$(nrounds)" -eq 3 ]
}

next_allowed() {
  new_tree
  dispatch
  assert_allowed
  [ "$(state_field '.history.checkpoints | length')" -eq 0 ]
}

@test "stalled evidence denies at the next tree: [5,5,5]" {
  alf_sequence 5 5 5
  stalled_denied
}

@test "stalled evidence denies at the next tree: [5,6,7]" {
  alf_sequence 5 6 7
  stalled_denied
}

@test "falling evidence allows the next tree: [5,4,4]" {
  alf_sequence 5 4 4
  next_allowed
}

@test "falling evidence allows the next tree: [5,5,4]" {
  alf_sequence 5 5 4
  next_allowed
}

@test "short evidence allows the next tree: [5,5]" {
  alf_sequence 5 5
  next_allowed
}

@test "an accept answering a stalled checkpoint allows one closing round, then the fallback denies" {
  alf_sequence 5 5 5
  new_tree
  dispatch
  assert_denied
  alf_add_answer 1 accept
  dispatch
  assert_allowed
  [ "$(nrounds)" -eq 4 ]
  [ "$(state_field '.history.rounds[3].closing')" = true ]
  new_tree
  dispatch
  assert_denied
  reason | grep -qF -- "(fallback)"
  [ "$(nrounds)" -eq 4 ]
}

@test "a grant of 2 answering a round-5 checkpoint buys exactly two more trees" {
  alf_sequence 6 5 4 3 2
  alf_add_checkpoint 5 allowance
  alf_add_answer 1 grant 2
  new_tree
  dispatch
  assert_allowed
  new_tree
  dispatch
  assert_allowed
  [ "$(nrounds)" -eq 7 ]
  new_tree
  dispatch
  assert_denied
  [ "$(nrounds)" -eq 7 ]
  [ "$(state_field '.history.checkpoints | length')" -eq 2 ]
  [ "$(state_field '.history.checkpoints[1].at_round')" -eq 7 ]
}

@test "a partial-repair run (A = 6,5,4,3,2 with one persisting key) is never stopped" {
  alf_fill f.txt 12 feature
  local round_number=0 unresolved_count
  for unresolved_count in 6 5 4 3 2; do
    round_number=$((round_number + 1))
    alf_set_line other.txt "$round_number" "round $round_number"
    alf_commit "round $round_number"
    dispatch
    assert_allowed
    alf_stamp "$round_number" $((10 * round_number))
    alf_sidecar "$FRONTEND_MEMBER" "$(alf_entries f.txt 1 "$unresolved_count")" $((10 * round_number + 1))
  done
  [ "$(nrounds)" -eq 5 ]
  [ "$(state_field '.history.checkpoints | length')" -eq 0 ]
  [ "$(state_field '[.history.rounds[0:4][].snapshot.verdict] | unique | join(",")')" = continue ]
  [ "$(state_field '.history.rounds[3].snapshot.A')" -eq 3 ]
}

# --- the knobs ------------------------------------------------------------------

@test "knobs set at round 1 freeze the checkpoint at 2 and print audit-grant 1; a grant buys one more" {
  export GAIA_AUDIT_CHECKPOINT_ROUND=2 GAIA_AUDIT_GRANT_ROUNDS=1
  dispatch
  assert_allowed
  new_tree
  dispatch
  assert_allowed
  new_tree
  dispatch
  assert_denied
  reason | grep -qxF -- "Grant (type exactly as the whole prompt): audit-grant 1"
  [ "$(nrounds)" -eq 2 ]
  alf_add_answer 1 grant 1
  dispatch
  assert_allowed
  [ "$(nrounds)" -eq 3 ]
  new_tree
  dispatch
  assert_denied
  [ "$(nrounds)" -eq 3 ]
}

@test "with both knobs unset the checkpoint is at 6 and the grant line is audit-grant 3" {
  local i
  for i in 1 2 3 4 5 6; do
    new_tree
    dispatch
    assert_allowed
  done
  new_tree
  dispatch
  assert_denied
  reason | grep -qxF -- "Grant (type exactly as the whole prompt): audit-grant 3"
  [ "$(state_field '.history.knobs.checkpoint_round')" -eq 6 ]
}

@test "a raised knob never allows past the frozen checkpoint" {
  local i
  for i in 1 2 3 4 5 6; do
    new_tree
    dispatch
    assert_allowed
  done
  new_tree
  export GAIA_AUDIT_CHECKPOINT_ROUND=9
  dispatch
  assert_denied
  [ "$(nrounds)" -eq 6 ]
}

@test "a live knob lowers a branch at round 3 to 4: one more tree, then denied" {
  local i
  for i in 1 2 3; do
    new_tree
    dispatch
    assert_allowed
  done
  export GAIA_AUDIT_CHECKPOINT_ROUND=4
  new_tree
  dispatch
  assert_allowed
  new_tree
  dispatch
  assert_denied
  [ "$(nrounds)" -eq 4 ]
}

@test "malformed knob values never allow past the default" {
  local i knob_value
  for i in 1 2 3 4 5 6; do
    new_tree
    dispatch
    assert_allowed
  done
  new_tree
  for knob_value in 0 -1 abc ""; do
    export GAIA_AUDIT_CHECKPOINT_ROUND="$knob_value"
    dispatch
    assert_denied
  done
  [ "$(nrounds)" -eq 6 ]
}

# --- the pull request link ------------------------------------------------------

@test "a merged pull request's state moves to .closed and a reused branch name starts at round 1" {
  alf_sequence 6 5 4 3 2
  jq '.pr = 100' "$ALF_STATE" >"$ALF_STATE.t" && mv "$ALF_STATE.t" "$ALF_STATE"
  printf '{"number":200,"state":"OPEN"}\n' >"$GH_STUB_STATE_DIRECTORY/branch.json"
  printf '{"state":"MERGED"}\n' >"$GH_STUB_STATE_DIRECTORY/pr-100.json"
  new_tree
  dispatch
  assert_allowed
  [ "$(nrounds)" -eq 1 ]
  [ "$(state_field '.pr')" -eq 200 ]
  [ "$(find "$ALF_ROOT/.gaia/local/audit-loop/.closed" -name 'feat+loop.100.*.json' | wc -l | tr -d ' ')" -eq 1 ]
}

@test "a branch lookup that returns the linked pull request as MERGED closes the state" {
  alf_sequence 6 5 4 3 2
  jq '.pr = 100' "$ALF_STATE" >"$ALF_STATE.t" && mv "$ALF_STATE.t" "$ALF_STATE"
  printf '{"number":100,"state":"MERGED"}\n' >"$GH_STUB_STATE_DIRECTORY/branch.json"
  new_tree
  dispatch
  assert_allowed
  [ "$(nrounds)" -eq 1 ]
  [ "$(state_field '.pr')" = null ]
  [ "$(find "$ALF_ROOT/.gaia/local/audit-loop/.closed" -name '*.json' | wc -l | tr -d ' ')" -eq 1 ]
}

@test "a gh failure keeps the history and the allowance" {
  alf_sequence 6 5 4 3 2
  jq '.pr = 100' "$ALF_STATE" >"$ALF_STATE.t" && mv "$ALF_STATE.t" "$ALF_STATE"
  new_tree
  dispatch
  assert_denied
  [ "$(nrounds)" -eq 5 ]
  [ ! -d "$ALF_ROOT/.gaia/local/audit-loop/.closed" ]
}

@test "an open pull request is linked onto a state that has none" {
  new_tree
  printf '{"number":321,"state":"OPEN"}\n' >"$GH_STUB_STATE_DIRECTORY/branch.json"
  dispatch
  assert_allowed
  [ "$(state_field '.pr')" -eq 321 ]
}

@test "a renamed branch with the same open pull request carries history and allowance over" {
  alf_branch old/name
  alf_sequence 6 5 4
  jq '.pr = 77' "$ALF_STATE" >"$ALF_STATE.t" && mv "$ALF_STATE.t" "$ALF_STATE"
  old_state="$ALF_STATE"
  alf_git branch -m new/name
  ALF_NORMALIZED_BRANCH=new/name
  ALF_STATE="$ALF_ROOT/.gaia/local/audit-loop/new/name.json"
  printf '{"number":77,"state":"OPEN"}\n' >"$GH_STUB_STATE_DIRECTORY/branch.json"
  new_tree
  dispatch
  assert_allowed
  [ "$(nrounds)" -eq 4 ]
  [ "$(state_field '.branch')" = new/name ]
  [ "$(state_field '.key')" = branch:new/name ]
  [ "$(state_field '.history.rounds[0].raw_branch_slug')" != "$(gaia_key_slug new/name)" ]
  [ ! -e "$old_state" ]
  [ -f "$ALF_ROOT/.gaia/local/audit-loop/new/name.d/round-1.stamp" ]
}

@test "a detached HEAD is denied: it has no branch key" {
  alf_git checkout -q --detach
  dispatch
  assert_denied
  reason | grep -qF -- "no branch key"
  [ ! -e "$ALF_ROOT/.gaia/local/audit-loop/feat/loop.json" ]
}

# --- corrupt state and missing tools --------------------------------------------

@test "invalid JSON and schema 2 each deny naming the cause and the repair, and the file is never touched" {
  alf_sequence 6 5
  new_tree
  cp "$ALF_STATE" "$BATS_TEST_TMPDIR/orig"
  printf '{not json' >"$ALF_STATE"
  cp "$ALF_STATE" "$BATS_TEST_TMPDIR/bad1"
  dispatch
  assert_denied
  reason | grep -qF -- "invalid JSON"
  reason | grep -qF -- "mv '$ALF_STATE' '$ALF_STATE.corrupt-"
  cmp "$ALF_STATE" "$BATS_TEST_TMPDIR/bad1"
  jq '.schema = 2' "$BATS_TEST_TMPDIR/orig" >"$ALF_STATE"
  cp "$ALF_STATE" "$BATS_TEST_TMPDIR/bad2"
  dispatch
  assert_denied
  reason | grep -qF -- "schema 2"
  reason | grep -qF -- "outside Claude Code"
  cmp "$ALF_STATE" "$BATS_TEST_TMPDIR/bad2"
}

@test "corrupt state denies even a same-tree dispatch" {
  alf_sequence 6 5
  printf '{"schema":1}' >"$ALF_STATE"
  dispatch
  assert_denied
}

@test "a missing previous-round sidecar records unknown and is allowed below the allowance" {
  alf_sequence 6 5 4
  rm -f "$ALF_ROOT"/.gaia/local/audit/*.findings.json
  new_tree
  dispatch
  assert_allowed
  [ "$(state_field '.history.rounds[2].snapshot.verdict')" = unknown ]
  [ "$(state_field '.history.rounds[2].snapshot.A')" = null ]
  [ "$(nrounds)" -eq 4 ]
}

@test "a missing previous-round sidecar records unknown and is denied at the allowance" {
  alf_sequence 6 5 4 3 2
  rm -f "$ALF_ROOT"/.gaia/local/audit/*.findings.json
  new_tree
  dispatch
  assert_denied
  [ "$(state_field '.history.rounds[4].snapshot.verdict')" = unknown ]
  [ "$(state_field '.history.rounds[4].snapshot.A')" = null ]
}

@test "jq absent denies a member dispatch with exit 2 and allows a general-purpose dispatch" {
  build_path "$BATS_TEST_TMPDIR/nojq" jq
  run env PATH="$BATS_TEST_TMPDIR/nojq" bash -c 'printf %s "$1" | /bin/bash "$2"' _ "$(payload "$FRONTEND_MEMBER" "$SID" "$ALF_ROOT" "$ALF_ROOT")" "$HOOK"
  [ "$status" -eq 2 ]
  grep -qF -- BLOCKED <<<"$output"
  grep -qF -- jq <<<"$output"
  run env PATH="$BATS_TEST_TMPDIR/nojq" bash -c 'printf %s "$1" | /bin/bash "$2"' _ "$(payload general-purpose "$SID" "$ALF_ROOT" "$ALF_ROOT")" "$HOOK"
  assert_allowed
  [ ! -e "$ALF_ROOT/.gaia/local/audit-loop" ]
}

@test "git absent denies a member dispatch with a message naming git" {
  build_path "$BATS_TEST_TMPDIR/nogit" git
  run env PATH="$BATS_TEST_TMPDIR/nogit" bash -c 'printf %s "$1" | /bin/bash "$2"' _ "$(payload "$FRONTEND_MEMBER" "$SID" "$ALF_ROOT" "$ALF_ROOT")" "$HOOK"
  assert_denied
  reason | grep -qF -- "git is not on PATH"
  [ ! -e "$ALF_ROOT/.gaia/local/audit-loop/feat/loop.json" ]
}

# --- resolving the audited root --------------------------------------------------

@test "a worktree branch and a main checkout on one key accumulate rounds in one file" {
  alf_branch debt/42-fix
  linked_worktree wt1 worktree-debt+42-fix
  commit_in_worktree 1
  run_payload "$(payload "$FRONTEND_MEMBER" "$SID" "$WORKTREE_PATH" "$ALF_ROOT")"
  assert_allowed
  new_tree
  run_payload "$(payload "$FRONTEND_MEMBER" "$SID" "$ALF_ROOT" "$WORKTREE_PATH")"
  assert_allowed
  [ "$(nrounds)" -eq 2 ]
  [ ! -e "$ALF_ROOT/.gaia/local/audit-loop/worktree-debt+42-fix.json" ]
  [ "$(state_field '.history.rounds[0].raw_branch_slug')" != "$(state_field '.history.rounds[1].raw_branch_slug')" ]
}

@test "a cwd on main with a prompt naming a feature worktree records under the feature branch" {
  alf_git checkout -q main
  linked_worktree wt2 feat/from-wt
  ALF_NORMALIZED_BRANCH=feat/from-wt
  ALF_STATE="$ALF_ROOT/.gaia/local/audit-loop/feat/from-wt.json"
  commit_in_worktree 1
  run_payload "$(payload "$FRONTEND_MEMBER" "$SID" "$WORKTREE_PATH" "$ALF_ROOT")"
  assert_allowed
  [ -f "$ALF_STATE" ]
  [ "$(nrounds)" -eq 1 ]
  [ ! -e "$ALF_ROOT/.gaia/local/audit-loop/main.json" ]
}

@test "a prose Working root ending in a period records under the named worktree, not the cwd" {
  local payload_json
  alf_git checkout -q main
  linked_worktree wt3 feat/prose
  ALF_STATE="$ALF_ROOT/.gaia/local/audit-loop/feat/prose.json"
  commit_in_worktree 1
  payload_json="$(jq -n -c --arg member "$FRONTEND_MEMBER" --arg session_id "$SID" --arg root "$WORKTREE_PATH" --arg cwd "$ALF_ROOT" \
    '{session_id: $session_id, hook_event_name: "PreToolUse", tool_name: "Agent", cwd: $cwd,
      tool_input: {subagent_type: $member, prompt: ("Working root: " + $root + ". Audit the PR.")}}')"
  run_payload "$payload_json"
  assert_allowed
  [ -f "$ALF_STATE" ]
  [ "$(nrounds)" -eq 1 ]
  [ ! -e "$ALF_ROOT/.gaia/local/audit-loop/main.json" ]
}

@test "a named Working root that does not resolve is denied naming it and charges no round to the cwd" {
  local missing="$BATS_TEST_TMPDIR/no-such-checkout"
  alf_git checkout -q main
  run_payload "$(payload "$FRONTEND_MEMBER" "$SID" "$missing" "$ALF_ROOT")"
  assert_denied
  reason | grep -qF -- "Working root: $missing"
  [ ! -e "$ALF_ROOT/.gaia/local/audit-loop/main.json" ]
}

@test "colliding branch names a/b-c and a-b/c keep separate files" {
  alf_branch a/b-c
  new_tree
  dispatch
  assert_allowed
  first="$ALF_STATE"
  alf_branch a-b/c
  new_tree
  dispatch
  assert_allowed
  [ -f "$first" ]
  [ -f "$ALF_STATE" ]
  [ "$first" != "$ALF_STATE" ]
  [ "$(jq -r '.history.rounds | length' "$first")" -eq 1 ]
  [ "$(nrounds)" -eq 1 ]
}

@test "a denied dispatch from the main checkout records the session and the worktree it audited" {
  alf_git checkout -q main
  linked_worktree wt3 feat/denied-wt
  ALF_NORMALIZED_BRANCH=feat/denied-wt
  ALF_STATE="$ALF_ROOT/.gaia/local/audit-loop/$ALF_NORMALIZED_BRANCH.json"
  local fake_object_id
  fake_object_id="$(printf 'a%.0s' $(seq 1 39))"
  alf_seed_state "$(jq -n -c --arg fake_object_id "$fake_object_id" '{rounds: [range(1; 6) | {round: ., tree: ($fake_object_id + (. | tostring)), commit: ($fake_object_id + (. | tostring)),
    raw_branch_slug: "x", dispatched_at: "2026-01-01T00:00:00Z", members: ["code-audit-frontend"], closing: false, snapshot: null}]}')"
  commit_in_worktree 1
  run_payload "$(payload "$FRONTEND_MEMBER" session-main "$WORKTREE_PATH" "$ALF_ROOT")"
  assert_denied
  [ "$(state_field '.history.checkpoints[0].session_id')" = session-main ]
  [ "$(state_field '.history.checkpoints[0].audited_root')" = "$WORKTREE_PATH" ]
}

# --- uncommitted work -----------------------------------------------------------

@test "a new tree on a dirty checkout is denied: commit the round first" {
  alf_sequence 6 5
  new_tree
  printf 'edit\n' >>"$ALF_ROOT/base.txt"
  dispatch
  assert_denied
  reason | grep -qF -- "Commit the round first"
  [ "$(nrounds)" -eq 2 ]
  git -C "$ALF_ROOT" checkout -q -- base.txt
  printf 'staged\n' >"$ALF_ROOT/staged.txt"
  git -C "$ALF_ROOT" add staged.txt
  dispatch
  assert_denied
  git -C "$ALF_ROOT" reset -q staged.txt
  rm -f "$ALF_ROOT/staged.txt"
}

@test "untracked files do not block a new tree, and a dirty tree does not block the same tree" {
  alf_sequence 6 5
  new_tree
  printf 'x\n' >"$ALF_ROOT/untracked.txt"
  dispatch
  assert_allowed
  [ "$(nrounds)" -eq 3 ]
  printf 'edit\n' >>"$ALF_ROOT/base.txt"
  dispatch code-audit-maintainer-shell
  assert_allowed
  [ "$(nrounds)" -eq 3 ]
}

# --- the deadline ---------------------------------------------------------------

mk_slow_git() {
  SLOW="$BATS_TEST_TMPDIR/slowgit"
  mkdir -p "$SLOW"
  REAL_GIT="$(command -v git)"
  cat >"$SLOW/git" <<EOF
#!/bin/bash
for git_argument in "\$@"; do
  if [ "\$git_argument" = diff ]; then exec sleep 6.$$; fi
done
exec "$REAL_GIT" "\$@"
EOF
  chmod +x "$SLOW/git"
}

@test "a slow git past the deadline denies naming the deadline within about 2 seconds and leaves no child" {
  mk_slow_git
  new_tree
  export GAIA_AUDIT_LOOP_DEADLINE_SECONDS=1
  local start_seconds end_seconds
  start_seconds="$(date +%s)"
  run_payload "$(payload "$FRONTEND_MEMBER" "$SID" "$ALF_ROOT" "$ALF_ROOT")" "$SLOW"
  end_seconds="$(date +%s)"
  assert_denied
  reason | grep -qF -- "1s internal deadline"
  [ $((end_seconds - start_seconds)) -le 3 ]
  pgrep -f "sleep 6.$$" >/dev/null && return 1
  [ ! -e "$ALF_STATE" ]
  [ ! -e "$ALF_STATE.lock" ]
}

@test "a deadline override larger than the default is ignored and a smaller one is honoured" {
  mk_slow_git
  scratch_hook 4
  new_tree
  export GAIA_AUDIT_LOOP_DEADLINE_SECONDS=999
  run_payload "$(payload "$FRONTEND_MEMBER" "$SID" "$ALF_ROOT" "$ALF_ROOT")" "$SLOW"
  assert_denied
  reason | grep -qF -- "4s internal deadline"
  export GAIA_AUDIT_LOOP_DEADLINE_SECONDS=2
  run_payload "$(payload "$FRONTEND_MEMBER" "$SID" "$ALF_ROOT" "$ALF_ROOT")" "$SLOW"
  assert_denied
  reason | grep -qF -- "2s internal deadline"
  pgrep -f "sleep 6.$$" >/dev/null && return 1
  return 0
}

@test "the default deadline is declared as a top-level integer assignment" {
  grep -qE '^GAIA_AUDIT_LOOP_DEADLINE_DEFAULT=[0-9]+$' "$HOOK"
}

@test "a held state lock past the deadline denies and the holder's lock is untouched" {
  new_tree
  mkdir -p "$ALF_ROOT/.gaia/local/audit-loop/feat"
  mkdir "$ALF_STATE.lock"
  export GAIA_AUDIT_LOOP_DEADLINE_SECONDS=2
  dispatch
  assert_denied
  reason | grep -qF -- "state lock"
  [ -d "$ALF_STATE.lock" ]
  [ ! -e "$ALF_STATE" ]
}

# --- concurrency ----------------------------------------------------------------

@test "five members dispatched at once on one new tree produce one round holding all five" {
  new_tree
  local member i=0 payload_json
  payload_json="$(payload x "$SID" "$ALF_ROOT" "$ALF_ROOT")"
  for member in code-audit-frontend code-audit-github-workflows code-audit-maintainer-node code-audit-maintainer-shell code-audit-extra; do
    i=$((i + 1))
    (printf '%s' "$payload_json" | jq -c --arg member "$member" '.tool_input.subagent_type = $member' |
      env PATH="$STUB_BIN:$PATH" GH_STUB_DIRECTORY="$GH_STUB_STATE_DIRECTORY" bash "$HOOK" >"$BATS_TEST_TMPDIR/out.$i" 2>&1) &
  done
  wait
  for i in 1 2 3 4 5; do
    [ ! -s "$BATS_TEST_TMPDIR/out.$i" ] || { printf 'out.%s: %s\n' "$i" "$(cat "$BATS_TEST_TMPDIR/out.$i")" >&2; return 1; }
  done
  [ "$(nrounds)" -eq 1 ]
  [ "$(state_field '.history.rounds[0].members | length')" -eq 5 ]
}

@test "two checkouts of one key dispatching at once on different trees never lose a tree" {
  alf_branch feat/x
  linked_worktree wtc worktree-feat+x
  new_tree
  commit_in_worktree 1
  local main_payload worktree_payload
  main_payload="$(payload "$FRONTEND_MEMBER" s1 "$ALF_ROOT" "$ALF_ROOT")"
  worktree_payload="$(payload "$FRONTEND_MEMBER" s2 "$WORKTREE_PATH" "$WORKTREE_PATH")"
  (printf '%s' "$main_payload" | env PATH="$STUB_BIN:$PATH" GH_STUB_DIRECTORY="$GH_STUB_STATE_DIRECTORY" bash "$HOOK" >"$BATS_TEST_TMPDIR/o1" 2>&1) &
  (printf '%s' "$worktree_payload" | env PATH="$STUB_BIN:$PATH" GH_STUB_DIRECTORY="$GH_STUB_STATE_DIRECTORY" bash "$HOOK" >"$BATS_TEST_TMPDIR/o2" 2>&1) &
  wait
  [ ! -s "$BATS_TEST_TMPDIR/o1" ]
  [ ! -s "$BATS_TEST_TMPDIR/o2" ]
  [ "$(nrounds)" -eq 2 ]
  [ "$(state_field '.history.rounds | map(.tree) | unique | length')" -eq 2 ]
}

# --- scope ----------------------------------------------------------------------

@test "non-member dispatches exit 0 silently and create no state directory" {
  local subagent_type
  for subagent_type in general-purpose Explore code-reviewer; do
    run_payload "$(payload "$subagent_type" "$SID" "$ALF_ROOT" "$ALF_ROOT")"
    assert_allowed
  done
  run_payload "$(jq -n -c --arg cwd "$ALF_ROOT" '{session_id: "s", tool_name: "Agent", cwd: $cwd, tool_input: {prompt: "x"}}')"
  assert_allowed
  run_payload "$(payload "$FRONTEND_MEMBER" "$SID" "$ALF_ROOT" "$ALF_ROOT" | jq -c '.tool_name = "Bash"')"
  assert_allowed
  [ ! -e "$ALF_ROOT/.gaia/local/audit-loop" ]
}

@test "the Task tool name is bound like Agent" {
  run_payload "$(payload "$FRONTEND_MEMBER" "$SID" "$ALF_ROOT" "$ALF_ROOT" | jq -c '.tool_name = "Task"')"
  assert_allowed
  [ "$(nrounds)" -eq 1 ]
}

# --- fork pull requests ---------------------------------------------------------
#
# A dispatch that would record a round asks gh whether the audited checkout's
# pull request is a fork. The stub's answer comes from $GH_STUB_STATE_DIRECTORY/cross-repository
# (see setup). Each refusal is driven both ways: against the hook, and against
# a scratch mutant that lacks the arm, which must let the same case through.

# fork_mutant <perl-substitution>: point HOOK at a copy with one mutation.
fork_mutant() {
  local mutant_directory="$BATS_TEST_TMPDIR/fork-mutant"
  mkdir -p "$mutant_directory/.claude/hooks"
  ln -sfn "$REPO_ROOT/.gaia" "$mutant_directory/.gaia"
  ln -sfn "$REPO_ROOT/.claude/hooks/lib" "$mutant_directory/.claude/hooks/lib"
  perl -0pe "$1" "$HOOK" >"$mutant_directory/.claude/hooks/audit-loop-bound.sh"
  cmp -s "$HOOK" "$mutant_directory/.claude/hooks/audit-loop-bound.sh" && { printf 'mutation changed nothing: %s\n' "$1" >&2; return 1; }
  HOOK="$mutant_directory/.claude/hooks/audit-loop-bound.sh"
}

@test "UAT-010: a dispatch for a fork pull request is denied with the refusal and records no round" {
  local message
  printf '{"number":34,"state":"OPEN"}\n' >"$GH_STUB_STATE_DIRECTORY/branch.json"
  printf 'true\n' >"$GH_STUB_STATE_DIRECTORY/cross-repository"
  dispatch
  assert_denied
  message="$(bash -c '. "$1"; printf "%s" "$GAIA_CROSS_REPO_REFUSAL_MESSAGE"' _ "$REPO_ROOT/.claude/hooks/lib/cross-repo-refusal.sh")"
  reason | grep -qF -- "$message"
  grep -qxF -- 'pr view --json isCrossRepository --jq .isCrossRepository' "$GH_STUB_STATE_DIRECTORY/calls.log"
  [ ! -f "$ALF_STATE" ]
}

@test "UAT-010: the same dispatch for a same-repo pull request is allowed and records its round" {
  printf '{"number":34,"state":"OPEN"}\n' >"$GH_STUB_STATE_DIRECTORY/branch.json"
  printf 'false\n' >"$GH_STUB_STATE_DIRECTORY/cross-repository"
  dispatch
  assert_allowed
  [ "$(nrounds)" -eq 1 ]
}

@test "UAT-010: a dispatch is denied, naming the gh failure, when gh cannot say whether the pull request is a fork" {
  printf 'fail\n' >"$GH_STUB_STATE_DIRECTORY/cross-repository"
  dispatch
  assert_denied
  reason | grep -qF -- 'cannot tell whether the pull request'
  reason | grep -qF -- 'HTTP 502: Bad Gateway'
  reason | grep -qF -- 'push the branch to origin'
  [ ! -f "$ALF_STATE" ]
}

@test "UAT-010 mutation: without the refusal call the fork dispatch is allowed, so the denial test can fail" {
  fork_mutant 's/if fork_reason=\$\(gaia_cross_repo_deny_reason/if false && fork_reason=\$(gaia_cross_repo_deny_reason/'
  printf '{"number":34,"state":"OPEN"}\n' >"$GH_STUB_STATE_DIRECTORY/branch.json"
  printf 'true\n' >"$GH_STUB_STATE_DIRECTORY/cross-repository"
  dispatch
  assert_allowed
  [ "$(nrounds)" -eq 1 ]
}

@test "UAT-010 mutation: treating an unanswerable gh as allow lets the dispatch through, so the fail-closed test can fail" {
  fork_mutant 's/finish_deny "\$fork_reason"/case "\$fork_reason" in *"cannot tell"*) ;; *) finish_deny "\$fork_reason" ;; esac/'
  printf 'fail\n' >"$GH_STUB_STATE_DIRECTORY/cross-repository"
  dispatch
  assert_allowed
  [ "$(nrounds)" -eq 1 ]
}

# --- the unit gate ----------------------------------------------------------------
#
# K, the line defaults and the hard cap come from the libs the suite sources in
# setup (GAIA_CONTEXT_UNIT_ROUNDS, GAIA_CONTEXT_ASK_TOKENS_DEFAULT,
# GAIA_CONTEXT_ASK_WINDOW_PERCENT_DEFAULT, _GAIA_LOOP_HARD_CAP), never from literals.
# A context reading is keyed by a UUID session id; the plain ids the cases
# above use read as `missing`, which is the round-count fallback.

SIDU=0a1b2c3d-1111-4222-8333-444455556666
SIDV=0a1b2c3d-2222-4222-8333-444455556666
IN_UNIT='{"agent_id":"a0b1c2d3e4f5a6b7c","agent_type":"audit-loop-unit"}'

# write_context_reading <tokens> <window> [age-seconds] [session]: write that session's reading.
write_context_reading() {
  local token_count="$1" window_size="$2" age="${3:-0}" session_id="${4:-$SIDU}"
  gaia_context_write "$ALF_ROOT" "$session_id" "$((token_count * 100 / window_size))" "$token_count" "$window_size" "$(($(date +%s) - age))"
}

# below / above: a fresh 1M-window reading one token either side of the default line.
below() { write_context_reading $((GAIA_CONTEXT_ASK_TOKENS_DEFAULT - 1)) 1000000 0 "${1:-$SIDU}"; }
above() { write_context_reading "$GAIA_CONTEXT_ASK_TOKENS_DEFAULT" 1000000 0 "${1:-$SIDU}"; }

# unit_payload <session> [extra-json]: an audit-loop-unit dispatch whose brief
# carries the fixture root.
unit_payload() {
  local extra="${2-}"
  [ -n "$extra" ] || extra='{}'
  jq -n -c --arg session_id "$1" --arg root "$ALF_ROOT" --argjson extra "$extra" \
    '{session_id: $session_id, hook_event_name: "PreToolUse", tool_name: "Agent", cwd: $root,
      tool_input: {subagent_type: "audit-loop-unit",
        prompt: ("Run one audit unit.\nWorking root: " + $root + "\nUnit: 1\nStart round: 1")}} + $extra'
}

unit_dispatch() {
  run_payload "$(unit_payload "${1:-$SIDU}")"
}

# nested [member] [session]: a member dispatch made from inside a unit.
nested() {
  run_payload "$(payload "${1:-$FRONTEND_MEMBER}" "${2:-$SIDU}" "$ALF_ROOT" "$ALF_ROOT" "$IN_UNIT")"
}

# main_member [member] [session]: a member dispatch from the main thread.
main_member() {
  run_payload "$(payload "${1:-$FRONTEND_MEMBER}" "${2:-$SIDU}" "$ALF_ROOT" "$ALF_ROOT")"
}

minimum_of() {
  if [ "$1" -lt "$2" ]; then printf '%s\n' "$1"; else printf '%s\n' "$2"; fi
}

# seed_rounds <n> <last-snapshot-json>: n recorded rounds on stand-in trees with
# frozen default knobs; every earlier snapshot is a plain continue.
seed_rounds() {
  local object_id_prefix
  object_id_prefix="$(printf 'a%.0s' $(seq 1 37))"
  alf_seed_state "$(jq -n -c --arg object_id_prefix "$object_id_prefix" --argjson round_count "$1" --argjson last "$2" '{knobs: {checkpoint_round: 6, grant_rounds: 3},
    rounds: [range(1; $round_count + 1) | {round: ., tree: ($object_id_prefix + ((100 + .) | tostring)), commit: ($object_id_prefix + ((100 + .) | tostring)),
      raw_branch_slug: "x", dispatched_at: "2026-01-01T00:00:00Z", members: ["code-audit-frontend"], closing: false,
      snapshot: (if . == $round_count then $last else {verdict: "continue", A: 1} end)}]}')"
}

# sig_snap <signal> <eligible>: a stored snapshot holding exactly one signal.
sig_snap() {
  jq -n -c --arg signal "$1" --argjson accept_eligible "$2" \
    '{verdict: (if $signal == "quiet" or $signal == "enriching" or $signal == "stalled" then $signal else "continue" end),
      A: (if $signal == "quiet" then 0 else 1 end), counted_keys: [], raw_count: 1, waived_count: 0,
      signals: {($signal): true}, accept_eligible: $accept_eligible, accept_reasons: [$signal]}'
}

# assert_pinned <trigger>: the last run is a checkpoint deny; the latest
# checkpoint carries a nonce and a pinned question for <trigger>, and the deny
# prints that question verbatim with the asking instruction and the typed line.
assert_pinned() {
  local denial_reason pinned_question
  assert_denied
  denial_reason="$(reason)"
  case "$denial_reason" in "BLOCKED: audit checkpoint"*) ;; *) printf 'not a checkpoint deny: %s\n' "$denial_reason" >&2; return 1 ;; esac
  [ "$(state_field '.history.checkpoints | last | .trigger')" = "$1" ]
  [ "$(state_field '.history.checkpoints | last | .reason')" = "$1" ]
  [[ "$(state_field '.history.checkpoints | last | .nonce')" =~ ^[0-9a-f]{16}$ ]] || return 1
  [ "$(state_field '.history.checkpoints | last | .question.questions[0].options | length')" -ge 2 ]
  [ "$(state_field '[.history.checkpoints | last | .question.questions[0].options[].label | sub(" \\(Recommended\\)$"; "")] | index("Stop and file the remainder") != null')" = true ]
  pinned_question="$(state_field '.history.checkpoints | last | .question | tojson')"
  printf '%s\n' "$denial_reason" | grep -qxF -- "$pinned_question"
  printf '%s\n' "$denial_reason" | grep -qF -- AskUserQuestion
  printf '%s\n' "$denial_reason" | grep -qF -- audit-grant
}

# deny_prefix <prefix>: the last run denied with a reason starting <prefix>.
deny_prefix() {
  assert_denied
  case "$(reason)" in "$1"*) ;; *) printf 'want prefix %s, got: %s\n' "$1" "$(reason)" >&2; return 1 ;; esac
}

# scratch_copy: point HOOK at a copy of the hook whose scripts directory is a
# real copy of the files the hook loads, so a case can remove or stub one.
scratch_copy() {
  local scratch_directory="$BATS_TEST_TMPDIR/scratch-copy" script_name
  rm -rf "$scratch_directory"
  mkdir -p "$scratch_directory/.claude/hooks" "$scratch_directory/.gaia/scripts"
  for script_name in audit-loop-state-lib.sh branch-name-lib.sh main-root-lib.sh audit-key-lib.sh context-checkpoint-lib.sh \
    audit-loop-eval.sh audit-loop-signals-lib.sh audit-dispositions-check.sh; do
    cp "$REPO_ROOT/.gaia/scripts/$script_name" "$scratch_directory/.gaia/scripts/$script_name"
  done
  ln -sfn "$REPO_ROOT/.claude/hooks/lib" "$scratch_directory/.claude/hooks/lib"
  cp "$BOUND_HOOK" "$scratch_directory/.claude/hooks/audit-loop-bound.sh"
  HOOK="$scratch_directory/.claude/hooks/audit-loop-bound.sh"
  SCRATCH_SCRIPTS="$scratch_directory/.gaia/scripts"
}

# settings <ask_tokens> <ask_window_pct>: the machine-local line override.
settings() {
  mkdir -p "$ALF_ROOT/.gaia/local"
  jq -n -c --argjson ask_tokens "$1" --argjson ask_window_percent "$2" '{version: 1, context_checkpoint: {ask_tokens: $ask_tokens, ask_window_pct: $ask_window_percent}}' \
    >"$ALF_ROOT/.gaia/local/checkpoint-override.json"
}

@test "fast path: a general-purpose dispatch exits 0 silently without touching the context directory" {
  local context_directory
  context_directory="$(dirname "$(gaia_context_file "$ALF_ROOT" "$SIDU")")"
  mkdir -p "$context_directory"
  chmod 000 "$context_directory"
  run_payload "$(payload general-purpose "$SIDU" "$ALF_ROOT" "$ALF_ROOT")"
  chmod 755 "$context_directory"
  assert_allowed
  [ ! -e "$ALF_ROOT/.gaia/local/audit-loop" ]
}

@test "jq absent refuses a unit dispatch with exit 2 and allows a general-purpose one; without the unit literal the unit gets through" {
  build_path "$BATS_TEST_TMPDIR/nojq" jq
  run env PATH="$BATS_TEST_TMPDIR/nojq" bash -c 'printf %s "$1" | /bin/bash "$2"' _ "$(unit_payload "$SIDU")" "$HOOK"
  [ "$status" -eq 2 ]
  grep -qF -- BLOCKED <<<"$output"
  run env PATH="$BATS_TEST_TMPDIR/nojq" bash -c 'printf %s "$1" | /bin/bash "$2"' _ "$(payload general-purpose "$SIDU" "$ALF_ROOT" "$ALF_ROOT")" "$HOOK"
  assert_allowed
  fork_mutant "s/ 'code-audit-' 'audit-loop-unit'/ 'code-audit-'/"
  run env PATH="$BATS_TEST_TMPDIR/nojq" bash -c 'printf %s "$1" | /bin/bash "$2"' _ "$(unit_payload "$SIDU")" "$HOOK"
  assert_allowed
}

@test "the first unit on a fresh branch creates the state with knobs, line config and one unit, and no round" {
  printf '{"number":51,"state":"OPEN"}\n' >"$GH_STUB_STATE_DIRECTORY/branch.json"
  below
  unit_dispatch
  assert_allowed
  [ "$(nrounds)" -eq 0 ]
  [ "$(state_field '.pr')" -eq 51 ]
  [ "$(state_field '.history.knobs.checkpoint_round')" -eq 6 ]
  [ "$(state_field '.history.context_config.ask_tokens')" -eq "$GAIA_CONTEXT_ASK_TOKENS_DEFAULT" ]
  [ "$(state_field '.history.context_config.ask_window_pct')" -eq "$GAIA_CONTEXT_ASK_WINDOW_PERCENT_DEFAULT" ]
  [ "$(state_field '.history.units | length')" -eq 1 ]
  [ "$(state_field '.history.units[0].start_round')" -eq 1 ]
  [ "$(state_field '.history.units[0].through_round')" -eq "$GAIA_CONTEXT_UNIT_ROUNDS" ]
  [ "$(state_field '.history.units[0].admitted_on')" = context ]
  [ "$(state_field '.history.units[0].session_id')" = "$SIDU" ]
}

@test "the first unit on a dirty checkout is denied with the uncommitted-changes text and creates no state" {
  below
  printf 'edit\n' >>"$ALF_ROOT/base.txt"
  unit_dispatch
  assert_denied
  reason | grep -qF -- "Commit the round first"
  [ ! -e "$ALF_STATE" ]
}

@test "a unit after 6 rounds below the line gets a K-round window; its members open exactly those rounds, then the window denies" {
  local unit_rounds="$GAIA_CONTEXT_UNIT_ROUNDS" through round_number
  through="$(minimum_of $((6 + unit_rounds)) "$_GAIA_LOOP_HARD_CAP")"
  alf_sequence 6 5 4 3 2 1
  alf_state_edit '.history.knobs.checkpoint_round = 6'
  below
  unit_dispatch
  assert_allowed
  [ "$(state_field '.history.units[-1] | [.start_round, .k, .through_round, .admitted_on] | map(tostring) | join(" ")')" = "7 $unit_rounds $through context" ]
  [ "$(state_field '.history.checkpoints | length')" -eq 0 ]
  round_number=7
  while [ "$round_number" -le "$through" ]; do
    new_tree
    nested
    assert_allowed
    [ "$(nrounds)" -eq "$round_number" ]
    round_number=$((round_number + 1))
  done
  new_tree
  nested
  if [ "$through" -lt "$_GAIA_LOOP_HARD_CAP" ]; then
    deny_prefix "BLOCKED: audit window"
    reason | grep -qF -- "rounds 7 through $through"
    reason | grep -qF -- "window-end"
    [ "$(state_field '.history.checkpoints | length')" -eq 0 ]
  else
    assert_pinned cap
  fi
  [ "$(nrounds)" -eq "$through" ]
}

@test "red state: deciding the in-unit member by the round-count allowance denies the round-7 dispatch" {
  fork_mutant 's/decision=\$\(gaia_loop_decide_member "\$view" "\$snapshot" "\$in_unit" "\$reading" "\$ask_tokens" "\$ask_percent"\)/decision=\$(gaia_loop_decide "\$WORKING_STATE" "\$snapshot")/'
  alf_sequence 6 5 4 3 2 1
  alf_state_edit '.history.knobs.checkpoint_round = 6'
  below
  unit_dispatch
  assert_allowed
  new_tree
  nested
  assert_denied
  [ "$(nrounds)" -eq 6 ]
}

@test "a reading at the line denies the unit with a pinned context checkpoint and the unattended rule" {
  local nonce elig want
  alf_sequence 6 5
  above
  unit_dispatch
  assert_pinned context
  nonce="$(state_field '.history.checkpoints[-1].nonce')"
  elig="$(state_field '.history.rounds[1].snapshot.accept_eligible // false')"
  want="$(gaia_loop_pinned_question feat/loop "$nonce" 2 "$GAIA_CONTEXT_UNIT_ROUNDS" "$elig" false context "fresh $GAIA_CONTEXT_ASK_TOKENS_DEFAULT 1000000" grant "$(gaia_context_line 1000000 "$GAIA_CONTEXT_ASK_TOKENS_DEFAULT" "$GAIA_CONTEXT_ASK_WINDOW_PERCENT_DEFAULT")")"
  [ "$(state_field '.history.checkpoints[-1].question | tojson')" = "$want" ]
  [[ "$(state_field '.history.checkpoints[-1].question.questions[0].question')" == *"(context), context "[0-9]*"% ("[0-9]*"k of 1000k). How should"* ]]
  [ "$(state_field '.history.checkpoints[-1].at_round')" -eq 2 ]
  reason | grep -qF -- "never ask; stop, leave the PR open, print the typed grant line above, and print no continuation prompt"
  [ "$(state_field '.history.units // [] | length')" -eq 0 ]
}

@test "missing, stale, future-dated and garbage readings fall back to the round count: allowed at 5 used, denied at 6" {
  local mode reading_file
  reading_file="$(gaia_context_file "$ALF_ROOT" "$SIDU")"
  for mode in missing stale future garbage; do
    rm -f "$reading_file" "$ALF_STATE"
    rm -rf "${ALF_STATE%.json}.d"
    seed_rounds 5 '{"verdict":"continue","A":1}'
    case "$mode" in
      missing) ;;
      stale) write_context_reading 1000 1000000 $((GAIA_CONTEXT_FRESH_SECONDS + 60)) ;;
      future) write_context_reading 1000 1000000 -3600 ;;
      garbage) mkdir -p "${reading_file%/*}" && printf '{garbage' >"$reading_file" ;;
    esac
    unit_dispatch
    assert_allowed
    [ "$(state_field '.history.units[-1] | [.admitted_on, .start_round, .through_round] | map(tostring) | join(" ")')" = "fallback 6 6" ]
    seed_rounds 6 '{"verdict":"continue","A":1}'
    unit_dispatch
    assert_pinned fallback
  done
}

@test "below the line each denying signal denies the unit and quiet alone does not; the cap pins accept or type-accept with stop" {
  local signal
  below
  for signal in enriching stalled nitpicky reintroduced small-tail waiver-drift; do
    seed_rounds 6 "$(sig_snap "$signal" true)"
    unit_dispatch
    assert_pinned "rubric:$signal"
  done
  seed_rounds 6 "$(sig_snap quiet true)"
  unit_dispatch
  assert_allowed
  seed_rounds "$_GAIA_LOOP_HARD_CAP" "$(sig_snap cap true)"
  unit_dispatch
  assert_pinned cap
  [ "$(state_field '[.history.checkpoints[-1].question.questions[0].options[].label] | join("|")')" = "Accept the remainder (Recommended)|Stop and file the remainder" ]
  seed_rounds "$_GAIA_LOOP_HARD_CAP" "$(sig_snap cap false)"
  unit_dispatch
  assert_pinned cap
  [ "$(state_field '[.history.checkpoints[-1].question.questions[0].options[].label] | join("|")')" = "Stop and file the remainder (Recommended)|Type audit-accept instead" ]
}

# first_pinned_label: the leading option of the latest checkpoint's pinned question.
first_pinned_label() { state_field '.history.checkpoints | last | .question.questions[0].options[0].label'; }

@test "the pinned question leads with the evaluator's recommendation, and the band picks the grant when it is a grant" {
  local unit_rounds="$GAIA_CONTEXT_UNIT_ROUNDS"
  below
  seed_rounds 6 "$(sig_snap nitpicky true)"
  unit_dispatch
  assert_pinned rubric:nitpicky
  [ "$(first_pinned_label)" = "Continue audit in this session (Recommended)" ]
  [[ "$(state_field '.history.checkpoints | last | .question.questions[0].options[0].description')" == "Context "*" is below the checkpoint line, so this session has room: "* ]]
  seed_rounds 6 "$(sig_snap enriching true)"
  unit_dispatch
  assert_pinned rubric:enriching
  [ "$(first_pinned_label)" = "Accept the remainder (Recommended)" ]
  above
  seed_rounds 6 "$(sig_snap quiet true)"
  unit_dispatch
  assert_pinned context
  [ "$(first_pinned_label)" = "Continue audit in a new session (Recommended)" ]
  [[ "$(state_field '.history.checkpoints | last | .question.questions[0].options[0].description')" == "Context "*" is at or above the checkpoint line: "* ]]
}

@test "an ask grant admits one K-round unit over the line; the next unit asks again; a new session below the line continues" {
  local unit_rounds="$GAIA_CONTEXT_UNIT_ROUNDS" checkpoint_index nonce
  alf_sequence 6 5
  above
  unit_dispatch
  assert_pinned context
  checkpoint_index="$(state_field '.history.checkpoints[-1].index')"
  nonce="$(state_field '.history.checkpoints[-1].nonce')"
  alf_state_edit '.allowance.answers += [{checkpoint: $checkpoint_index, kind: "grant", n: $unit_rounds, source: "ask", option: "Continue audit in this session",
    nonce: $nonce, at: "2026-01-01T00:00:00Z", session_id: $session_id}]' --argjson checkpoint_index "$checkpoint_index" --argjson unit_rounds "$unit_rounds" --arg nonce "$nonce" --arg session_id "$SIDU"
  unit_dispatch
  assert_allowed
  [ "$(state_field '.history.units[-1] | [.admitted_on, .start_round, .through_round, .after_checkpoint] | map(tostring) | join(" ")')" = "grant 3 $(minimum_of $((2 + unit_rounds)) "$_GAIA_LOOP_HARD_CAP") $checkpoint_index" ]
  unit_dispatch
  assert_pinned context
  [ "$(state_field '.history.checkpoints[-1].nonce')" != "$nonce" ]
  below "$SIDV"
  unit_dispatch "$SIDV"
  assert_allowed
  [ "$(state_field '.history.units[-1].admitted_on')" = context ]
  [ "$(state_field '.history.units[-1].session_id')" = "$SIDV" ]
}

@test "a pending checkpoint with no answer denies the next unit again with a new nonce" {
  local first
  alf_sequence 6 5
  above
  unit_dispatch
  assert_pinned context
  first="$(state_field '.history.checkpoints[-1].nonce')"
  unit_dispatch
  assert_pinned context
  [ "$(state_field '.history.checkpoints | length')" -eq 2 ]
  [ "$(state_field '.history.checkpoints[-1].nonce')" != "$first" ]
}

@test "a legacy pending checkpoint without a nonce is superseded by a pinned one" {
  alf_sequence 6 5
  alf_add_checkpoint 2 allowance
  above
  unit_dispatch
  assert_pinned context
  [ "$(state_field '.history.checkpoints | length')" -eq 2 ]
  [ "$(state_field '.history.checkpoints[0].nonce // "none"')" = none ]
}

@test "a failing zero-fix dispositions file denies the same-tree re-dispatch and the next unit, recording nothing" {
  alf_sequence 6 5
  alf_dispositions 2 '[{"member":"code-audit-frontend","finding_class":"rule/x","path":"f.txt","line":1,"disposition":"accept-residual","reason":"later"}]'
  cp "$ALF_STATE" "$BATS_TEST_TMPDIR/before"
  below
  dispatch
  deny_prefix "BLOCKED: audit dispositions"
  reason | grep -qF -- "violation: security-not-fix"
  cmp "$ALF_STATE" "$BATS_TEST_TMPDIR/before"
  unit_dispatch
  deny_prefix "BLOCKED: audit dispositions"
  reason | grep -qF -- "violation: security-not-fix"
  cmp "$ALF_STATE" "$BATS_TEST_TMPDIR/before"
}

@test "red state: without the dispositions check the failing zero-fix re-dispatch joins its round" {
  fork_mutant 's/^  check_dispositions\n//m'
  alf_sequence 6 5
  alf_dispositions 2 '[{"member":"code-audit-frontend","finding_class":"rule/x","path":"f.txt","line":1,"disposition":"accept-residual","reason":"later"}]'
  dispatch
  assert_allowed
  [ "$(nrounds)" -eq 2 ]
}

# veto_rounds: round 1 reports finding X (security false) and disposes it
# accept-residual; round 2 is recorded by a member dispatch, which snapshots
# round 1's dispositions.
FINDING_X='{"member":"code-audit-frontend","finding_class":"rule/x","path":"f.txt","line":1}'
veto_rounds() {
  alf_fill f.txt 12 feature
  alf_commit "round 1"
  dispatch
  assert_allowed
  alf_stamp 1 10
  alf_sidecar "$FRONTEND_MEMBER" '[{"path":"f.txt","line":1,"security":false}]' 11
  alf_dispositions 1 "[$(jq -c '. + {disposition: "accept-residual", reason: "minor"}' <<<"$FINDING_X")]"
  new_tree
  dispatch
  assert_allowed
  [ "$(nrounds)" -eq 2 ]
  [ -f "${ALF_STATE%.json}.d/dispositions-1.checked.json" ]
  alf_stamp 2 20
}

@test "a veto effective from round 2 lets the next unit through, then binds round 2's disposition of the finding" {
  veto_rounds
  alf_sidecar "$FRONTEND_MEMBER" '[{"path":"f.txt","line":1,"security":false}]' 21
  jq -n -c --argjson finding "$FINDING_X" '{version: 1, keys: [$finding + {vetoed_at: "2026-01-01T00:00:00Z", unit: 1, effective_from_round: 2}]}' \
    >"$ALF_ROOT/.gaia/local/runs/$ALF_NORMALIZED_BRANCH/vetoes.json"
  below
  unit_dispatch
  assert_allowed
  alf_dispositions 2 "[$(jq -c '. + {disposition: "accept-residual", reason: "minor"}' <<<"$FINDING_X")]"
  unit_dispatch
  deny_prefix "BLOCKED: audit dispositions"
  reason | grep -qF -- "violation: vetoed-not-fix"
  alf_dispositions 2 "[$(jq -c '. + {disposition: "fix"}' <<<"$FINDING_X")]"
  unit_dispatch
  assert_allowed
}

@test "a dispositions snapshot outlives the overwritten sidecar; without it the same dispatch denies unknown-key" {
  veto_rounds
  alf_sidecar "$FRONTEND_MEMBER" '[{"path":"f.txt","line":2,"security":false}]' 21
  below
  unit_dispatch
  assert_allowed
  rm -f "${ALF_STATE%.json}.d"/dispositions-*.checked.json
  unit_dispatch
  deny_prefix "BLOCKED: audit dispositions"
  reason | grep -qF -- "violation: unknown-key"
}

@test "a main-thread member with no unit is judged as a one-round unit: over the line it pins, below it records and adds no unit" {
  alf_sequence 6 5
  new_tree
  above
  main_member
  assert_pinned context
  [ "$(nrounds)" -eq 2 ]
  below
  main_member
  assert_allowed
  [ "$(nrounds)" -eq 3 ]
  [ "$(state_field '.history.units // [] | length')" -eq 0 ]
}

@test "a window left by a unit that returned nesting-unavailable does not cover a main-thread or non-unit member over the line" {
  alf_sequence 6 5
  alf_state_edit '.history.units = [{unit: 1, start_round: 3, k: 3, through_round: 5, admitted_on: "context",
    after_checkpoint: 0, recorded_at: "2026-01-01T00:00:00Z", session_id: $session_id}]' --arg session_id "$SIDU"
  mkdir -p "$ALF_ROOT/.gaia/local/runs/$ALF_NORMALIZED_BRANCH"
  printf '{"version":1,"unit":1,"start_round":3,"through_round":5,"k":3,"rounds":[{"round":3,"opened":false,"reason":"nesting-unavailable"}],"stop_reason":"nesting-unavailable"}\n' \
    >"$ALF_ROOT/.gaia/local/runs/$ALF_NORMALIZED_BRANCH/unit-1.json"
  new_tree
  above
  main_member
  assert_pinned context
  run_payload "$(payload "$FRONTEND_MEMBER" "$SIDU" "$ALF_ROOT" "$ALF_ROOT" '{"agent_id":"a0b1c2d3e4f5a6b7c","agent_type":"general-purpose"}')"
  assert_pinned context
  [ "$(nrounds)" -eq 2 ]
  nested
  assert_allowed
  [ "$(nrounds)" -eq 3 ]
}

@test "the line config: a raise never applies, a lowering applies live, the window percent caps it, a frozen lowering survives removal" {
  below
  unit_dispatch
  assert_allowed
  settings 600000 50
  write_context_reading 350000 1000000
  unit_dispatch
  assert_pinned context
  settings 250000 50
  write_context_reading 260000 1000000
  unit_dispatch
  assert_pinned context
  write_context_reading 240000 1000000
  unit_dispatch
  assert_allowed
  rm -f "$ALF_ROOT/.gaia/local/checkpoint-override.json"
  write_context_reading 120000 200000
  unit_dispatch
  assert_pinned context
  alf_state_edit '.history.context_config = {ask_tokens: 250000, ask_window_pct: 50}'
  write_context_reading 260000 1000000
  unit_dispatch
  assert_pinned context
  write_context_reading 240000 1000000
  unit_dispatch
  assert_allowed
}

@test "an override present before the first unit freezes only the default, raised or malformed, and the hook denies at the default line" {
  local pair
  # A token count of 150 is a valid lowering, so 150 is a percent fixture only.
  for pair in "1000000 100" "0 0" "-1 -1" "1.5 1.5" "1000000 150"; do
    rm -f "$ALF_STATE"
    rm -rf "${ALF_STATE%.json}.d"
    # shellcheck disable=SC2086 # the pair is two words on purpose
    settings $pair
    below
    unit_dispatch
    assert_allowed
    [ "$(state_field '.history.context_config | "\(.ask_tokens) \(.ask_window_pct)"')" = "$GAIA_CONTEXT_ASK_TOKENS_DEFAULT $GAIA_CONTEXT_ASK_WINDOW_PERCENT_DEFAULT" ]
    above
    unit_dispatch
    assert_pinned context
  done
}

@test "at the round cap a unit is denied with trigger cap and a nested member for the next round is denied" {
  seed_rounds "$_GAIA_LOOP_HARD_CAP" '{"verdict":"continue","A":1}'
  alf_state_edit '.history.units = [{unit: 1, start_round: 8, k: 3, through_round: 10, admitted_on: "context",
    after_checkpoint: 0, recorded_at: "2026-01-01T00:00:00Z", session_id: $session_id}]' --arg session_id "$SIDU"
  below
  unit_dispatch
  assert_pinned cap
  new_tree
  nested
  assert_pinned cap
  [ "$(nrounds)" -eq "$_GAIA_LOOP_HARD_CAP" ]
}

@test "deny classes: each gate deny carries its prefix and no fail-loud deny borrows one" {
  local denial_reasons
  alf_sequence 6 5
  above
  unit_dispatch
  deny_prefix "BLOCKED: audit checkpoint"
  new_tree
  nested
  deny_prefix "BLOCKED: audit window"
  alf_dispositions 2 '[{"member":"code-audit-frontend","finding_class":"rule/x","path":"f.txt","line":1,"disposition":"file","reason":""}]'
  unit_dispatch
  deny_prefix "BLOCKED: audit dispositions"
  rm -f "$ALF_ROOT/.gaia/local/runs/$ALF_NORMALIZED_BRANCH/dispositions-2.json"
  printf 'edit\n' >>"$ALF_ROOT/base.txt"
  dispatch
  denial_reasons="$(reason)"
  git -C "$ALF_ROOT" checkout -q -- base.txt
  cp "$ALF_STATE" "$BATS_TEST_TMPDIR/good"
  printf '{not json' >"$ALF_STATE"
  dispatch
  denial_reasons="$denial_reasons"$'\n'"$(reason)"
  cp "$BATS_TEST_TMPDIR/good" "$ALF_STATE"
  mk_slow_git
  GAIA_AUDIT_LOOP_DEADLINE_SECONDS=1 run_payload "$(payload "$FRONTEND_MEMBER" "$SID" "$ALF_ROOT" "$ALF_ROOT")" "$SLOW"
  denial_reasons="$denial_reasons"$'\n'"$(reason)"
  scratch_copy
  rm -f "$SCRATCH_SCRIPTS/context-checkpoint-lib.sh"
  dispatch
  denial_reasons="$denial_reasons"$'\n'"$(reason)"
  [ "$(printf '%s\n' "$denial_reasons" | grep -c '^BLOCKED: ')" -eq 4 ]
  printf '%s\n' "$denial_reasons" | grep -qE '^BLOCKED: audit (checkpoint|window|dispositions)' && return 1
  printf '%s\n' "$denial_reasons" | grep -qF -- "Commit the round first"
  printf '%s\n' "$denial_reasons" | grep -qF -- "invalid JSON"
  printf '%s\n' "$denial_reasons" | grep -qF -- "internal deadline"
  printf '%s\n' "$denial_reasons" | grep -qF -- "cannot load its libraries"
}

@test "fail closed: a missing context lib, a missing or exit-3 dispositions check, and an unparseable vetoes.json each deny" {
  alf_sequence 6 5
  below
  scratch_copy
  rm -f "$SCRATCH_SCRIPTS/context-checkpoint-lib.sh"
  unit_dispatch
  assert_denied
  reason | grep -qF -- "cannot load its libraries"
  scratch_copy
  rm -f "$SCRATCH_SCRIPTS/audit-dispositions-check.sh"
  unit_dispatch
  assert_denied
  reason | grep -qF -- "cannot load its libraries"
  scratch_copy
  printf '#!/usr/bin/env bash\nexit 3\n' >"$SCRATCH_SCRIPTS/audit-dispositions-check.sh"
  unit_dispatch
  deny_prefix "BLOCKED: audit dispositions"
  reason | grep -qF -- "(exit 3)"
  HOOK="$BOUND_HOOK"
  mkdir -p "$ALF_ROOT/.gaia/local/runs/$ALF_NORMALIZED_BRANCH"
  printf '{broken' >"$ALF_ROOT/.gaia/local/runs/$ALF_NORMALIZED_BRANCH/vetoes.json"
  unit_dispatch
  deny_prefix "BLOCKED: audit dispositions"
  reason | grep -qF -- "vetoes.json"
}

@test "red state: without the spent-answer view, a main-thread grant of 2 keeps buying trees" {
  fork_mutant 's/view=\$\(answer_view "\$WORKING_STATE"\)/view="\$WORKING_STATE"/'
  alf_sequence 6 5 4 3 2
  alf_add_checkpoint 5 allowance
  alf_add_answer 1 grant 2
  new_tree
  dispatch
  assert_allowed
  new_tree
  dispatch
  assert_allowed
  new_tree
  dispatch
  assert_allowed
  [ "$(nrounds)" -eq 8 ]
}

@test "a unit dispatch over 9 rounds with 9 snapshotted dispositions files decides within 5 seconds" {
  local round_number start_milliseconds end_milliseconds i
  alf_sequence 6 5 4 3 2 2 1 1 1
  # With no baselines every round reads the newest sidecar, which reports only
  # f.txt:1, and the dispositions check requires that finding disposed.
  for round_number in 1 2 3 4 5 6 7 8 9; do
    alf_dispositions "$round_number" "$(alf_entries f.txt 1 1 | jq -c 'map(. + {member: "code-audit-frontend", disposition: "fix", reason: ""})')"
  done
  bash "$REPO_ROOT/.gaia/scripts/audit-dispositions-check.sh" check-all --root "$ALF_ROOT" \
    --run-folder "$ALF_ROOT/.gaia/local/runs/$ALF_NORMALIZED_BRANCH" --snapshot-dir "${ALF_STATE%.json}.d"
  [ "$(find "${ALF_STATE%.json}.d" -name 'dispositions-*.checked.json' | wc -l | tr -d ' ')" -eq 9 ]
  below
  for i in 1 2 3 4 5; do
    start_milliseconds="$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')"
    unit_dispatch
    end_milliseconds="$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')"
    [ "$status" -eq 0 ]
    printf '# run %s: %s ms\n' "$i" $((end_milliseconds - start_milliseconds)) >&3
    [ $((end_milliseconds - start_milliseconds)) -lt 5000 ]
  done
}
