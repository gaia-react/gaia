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
  unset GAIA_AUDIT_CHECKPOINT_ROUND GAIA_AUDIT_GRANT_ROUNDS GAIA_AUDIT_LOOP_DEADLINE_SECONDS
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/scripts/audit-loop-eval.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/audit-loop-fixture.sh"
  alf_init
  alf_branch feat/loop
  M=code-audit-frontend
  SID=sess-a
  STUB_BIN="$BATS_TEST_TMPDIR/stubbin"
  GH_DIR="$BATS_TEST_TMPDIR/gh"
  mkdir -p "$STUB_BIN" "$GH_DIR"
  # The fork query (`--json isCrossRepository`) answers from cross-repository
  # when a case writes one (`true`, `false`, or `fail` for a gh that cannot
  # answer), and otherwise `false` whenever the branch has a pull request,
  # mirroring gh's own "no pull requests found" when it has none.
  cat >"$STUB_BIN/gh" <<'EOF'
#!/bin/bash
d="${GH_STUB_DIR:?}"
printf '%s\n' "$*" >>"$d/calls.log"
case "$*" in
  *isCrossRepository*)
    if [ -f "$d/cross-repository" ]; then
      answer=$(cat "$d/cross-repository")
      [ "$answer" != fail ] || { echo "HTTP 502: Bad Gateway (https://api.github.com/graphql)" >&2; exit 1; }
      printf '%s\n' "$answer"
      exit 0
    fi
    [ -f "$d/branch.json" ] || { echo "no pull requests found for branch \"x\"" >&2; exit 1; }
    printf 'false\n'
    exit 0
    ;;
esac
if [ "${3-}" = "--json" ]; then
  [ -f "$d/branch.json" ] || { echo "no pull requests found" >&2; exit 1; }
  cat "$d/branch.json"
else
  [ -f "$d/pr-${3-}.json" ] || exit 1
  cat "$d/pr-${3-}.json"
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
  jq -n -c --arg m "$1" --arg s "$2" --arg root "$3" --arg cwd "$4" --argjson x "$extra" \
    '{session_id: $s, hook_event_name: "PreToolUse", tool_name: "Agent", cwd: $cwd,
      tool_input: {subagent_type: $m, prompt: ("Audit the change. Working root: " + $root + ", base main")}} + $x'
}

# run_payload <payload-json> [extra-path-dir]: run the hook in a fresh bash.
run_payload() {
  run env PATH="${2:+$2:}$STUB_BIN:$PATH" GH_STUB_DIR="$GH_DIR" \
    bash -c 'printf %s "$1" | "${GAIA_TEST_HOOK_BASH:-bash}" "$2"' _ "$1" "$HOOK"
}

# dispatch [member] [session] [root] [cwd]: a member dispatch at the fixture root.
dispatch() {
  run_payload "$(payload "${1:-$M}" "${2:-$SID}" "${3:-$ALF_ROOT}" "${4:-$ALF_ROOT}")"
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

# sj <jq-filter>: one read of the state file.
sj() {
  jq -r "$1" "$ALF_STATE"
}

nrounds() {
  sj '.history.rounds | length'
}

# build_path <dir> <omit>: a PATH directory holding the tools the hook needs, without <omit>.
build_path() {
  local d="$1" omit="$2" t p
  mkdir -p "$d"
  for t in bash cat jq git gh date mktemp rm mv mkdir dirname sleep env tr find ls touch grep sed awk wc head tail sort uniq cut kill cmp pwd; do
    [ "$t" != "$omit" ] || continue
    if [ "$t" = gh ]; then p="$STUB_BIN/gh"; else p="$(command -v "$t")" || continue; fi
    case "$p" in /*) ln -sf "$p" "$d/$t" ;; esac
  done
}

# scratch_hook <default-deadline>: a copy of the hook with its own default deadline.
scratch_hook() {
  local d="$BATS_TEST_TMPDIR/scratch"
  mkdir -p "$d/.claude/hooks"
  ln -sfn "$REPO_ROOT/.gaia" "$d/.gaia"
  ln -sfn "$REPO_ROOT/.claude/hooks/lib" "$d/.claude/hooks/lib"
  sed "s/^GAIA_AUDIT_LOOP_DEADLINE_DEFAULT=.*/GAIA_AUDIT_LOOP_DEADLINE_DEFAULT=$1/" "$HOOK" >"$d/.claude/hooks/audit-loop-bound.sh"
  HOOK="$d/.claude/hooks/audit-loop-bound.sh"
}

# linked_worktree <name> <branch>: a linked worktree on a new branch from main.
linked_worktree() {
  alf_git worktree add -q -b "$2" "$BATS_TEST_TMPDIR/$1" main || return 1
  WT="$(cd "$BATS_TEST_TMPDIR/$1" && pwd -P)"
}

# wt_commit <line>: commit one change in the linked worktree $WT.
wt_commit() {
  printf 'wt %s\n' "$1" >"$WT/wt.txt"
  git -C "$WT" add -A
  git -C "$WT" -c user.email=gaia-test@example.com -c user.name="GAIA Test" -c commit.gpgsign=false commit -q -m "wt $1"
}

# --- same-wave identity -------------------------------------------------------

@test "a dispatch from another session on a fifth tree is allowed and recorded" {
  alf_sequence 6 5 4 3
  [ "$(nrounds)" -eq 4 ]
  new_tree
  dispatch "$M" session-b
  assert_allowed
  [ "$(nrounds)" -eq 5 ]
  [ "$(sj '.history.rounds[4].tree')" = "$ALF_TREE" ]
  [ "$(sj '.history.rounds | map(.tree) | unique | length')" -eq 5 ]
}

@test "the first dispatch on an absent state is round 1 with frozen defaults and a stamp" {
  dispatch
  assert_allowed
  [ "$(nrounds)" -eq 1 ]
  [ "$(sj '.history.knobs.checkpoint_round')" -eq 5 ]
  [ "$(sj '.history.knobs.grant_rounds')" -eq 3 ]
  [ "$(sj '.history.rounds[0].members[0]')" = "$M" ]
  [ "$(sj '.history.rounds[0].raw_branch_slug')" = "$ALF_SLUG" ]
  [ -f "$ALF_ROOT/.gaia/local/audit-loop/feat/loop.d/round-1.stamp" ]
}

@test "a parallel member and a repeated member on the same tree join one round" {
  dispatch "$M"
  assert_allowed
  dispatch code-audit-maintainer-shell session-b
  assert_allowed
  dispatch "$M" session-c
  assert_allowed
  [ "$(nrounds)" -eq 1 ]
  [ "$(sj '.history.rounds[0].members | sort | join(",")')" = "code-audit-frontend,code-audit-maintainer-shell" ]
}

# --- the allowance checkpoint -------------------------------------------------

@test "a sixth tree is denied with the checkpoint, the rounds run and both typed lines" {
  alf_sequence 6 5 4 3 2
  new_tree
  dispatch "$M" session-b
  assert_denied
  r="$(reason)"
  printf '%s\n' "$r" | grep -qF -- "BLOCKED: audit checkpoint on branch feat/loop after 5 rounds (allowance)."
  printf '%s\n' "$r" | grep -qF -- "round 1: A=6 verdict=continue"
  printf '%s\n' "$r" | grep -qF -- "round 5: A=2 verdict=continue"
  printf '%s\n' "$r" | grep -qxF -- "Grant (type exactly as the whole prompt): $(gaia_loop_grant_line 3)"
  printf '%s\n' "$r" | grep -qxF -- "Accept (type exactly as the whole prompt): $(gaia_loop_accept_line)"
  printf '%s\n' "$r" | grep -qF -- "Interactive run: ask the human the checkpoint question from"
  printf '%s\n' "$r" | grep -qF -- "Unattended run (/gaia-debt drain or CI): stop, push the round's fix, leave the PR open and report this message."
  printf '%s\n' "$r" | grep -qF -- "never types or simulates"
  printf '%s\n' "$r" | grep -qF -- "already-audited tree is still allowed"
  printf '%s\n' "$r" | grep -qF -- "State file: $ALF_STATE"
  [ "$(nrounds)" -eq 5 ]
}

@test "an already-audited tree stays allowed at the checkpoint, from another session and with an agent_id" {
  alf_sequence 6 5 4 3 2
  run_payload "$(payload "$M" session-z "$ALF_ROOT" "$ALF_ROOT" '{"agent_id":"agent-9","agent_type":"code-audit-frontend"}')"
  assert_allowed
  dispatch code-audit-maintainer-node session-q
  assert_allowed
  [ "$(nrounds)" -eq 5 ]
  [ "$(sj '.history.rounds[4].members | length')" -eq 2 ]
}

@test "a new session cannot reset a checkpoint: the deny repeats and the checkpoint is recorded once" {
  alf_sequence 6 5 4 3 2
  new_tree
  dispatch "$M" session-b
  assert_denied
  cp "$ALF_STATE" "$BATS_TEST_TMPDIR/after-first"
  dispatch "$M" session-c
  assert_denied
  cmp "$ALF_STATE" "$BATS_TEST_TMPDIR/after-first"
  [ "$(sj '[.history.checkpoints[] | select(.at_round == 5)] | length')" -eq 1 ]
  [ "$(sj '.history.checkpoints[0].session_id')" = session-b ]
  [ "$(nrounds)" -eq 5 ]
}

# --- the evidence verdicts, through the hook ----------------------------------

# stalled_denied: the last-built sequence is stalled at round 3.
stalled_denied() {
  new_tree
  dispatch
  assert_denied
  reason | grep -qF -- "(stalled)"
  [ "$(sj '.history.checkpoints[0].reason')" = stalled ]
  [ "$(sj '.history.checkpoints[0].at_round')" -eq 3 ]
  [ "$(nrounds)" -eq 3 ]
}

next_allowed() {
  new_tree
  dispatch
  assert_allowed
  [ "$(sj '.history.checkpoints | length')" -eq 0 ]
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

@test "an accept answering a stalled checkpoint allows one closing round, then the allowance denies" {
  alf_sequence 5 5 5
  new_tree
  dispatch
  assert_denied
  alf_add_answer 1 accept
  dispatch
  assert_allowed
  [ "$(nrounds)" -eq 4 ]
  [ "$(sj '.history.rounds[3].closing')" = true ]
  new_tree
  dispatch
  assert_denied
  reason | grep -qF -- "(allowance)"
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
  [ "$(sj '.history.checkpoints | length')" -eq 2 ]
  [ "$(sj '.history.checkpoints[1].at_round')" -eq 7 ]
}

@test "a partial-repair run (A = 6,5,4,3,2 with one persisting key) is never stopped" {
  alf_fill f.txt 12 feature
  local r=0 a
  for a in 6 5 4 3 2; do
    r=$((r + 1))
    alf_set_line other.txt "$r" "round $r"
    alf_commit "round $r"
    dispatch
    assert_allowed
    alf_stamp "$r" $((10 * r))
    alf_sidecar "$M" "$(alf_entries f.txt 1 "$a")" $((10 * r + 1))
  done
  [ "$(nrounds)" -eq 5 ]
  [ "$(sj '.history.checkpoints | length')" -eq 0 ]
  [ "$(sj '[.history.rounds[0:4][].snapshot.verdict] | unique | join(",")')" = continue ]
  [ "$(sj '.history.rounds[3].snapshot.A')" -eq 3 ]
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

@test "with both knobs unset the checkpoint is at 5 and the grant line is audit-grant 3" {
  local i
  for i in 1 2 3 4 5; do
    new_tree
    dispatch
    assert_allowed
  done
  new_tree
  dispatch
  assert_denied
  reason | grep -qxF -- "Grant (type exactly as the whole prompt): audit-grant 3"
  [ "$(sj '.history.knobs.checkpoint_round')" -eq 5 ]
}

@test "a raised knob never allows past the frozen checkpoint" {
  local i
  for i in 1 2 3 4 5; do
    new_tree
    dispatch
    assert_allowed
  done
  new_tree
  export GAIA_AUDIT_CHECKPOINT_ROUND=9
  dispatch
  assert_denied
  [ "$(nrounds)" -eq 5 ]
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
  local i v
  for i in 1 2 3 4 5; do
    new_tree
    dispatch
    assert_allowed
  done
  new_tree
  for v in 0 -1 abc ""; do
    export GAIA_AUDIT_CHECKPOINT_ROUND="$v"
    dispatch
    assert_denied
  done
  [ "$(nrounds)" -eq 5 ]
}

# --- the pull request link ------------------------------------------------------

@test "a merged pull request's state moves to .closed and a reused branch name starts at round 1" {
  alf_sequence 6 5 4 3 2
  jq '.pr = 100' "$ALF_STATE" >"$ALF_STATE.t" && mv "$ALF_STATE.t" "$ALF_STATE"
  printf '{"number":200,"state":"OPEN"}\n' >"$GH_DIR/branch.json"
  printf '{"state":"MERGED"}\n' >"$GH_DIR/pr-100.json"
  new_tree
  dispatch
  assert_allowed
  [ "$(nrounds)" -eq 1 ]
  [ "$(sj '.pr')" -eq 200 ]
  [ "$(find "$ALF_ROOT/.gaia/local/audit-loop/.closed" -name 'feat+loop.100.*.json' | wc -l | tr -d ' ')" -eq 1 ]
}

@test "a branch lookup that returns the linked pull request as MERGED closes the state" {
  alf_sequence 6 5 4 3 2
  jq '.pr = 100' "$ALF_STATE" >"$ALF_STATE.t" && mv "$ALF_STATE.t" "$ALF_STATE"
  printf '{"number":100,"state":"MERGED"}\n' >"$GH_DIR/branch.json"
  new_tree
  dispatch
  assert_allowed
  [ "$(nrounds)" -eq 1 ]
  [ "$(sj '.pr')" = null ]
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
  printf '{"number":321,"state":"OPEN"}\n' >"$GH_DIR/branch.json"
  dispatch
  assert_allowed
  [ "$(sj '.pr')" -eq 321 ]
}

@test "a renamed branch with the same open pull request carries history and allowance over" {
  alf_branch old/name
  alf_sequence 6 5 4
  jq '.pr = 77' "$ALF_STATE" >"$ALF_STATE.t" && mv "$ALF_STATE.t" "$ALF_STATE"
  old_state="$ALF_STATE"
  alf_git branch -m new/name
  ALF_B=new/name
  ALF_STATE="$ALF_ROOT/.gaia/local/audit-loop/new/name.json"
  printf '{"number":77,"state":"OPEN"}\n' >"$GH_DIR/branch.json"
  new_tree
  dispatch
  assert_allowed
  [ "$(nrounds)" -eq 4 ]
  [ "$(sj '.branch')" = new/name ]
  [ "$(sj '.key')" = branch:new/name ]
  [ "$(sj '.history.rounds[0].raw_branch_slug')" != "$(gaia_key_slug new/name)" ]
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
  [ "$(sj '.history.rounds[2].snapshot.verdict')" = unknown ]
  [ "$(sj '.history.rounds[2].snapshot.A')" = null ]
  [ "$(nrounds)" -eq 4 ]
}

@test "a missing previous-round sidecar records unknown and is denied at the allowance" {
  alf_sequence 6 5 4 3 2
  rm -f "$ALF_ROOT"/.gaia/local/audit/*.findings.json
  new_tree
  dispatch
  assert_denied
  [ "$(sj '.history.rounds[4].snapshot.verdict')" = unknown ]
  [ "$(sj '.history.rounds[4].snapshot.A')" = null ]
}

@test "jq absent denies a member dispatch with exit 2 and allows a general-purpose dispatch" {
  build_path "$BATS_TEST_TMPDIR/nojq" jq
  run env PATH="$BATS_TEST_TMPDIR/nojq" bash -c 'printf %s "$1" | /bin/bash "$2"' _ "$(payload "$M" "$SID" "$ALF_ROOT" "$ALF_ROOT")" "$HOOK"
  [ "$status" -eq 2 ]
  grep -qF -- BLOCKED <<<"$output"
  grep -qF -- jq <<<"$output"
  run env PATH="$BATS_TEST_TMPDIR/nojq" bash -c 'printf %s "$1" | /bin/bash "$2"' _ "$(payload general-purpose "$SID" "$ALF_ROOT" "$ALF_ROOT")" "$HOOK"
  assert_allowed
  [ ! -e "$ALF_ROOT/.gaia/local/audit-loop" ]
}

@test "git absent denies a member dispatch with a message naming git" {
  build_path "$BATS_TEST_TMPDIR/nogit" git
  run env PATH="$BATS_TEST_TMPDIR/nogit" bash -c 'printf %s "$1" | /bin/bash "$2"' _ "$(payload "$M" "$SID" "$ALF_ROOT" "$ALF_ROOT")" "$HOOK"
  assert_denied
  reason | grep -qF -- "git is not on PATH"
  [ ! -e "$ALF_ROOT/.gaia/local/audit-loop/feat/loop.json" ]
}

# --- resolving the audited root --------------------------------------------------

@test "a worktree branch and a main checkout on one key accumulate rounds in one file" {
  alf_branch debt/42-fix
  linked_worktree wt1 worktree-debt+42-fix
  wt_commit 1
  run_payload "$(payload "$M" "$SID" "$WT" "$ALF_ROOT")"
  assert_allowed
  new_tree
  run_payload "$(payload "$M" "$SID" "$ALF_ROOT" "$WT")"
  assert_allowed
  [ "$(nrounds)" -eq 2 ]
  [ ! -e "$ALF_ROOT/.gaia/local/audit-loop/worktree-debt+42-fix.json" ]
  [ "$(sj '.history.rounds[0].raw_branch_slug')" != "$(sj '.history.rounds[1].raw_branch_slug')" ]
}

@test "a cwd on main with a prompt naming a feature worktree records under the feature branch" {
  alf_git checkout -q main
  linked_worktree wt2 feat/from-wt
  ALF_B=feat/from-wt
  ALF_STATE="$ALF_ROOT/.gaia/local/audit-loop/feat/from-wt.json"
  wt_commit 1
  run_payload "$(payload "$M" "$SID" "$WT" "$ALF_ROOT")"
  assert_allowed
  [ -f "$ALF_STATE" ]
  [ "$(nrounds)" -eq 1 ]
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
  ALF_B=feat/denied-wt
  ALF_STATE="$ALF_ROOT/.gaia/local/audit-loop/$ALF_B.json"
  local t
  t="$(printf 'a%.0s' $(seq 1 39))"
  alf_seed_state "$(jq -n -c --arg t "$t" '{rounds: [range(1; 6) | {round: ., tree: ($t + (. | tostring)), commit: ($t + (. | tostring)),
    raw_branch_slug: "x", dispatched_at: "2026-01-01T00:00:00Z", members: ["code-audit-frontend"], closing: false, snapshot: null}]}')"
  wt_commit 1
  run_payload "$(payload "$M" session-main "$WT" "$ALF_ROOT")"
  assert_denied
  [ "$(sj '.history.checkpoints[0].session_id')" = session-main ]
  [ "$(sj '.history.checkpoints[0].audited_root')" = "$WT" ]
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
for a in "\$@"; do
  if [ "\$a" = diff ]; then exec sleep 6.$$; fi
done
exec "$REAL_GIT" "\$@"
EOF
  chmod +x "$SLOW/git"
}

@test "a slow git past the deadline denies naming the deadline within about 2 seconds and leaves no child" {
  mk_slow_git
  new_tree
  export GAIA_AUDIT_LOOP_DEADLINE_SECONDS=1
  local t0 t1
  t0="$(date +%s)"
  run_payload "$(payload "$M" "$SID" "$ALF_ROOT" "$ALF_ROOT")" "$SLOW"
  t1="$(date +%s)"
  assert_denied
  reason | grep -qF -- "1s internal deadline"
  [ $((t1 - t0)) -le 3 ]
  pgrep -f "sleep 6.$$" >/dev/null && return 1
  [ ! -e "$ALF_STATE" ]
  [ ! -e "$ALF_STATE.lock" ]
}

@test "a deadline override larger than the default is ignored and a smaller one is honoured" {
  mk_slow_git
  scratch_hook 4
  new_tree
  export GAIA_AUDIT_LOOP_DEADLINE_SECONDS=999
  run_payload "$(payload "$M" "$SID" "$ALF_ROOT" "$ALF_ROOT")" "$SLOW"
  assert_denied
  reason | grep -qF -- "4s internal deadline"
  export GAIA_AUDIT_LOOP_DEADLINE_SECONDS=2
  run_payload "$(payload "$M" "$SID" "$ALF_ROOT" "$ALF_ROOT")" "$SLOW"
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
  local m i=0 p
  p="$(payload x "$SID" "$ALF_ROOT" "$ALF_ROOT")"
  for m in code-audit-frontend code-audit-github-workflows code-audit-maintainer-node code-audit-maintainer-shell code-audit-extra; do
    i=$((i + 1))
    (printf '%s' "$p" | jq -c --arg m "$m" '.tool_input.subagent_type = $m' |
      env PATH="$STUB_BIN:$PATH" GH_STUB_DIR="$GH_DIR" bash "$HOOK" >"$BATS_TEST_TMPDIR/out.$i" 2>&1) &
  done
  wait
  for i in 1 2 3 4 5; do
    [ ! -s "$BATS_TEST_TMPDIR/out.$i" ] || { printf 'out.%s: %s\n' "$i" "$(cat "$BATS_TEST_TMPDIR/out.$i")" >&2; return 1; }
  done
  [ "$(nrounds)" -eq 1 ]
  [ "$(sj '.history.rounds[0].members | length')" -eq 5 ]
}

@test "two checkouts of one key dispatching at once on different trees never lose a tree" {
  alf_branch feat/x
  linked_worktree wtc worktree-feat+x
  new_tree
  wt_commit 1
  local p1 p2
  p1="$(payload "$M" s1 "$ALF_ROOT" "$ALF_ROOT")"
  p2="$(payload "$M" s2 "$WT" "$WT")"
  (printf '%s' "$p1" | env PATH="$STUB_BIN:$PATH" GH_STUB_DIR="$GH_DIR" bash "$HOOK" >"$BATS_TEST_TMPDIR/o1" 2>&1) &
  (printf '%s' "$p2" | env PATH="$STUB_BIN:$PATH" GH_STUB_DIR="$GH_DIR" bash "$HOOK" >"$BATS_TEST_TMPDIR/o2" 2>&1) &
  wait
  [ ! -s "$BATS_TEST_TMPDIR/o1" ]
  [ ! -s "$BATS_TEST_TMPDIR/o2" ]
  [ "$(nrounds)" -eq 2 ]
  [ "$(sj '.history.rounds | map(.tree) | unique | length')" -eq 2 ]
}

# --- scope ----------------------------------------------------------------------

@test "non-member dispatches exit 0 silently and create no state directory" {
  local sub
  for sub in general-purpose Explore code-reviewer; do
    run_payload "$(payload "$sub" "$SID" "$ALF_ROOT" "$ALF_ROOT")"
    assert_allowed
  done
  run_payload "$(jq -n -c --arg c "$ALF_ROOT" '{session_id: "s", tool_name: "Agent", cwd: $c, tool_input: {prompt: "x"}}')"
  assert_allowed
  run_payload "$(payload "$M" "$SID" "$ALF_ROOT" "$ALF_ROOT" | jq -c '.tool_name = "Bash"')"
  assert_allowed
  [ ! -e "$ALF_ROOT/.gaia/local/audit-loop" ]
}

@test "the Task tool name is bound like Agent" {
  run_payload "$(payload "$M" "$SID" "$ALF_ROOT" "$ALF_ROOT" | jq -c '.tool_name = "Task"')"
  assert_allowed
  [ "$(nrounds)" -eq 1 ]
}

# --- fork pull requests ---------------------------------------------------------
#
# A dispatch that would record a round asks gh whether the audited checkout's
# pull request is a fork. The stub's answer comes from $GH_DIR/cross-repository
# (see setup). Each refusal is driven both ways: against the hook, and against
# a scratch mutant that lacks the arm, which must let the same case through.

# fork_mutant <perl-substitution>: point HOOK at a copy with one mutation.
fork_mutant() {
  local d="$BATS_TEST_TMPDIR/fork-mutant"
  mkdir -p "$d/.claude/hooks"
  ln -sfn "$REPO_ROOT/.gaia" "$d/.gaia"
  ln -sfn "$REPO_ROOT/.claude/hooks/lib" "$d/.claude/hooks/lib"
  perl -0pe "$1" "$HOOK" >"$d/.claude/hooks/audit-loop-bound.sh"
  cmp -s "$HOOK" "$d/.claude/hooks/audit-loop-bound.sh" && { printf 'mutation changed nothing: %s\n' "$1" >&2; return 1; }
  HOOK="$d/.claude/hooks/audit-loop-bound.sh"
}

@test "UAT-010: a dispatch for a fork pull request is denied with the refusal and records no round" {
  local message
  printf '{"number":34,"state":"OPEN"}\n' >"$GH_DIR/branch.json"
  printf 'true\n' >"$GH_DIR/cross-repository"
  dispatch
  assert_denied
  message="$(bash -c '. "$1"; printf "%s" "$GAIA_CROSS_REPO_REFUSAL_MESSAGE"' _ "$REPO_ROOT/.claude/hooks/lib/cross-repo-refusal.sh")"
  reason | grep -qF -- "$message"
  grep -qxF -- 'pr view --json isCrossRepository --jq .isCrossRepository' "$GH_DIR/calls.log"
  [ ! -f "$ALF_STATE" ]
}

@test "UAT-010: the same dispatch for a same-repo pull request is allowed and records its round" {
  printf '{"number":34,"state":"OPEN"}\n' >"$GH_DIR/branch.json"
  printf 'false\n' >"$GH_DIR/cross-repository"
  dispatch
  assert_allowed
  [ "$(nrounds)" -eq 1 ]
}

@test "UAT-010: a dispatch is denied, naming the gh failure, when gh cannot say whether the pull request is a fork" {
  printf 'fail\n' >"$GH_DIR/cross-repository"
  dispatch
  assert_denied
  reason | grep -qF -- 'cannot tell whether the pull request'
  reason | grep -qF -- 'HTTP 502: Bad Gateway'
  reason | grep -qF -- 'push the branch to origin'
  [ ! -f "$ALF_STATE" ]
}

@test "UAT-010 mutation: without the refusal call the fork dispatch is allowed, so the denial test can fail" {
  fork_mutant "s/gaia_pr_is_cross_repository '' \\|\\| fork_status=\\\$\\?/fork_status=1/"
  printf '{"number":34,"state":"OPEN"}\n' >"$GH_DIR/branch.json"
  printf 'true\n' >"$GH_DIR/cross-repository"
  dispatch
  assert_allowed
  [ "$(nrounds)" -eq 1 ]
}

@test "UAT-010 mutation: treating an unanswerable gh as allow lets the dispatch through, so the fail-closed test can fail" {
  fork_mutant 's/\n      1\) ;;\n      0\) finish_deny "BLOCKED: \$GAIA_CROSS_REPO_REFUSAL_MESSAGE" ;;/\n      1 | 2) ;;\n      0) finish_deny "BLOCKED: \$GAIA_CROSS_REPO_REFUSAL_MESSAGE" ;;/'
  printf 'fail\n' >"$GH_DIR/cross-repository"
  dispatch
  assert_allowed
  [ "$(nrounds)" -eq 1 ]
}
