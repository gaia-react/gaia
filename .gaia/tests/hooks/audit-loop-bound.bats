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
  [ "$(sj '.history.knobs.checkpoint_round')" -eq 6 ]
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
  printf '%s\n' "$r" | grep -qF -- "BLOCKED: audit checkpoint on branch feat/loop after 5 rounds (fallback)."
  printf '%s\n' "$r" | grep -qF -- "round 1: A=6 verdict=continue"
  printf '%s\n' "$r" | grep -qF -- "round 5: A=2 verdict=continue"
  printf '%s\n' "$r" | grep -qxF -- "Grant (type exactly as the whole prompt): $(gaia_loop_grant_line 3)"
  printf '%s\n' "$r" | grep -qxF -- "Accept (type exactly as the whole prompt): $(gaia_loop_accept_line)"
  printf '%s\n' "$r" | grep -qF -- "Interactive run: on the main thread of this session, ask this question with AskUserQuestion exactly as printed"
  printf '%s\n' "$r" | grep -qF -- "Unattended run (a /gaia-debt drain): never ask; stop, leave the PR open, print the typed grant line above, and print no continuation prompt."
  printf '%s\n' "$r" | grep -qF -- "or CI" && return 1
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

@test "a new session cannot reset a checkpoint: the deny repeats with a fresh pinned checkpoint and no round" {
  alf_sequence 6 5 4 3 2
  new_tree
  dispatch "$M" session-b
  assert_denied
  dispatch "$M" session-c
  assert_denied
  [ "$(sj '[.history.checkpoints[] | select(.at_round == 5)] | length')" -eq 2 ]
  [ "$(sj '.history.checkpoints[0].session_id')" = session-b ]
  [ "$(sj '.history.checkpoints[1].session_id')" = session-c ]
  [ "$(sj '.history.checkpoints[0].nonce')" != "$(sj '.history.checkpoints[1].nonce')" ]
  [ "$(nrounds)" -eq 5 ]
}

# --- the evidence verdicts, through the hook ----------------------------------

# stalled_denied: the last-built sequence is stalled at round 3.
stalled_denied() {
  new_tree
  dispatch
  assert_denied
  reason | grep -qF -- "(rubric:stalled)"
  [ "$(sj '.history.checkpoints[0].reason')" = rubric:stalled ]
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

@test "an accept answering a stalled checkpoint allows one closing round, then the fallback denies" {
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
  [ "$(sj '.history.knobs.checkpoint_round')" -eq 6 ]
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
  local i v
  for i in 1 2 3 4 5 6; do
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
  [ "$(nrounds)" -eq 6 ]
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

@test "a prose Working root ending in a period records under the named worktree, not the cwd" {
  local p
  alf_git checkout -q main
  linked_worktree wt3 feat/prose
  ALF_STATE="$ALF_ROOT/.gaia/local/audit-loop/feat/prose.json"
  wt_commit 1
  p="$(jq -n -c --arg m "$M" --arg s "$SID" --arg root "$WT" --arg cwd "$ALF_ROOT" \
    '{session_id: $s, hook_event_name: "PreToolUse", tool_name: "Agent", cwd: $cwd,
      tool_input: {subagent_type: $m, prompt: ("Working root: " + $root + ". Audit the PR.")}}')"
  run_payload "$p"
  assert_allowed
  [ -f "$ALF_STATE" ]
  [ "$(nrounds)" -eq 1 ]
  [ ! -e "$ALF_ROOT/.gaia/local/audit-loop/main.json" ]
}

@test "a named Working root that does not resolve is denied naming it and charges no round to the cwd" {
  local missing="$BATS_TEST_TMPDIR/no-such-checkout"
  alf_git checkout -q main
  run_payload "$(payload "$M" "$SID" "$missing" "$ALF_ROOT")"
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
  fork_mutant 's/if fork_reason=\$\(gaia_cross_repo_deny_reason/if false && fork_reason=\$(gaia_cross_repo_deny_reason/'
  printf '{"number":34,"state":"OPEN"}\n' >"$GH_DIR/branch.json"
  printf 'true\n' >"$GH_DIR/cross-repository"
  dispatch
  assert_allowed
  [ "$(nrounds)" -eq 1 ]
}

@test "UAT-010 mutation: treating an unanswerable gh as allow lets the dispatch through, so the fail-closed test can fail" {
  fork_mutant 's/finish_deny "\$fork_reason"/case "\$fork_reason" in *"cannot tell"*) ;; *) finish_deny "\$fork_reason" ;; esac/'
  printf 'fail\n' >"$GH_DIR/cross-repository"
  dispatch
  assert_allowed
  [ "$(nrounds)" -eq 1 ]
}

# --- the unit gate ----------------------------------------------------------------
#
# K, the line defaults and the hard cap come from the libs the suite sources in
# setup (GAIA_CTX_UNIT_ROUNDS, GAIA_CTX_ASK_TOKENS_DEFAULT,
# GAIA_CTX_ASK_WINDOW_PCT_DEFAULT, _GAIA_LOOP_HARD_CAP), never from literals.
# A context reading is keyed by a UUID session id; the plain ids the cases
# above use read as `missing`, which is the round-count fallback.

SIDU=0a1b2c3d-1111-4222-8333-444455556666
SIDV=0a1b2c3d-2222-4222-8333-444455556666
IN_UNIT='{"agent_id":"a0b1c2d3e4f5a6b7c","agent_type":"audit-loop-unit"}'

# ctx <tokens> <window> [age-seconds] [session]: write that session's reading.
ctx() {
  local t="$1" w="$2" age="${3:-0}" sid="${4:-$SIDU}"
  gaia_ctx_write "$ALF_ROOT" "$sid" "$((t * 100 / w))" "$t" "$w" "$(($(date +%s) - age))"
}

# below / above: a fresh 1M-window reading one token either side of the default line.
below() { ctx $((GAIA_CTX_ASK_TOKENS_DEFAULT - 1)) 1000000 0 "${1:-$SIDU}"; }
above() { ctx "$GAIA_CTX_ASK_TOKENS_DEFAULT" 1000000 0 "${1:-$SIDU}"; }

# unit_payload <session> [extra-json]: an audit-loop-unit dispatch whose brief
# carries the fixture root.
unit_payload() {
  local extra="${2-}"
  [ -n "$extra" ] || extra='{}'
  jq -n -c --arg s "$1" --arg root "$ALF_ROOT" --argjson x "$extra" \
    '{session_id: $s, hook_event_name: "PreToolUse", tool_name: "Agent", cwd: $root,
      tool_input: {subagent_type: "audit-loop-unit",
        prompt: ("Run one audit unit.\nWorking root: " + $root + "\nUnit: 1\nStart round: 1")}} + $x'
}

unit_dispatch() {
  run_payload "$(unit_payload "${1:-$SIDU}")"
}

# nested [member] [session]: a member dispatch made from inside a unit.
nested() {
  run_payload "$(payload "${1:-$M}" "${2:-$SIDU}" "$ALF_ROOT" "$ALF_ROOT" "$IN_UNIT")"
}

# main_member [member] [session]: a member dispatch from the main thread.
main_member() {
  run_payload "$(payload "${1:-$M}" "${2:-$SIDU}" "$ALF_ROOT" "$ALF_ROOT")"
}

kmin() {
  if [ "$1" -lt "$2" ]; then printf '%s\n' "$1"; else printf '%s\n' "$2"; fi
}

# seed_rounds <n> <last-snapshot-json>: n recorded rounds on stand-in trees with
# frozen default knobs; every earlier snapshot is a plain continue.
seed_rounds() {
  local t
  t="$(printf 'a%.0s' $(seq 1 37))"
  alf_seed_state "$(jq -n -c --arg t "$t" --argjson n "$1" --argjson last "$2" '{knobs: {checkpoint_round: 6, grant_rounds: 3},
    rounds: [range(1; $n + 1) | {round: ., tree: ($t + ((100 + .) | tostring)), commit: ($t + ((100 + .) | tostring)),
      raw_branch_slug: "x", dispatched_at: "2026-01-01T00:00:00Z", members: ["code-audit-frontend"], closing: false,
      snapshot: (if . == $n then $last else {verdict: "continue", A: 1} end)}]}')"
}

# sig_snap <signal> <eligible>: a stored snapshot holding exactly one signal.
sig_snap() {
  jq -n -c --arg s "$1" --argjson e "$2" \
    '{verdict: (if $s == "quiet" or $s == "enriching" or $s == "stalled" then $s else "continue" end),
      A: (if $s == "quiet" then 0 else 1 end), counted_keys: [], raw_count: 1, waived_count: 0,
      signals: {($s): true}, accept_eligible: $e, accept_reasons: [$s]}'
}

# assert_pinned <trigger>: the last run is a checkpoint deny; the latest
# checkpoint carries a nonce and a pinned question for <trigger>, and the deny
# prints that question verbatim with the asking instruction and the typed line.
assert_pinned() {
  local r q
  assert_denied
  r="$(reason)"
  case "$r" in "BLOCKED: audit checkpoint"*) ;; *) printf 'not a checkpoint deny: %s\n' "$r" >&2; return 1 ;; esac
  [ "$(sj '.history.checkpoints | last | .trigger')" = "$1" ]
  [ "$(sj '.history.checkpoints | last | .reason')" = "$1" ]
  [[ "$(sj '.history.checkpoints | last | .nonce')" =~ ^[0-9a-f]{16}$ ]] || return 1
  [ "$(sj '.history.checkpoints | last | .question.questions[0].options | length')" -ge 2 ]
  [ "$(sj '[.history.checkpoints | last | .question.questions[0].options[].label] | index("Stop and file the remainder") != null')" = true ]
  q="$(sj '.history.checkpoints | last | .question | tojson')"
  printf '%s\n' "$r" | grep -qxF -- "$q"
  printf '%s\n' "$r" | grep -qF -- AskUserQuestion
  printf '%s\n' "$r" | grep -qF -- audit-grant
}

# deny_prefix <prefix>: the last run denied with a reason starting <prefix>.
deny_prefix() {
  assert_denied
  case "$(reason)" in "$1"*) ;; *) printf 'want prefix %s, got: %s\n' "$1" "$(reason)" >&2; return 1 ;; esac
}

# scratch_copy: point HOOK at a copy of the hook whose scripts directory is a
# real copy of the files the hook loads, so a case can remove or stub one.
scratch_copy() {
  local d="$BATS_TEST_TMPDIR/scratch-copy" f
  rm -rf "$d"
  mkdir -p "$d/.claude/hooks" "$d/.gaia/scripts"
  for f in audit-loop-state-lib.sh branch-name-lib.sh main-root-lib.sh audit-key-lib.sh context-checkpoint-lib.sh \
    audit-loop-eval.sh audit-loop-signals-lib.sh audit-dispositions-check.sh; do
    cp "$REPO_ROOT/.gaia/scripts/$f" "$d/.gaia/scripts/$f"
  done
  ln -sfn "$REPO_ROOT/.claude/hooks/lib" "$d/.claude/hooks/lib"
  cp "$BOUND_HOOK" "$d/.claude/hooks/audit-loop-bound.sh"
  HOOK="$d/.claude/hooks/audit-loop-bound.sh"
  SCRATCH_SCRIPTS="$d/.gaia/scripts"
}

# settings <ask_tokens> <ask_window_pct>: the machine-local line override.
settings() {
  mkdir -p "$ALF_ROOT/.gaia/local"
  jq -n -c --argjson t "$1" --argjson p "$2" '{version: 1, context_checkpoint: {ask_tokens: $t, ask_window_pct: $p}}' \
    >"$ALF_ROOT/.gaia/local/settings.json"
}

@test "fast path: a general-purpose dispatch exits 0 silently without touching the context directory" {
  local cdir
  cdir="$(dirname "$(gaia_ctx_file "$ALF_ROOT" "$SIDU")")"
  mkdir -p "$cdir"
  chmod 000 "$cdir"
  run_payload "$(payload general-purpose "$SIDU" "$ALF_ROOT" "$ALF_ROOT")"
  chmod 755 "$cdir"
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
  printf '{"number":51,"state":"OPEN"}\n' >"$GH_DIR/branch.json"
  below
  unit_dispatch
  assert_allowed
  [ "$(nrounds)" -eq 0 ]
  [ "$(sj '.pr')" -eq 51 ]
  [ "$(sj '.history.knobs.checkpoint_round')" -eq 6 ]
  [ "$(sj '.history.context_config.ask_tokens')" -eq "$GAIA_CTX_ASK_TOKENS_DEFAULT" ]
  [ "$(sj '.history.context_config.ask_window_pct')" -eq "$GAIA_CTX_ASK_WINDOW_PCT_DEFAULT" ]
  [ "$(sj '.history.units | length')" -eq 1 ]
  [ "$(sj '.history.units[0].start_round')" -eq 1 ]
  [ "$(sj '.history.units[0].through_round')" -eq "$GAIA_CTX_UNIT_ROUNDS" ]
  [ "$(sj '.history.units[0].admitted_on')" = context ]
  [ "$(sj '.history.units[0].session_id')" = "$SIDU" ]
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
  local K="$GAIA_CTX_UNIT_ROUNDS" through r
  through="$(kmin $((6 + K)) "$_GAIA_LOOP_HARD_CAP")"
  alf_sequence 6 5 4 3 2 1
  alf_state_edit '.history.knobs.checkpoint_round = 6'
  below
  unit_dispatch
  assert_allowed
  [ "$(sj '.history.units[-1] | [.start_round, .k, .through_round, .admitted_on] | map(tostring) | join(" ")')" = "7 $K $through context" ]
  [ "$(sj '.history.checkpoints | length')" -eq 0 ]
  r=7
  while [ "$r" -le "$through" ]; do
    new_tree
    nested
    assert_allowed
    [ "$(nrounds)" -eq "$r" ]
    r=$((r + 1))
  done
  new_tree
  nested
  if [ "$through" -lt "$_GAIA_LOOP_HARD_CAP" ]; then
    deny_prefix "BLOCKED: audit window"
    reason | grep -qF -- "rounds 7 through $through"
    reason | grep -qF -- "window-end"
    [ "$(sj '.history.checkpoints | length')" -eq 0 ]
  else
    assert_pinned cap
  fi
  [ "$(nrounds)" -eq "$through" ]
}

@test "red state: deciding the in-unit member by the round-count allowance denies the round-7 dispatch" {
  fork_mutant 's/dec=\$\(gaia_loop_decide_member "\$view" "\$snap" "\$in_unit" "\$reading" "\$ask_tokens" "\$ask_pct"\)/dec=\$(gaia_loop_decide "\$S" "\$snap")/'
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
  nonce="$(sj '.history.checkpoints[-1].nonce')"
  elig="$(sj '.history.rounds[1].snapshot.accept_eligible // false')"
  want="$(gaia_loop_pinned_question feat/loop "$nonce" 2 "$GAIA_CTX_UNIT_ROUNDS" "$elig" false context "fresh $GAIA_CTX_ASK_TOKENS_DEFAULT 1000000")"
  [ "$(sj '.history.checkpoints[-1].question | tojson')" = "$want" ]
  [[ "$(sj '.history.checkpoints[-1].question.questions[0].question')" == *"(context), context "[0-9]*"% ("[0-9]*"k of 1000k). How should"* ]]
  [ "$(sj '.history.checkpoints[-1].at_round')" -eq 2 ]
  reason | grep -qF -- "never ask; stop, leave the PR open, print the typed grant line above, and print no continuation prompt"
  [ "$(sj '.history.units // [] | length')" -eq 0 ]
}

@test "missing, stale, future-dated and garbage readings fall back to the round count: allowed at 5 used, denied at 6" {
  local mode f
  f="$(gaia_ctx_file "$ALF_ROOT" "$SIDU")"
  for mode in missing stale future garbage; do
    rm -f "$f" "$ALF_STATE"
    rm -rf "${ALF_STATE%.json}.d"
    seed_rounds 5 '{"verdict":"continue","A":1}'
    case "$mode" in
      missing) ;;
      stale) ctx 1000 1000000 $((GAIA_CTX_FRESH_SECONDS + 60)) ;;
      future) ctx 1000 1000000 -3600 ;;
      garbage) mkdir -p "${f%/*}" && printf '{garbage' >"$f" ;;
    esac
    unit_dispatch
    assert_allowed
    [ "$(sj '.history.units[-1] | [.admitted_on, .start_round, .through_round] | map(tostring) | join(" ")')" = "fallback 6 6" ]
    seed_rounds 6 '{"verdict":"continue","A":1}'
    unit_dispatch
    assert_pinned fallback
  done
}

@test "below the line each denying signal denies the unit and quiet alone does not; the cap pins accept or type-accept with stop" {
  local s
  below
  for s in enriching stalled nitpicky reintroduced small-tail waiver-drift; do
    seed_rounds 6 "$(sig_snap "$s" true)"
    unit_dispatch
    assert_pinned "rubric:$s"
  done
  seed_rounds 6 "$(sig_snap quiet true)"
  unit_dispatch
  assert_allowed
  seed_rounds "$_GAIA_LOOP_HARD_CAP" "$(sig_snap cap true)"
  unit_dispatch
  assert_pinned cap
  [ "$(sj '[.history.checkpoints[-1].question.questions[0].options[].label] | join("|")')" = "Accept the remainder|Stop and file the remainder" ]
  seed_rounds "$_GAIA_LOOP_HARD_CAP" "$(sig_snap cap false)"
  unit_dispatch
  assert_pinned cap
  [ "$(sj '[.history.checkpoints[-1].question.questions[0].options[].label] | join("|")')" = "Type audit-accept instead|Stop and file the remainder" ]
}

@test "an ask grant admits one K-round unit over the line; the next unit asks again; a new session below the line continues" {
  local K="$GAIA_CTX_UNIT_ROUNDS" idx nonce
  alf_sequence 6 5
  above
  unit_dispatch
  assert_pinned context
  idx="$(sj '.history.checkpoints[-1].index')"
  nonce="$(sj '.history.checkpoints[-1].nonce')"
  alf_state_edit '.allowance.answers += [{checkpoint: $i, kind: "grant", n: $k, source: "ask", option: ("Grant " + ($k | tostring) + ", continue here"),
    nonce: $n, at: "2026-01-01T00:00:00Z", session_id: $s}]' --argjson i "$idx" --argjson k "$K" --arg n "$nonce" --arg s "$SIDU"
  unit_dispatch
  assert_allowed
  [ "$(sj '.history.units[-1] | [.admitted_on, .start_round, .through_round, .after_checkpoint] | map(tostring) | join(" ")')" = "grant 3 $(kmin $((2 + K)) "$_GAIA_LOOP_HARD_CAP") $idx" ]
  unit_dispatch
  assert_pinned context
  [ "$(sj '.history.checkpoints[-1].nonce')" != "$nonce" ]
  below "$SIDV"
  unit_dispatch "$SIDV"
  assert_allowed
  [ "$(sj '.history.units[-1].admitted_on')" = context ]
  [ "$(sj '.history.units[-1].session_id')" = "$SIDV" ]
}

@test "a pending checkpoint with no answer denies the next unit again with a new nonce" {
  local first
  alf_sequence 6 5
  above
  unit_dispatch
  assert_pinned context
  first="$(sj '.history.checkpoints[-1].nonce')"
  unit_dispatch
  assert_pinned context
  [ "$(sj '.history.checkpoints | length')" -eq 2 ]
  [ "$(sj '.history.checkpoints[-1].nonce')" != "$first" ]
}

@test "a legacy pending checkpoint without a nonce is superseded by a pinned one" {
  alf_sequence 6 5
  alf_add_checkpoint 2 allowance
  above
  unit_dispatch
  assert_pinned context
  [ "$(sj '.history.checkpoints | length')" -eq 2 ]
  [ "$(sj '.history.checkpoints[0].nonce // "none"')" = none ]
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
  alf_sidecar "$M" '[{"path":"f.txt","line":1,"security":false}]' 11
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
  alf_sidecar "$M" '[{"path":"f.txt","line":1,"security":false}]' 21
  jq -n -c --argjson k "$FINDING_X" '{version: 1, keys: [$k + {vetoed_at: "2026-01-01T00:00:00Z", unit: 1, effective_from_round: 2}]}' \
    >"$ALF_ROOT/.gaia/local/runs/$ALF_B/vetoes.json"
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
  alf_sidecar "$M" '[{"path":"f.txt","line":2,"security":false}]' 21
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
  [ "$(sj '.history.units // [] | length')" -eq 0 ]
}

@test "a window left by a unit that returned nesting-unavailable does not cover a main-thread or non-unit member over the line" {
  alf_sequence 6 5
  alf_state_edit '.history.units = [{unit: 1, start_round: 3, k: 3, through_round: 5, admitted_on: "context",
    after_checkpoint: 0, recorded_at: "2026-01-01T00:00:00Z", session_id: $s}]' --arg s "$SIDU"
  mkdir -p "$ALF_ROOT/.gaia/local/runs/$ALF_B"
  printf '{"version":1,"unit":1,"start_round":3,"through_round":5,"k":3,"rounds":[{"round":3,"opened":false,"reason":"nesting-unavailable"}],"stop_reason":"nesting-unavailable"}\n' \
    >"$ALF_ROOT/.gaia/local/runs/$ALF_B/unit-1.json"
  new_tree
  above
  main_member
  assert_pinned context
  run_payload "$(payload "$M" "$SIDU" "$ALF_ROOT" "$ALF_ROOT" '{"agent_id":"a0b1c2d3e4f5a6b7c","agent_type":"general-purpose"}')"
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
  ctx 350000 1000000
  unit_dispatch
  assert_pinned context
  settings 250000 50
  ctx 260000 1000000
  unit_dispatch
  assert_pinned context
  ctx 240000 1000000
  unit_dispatch
  assert_allowed
  rm -f "$ALF_ROOT/.gaia/local/settings.json"
  ctx 120000 200000
  unit_dispatch
  assert_pinned context
  alf_state_edit '.history.context_config = {ask_tokens: 250000, ask_window_pct: 50}'
  ctx 260000 1000000
  unit_dispatch
  assert_pinned context
  ctx 240000 1000000
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
    [ "$(sj '.history.context_config | "\(.ask_tokens) \(.ask_window_pct)"')" = "$GAIA_CTX_ASK_TOKENS_DEFAULT $GAIA_CTX_ASK_WINDOW_PCT_DEFAULT" ]
    above
    unit_dispatch
    assert_pinned context
  done
}

@test "at the round cap a unit is denied with trigger cap and a nested member for the next round is denied" {
  seed_rounds "$_GAIA_LOOP_HARD_CAP" '{"verdict":"continue","A":1}'
  alf_state_edit '.history.units = [{unit: 1, start_round: 8, k: 3, through_round: 10, admitted_on: "context",
    after_checkpoint: 0, recorded_at: "2026-01-01T00:00:00Z", session_id: $s}]' --arg s "$SIDU"
  below
  unit_dispatch
  assert_pinned cap
  new_tree
  nested
  assert_pinned cap
  [ "$(nrounds)" -eq "$_GAIA_LOOP_HARD_CAP" ]
}

@test "deny classes: each gate deny carries its prefix and no fail-loud deny borrows one" {
  local r
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
  rm -f "$ALF_ROOT/.gaia/local/runs/$ALF_B/dispositions-2.json"
  printf 'edit\n' >>"$ALF_ROOT/base.txt"
  dispatch
  r="$(reason)"
  git -C "$ALF_ROOT" checkout -q -- base.txt
  cp "$ALF_STATE" "$BATS_TEST_TMPDIR/good"
  printf '{not json' >"$ALF_STATE"
  dispatch
  r="$r"$'\n'"$(reason)"
  cp "$BATS_TEST_TMPDIR/good" "$ALF_STATE"
  mk_slow_git
  GAIA_AUDIT_LOOP_DEADLINE_SECONDS=1 run_payload "$(payload "$M" "$SID" "$ALF_ROOT" "$ALF_ROOT")" "$SLOW"
  r="$r"$'\n'"$(reason)"
  scratch_copy
  rm -f "$SCRATCH_SCRIPTS/context-checkpoint-lib.sh"
  dispatch
  r="$r"$'\n'"$(reason)"
  [ "$(printf '%s\n' "$r" | grep -c '^BLOCKED: ')" -eq 4 ]
  printf '%s\n' "$r" | grep -qE '^BLOCKED: audit (checkpoint|window|dispositions)' && return 1
  printf '%s\n' "$r" | grep -qF -- "Commit the round first"
  printf '%s\n' "$r" | grep -qF -- "invalid JSON"
  printf '%s\n' "$r" | grep -qF -- "internal deadline"
  printf '%s\n' "$r" | grep -qF -- "cannot load its libraries"
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
  mkdir -p "$ALF_ROOT/.gaia/local/runs/$ALF_B"
  printf '{broken' >"$ALF_ROOT/.gaia/local/runs/$ALF_B/vetoes.json"
  unit_dispatch
  deny_prefix "BLOCKED: audit dispositions"
  reason | grep -qF -- "vetoes.json"
}

@test "red state: without the spent-answer view, a main-thread grant of 2 keeps buying trees" {
  fork_mutant 's/view=\$\(answer_view "\$S"\)/view="\$S"/'
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
  local r t0 t1 i
  alf_sequence 6 5 4 3 2 2 1 1 1
  for r in 1 2 3 4 5 6 7 8 9; do
    alf_dispositions "$r" '[]'
  done
  bash "$REPO_ROOT/.gaia/scripts/audit-dispositions-check.sh" check-all --root "$ALF_ROOT" \
    --run-folder "$ALF_ROOT/.gaia/local/runs/$ALF_B" --snapshot-dir "${ALF_STATE%.json}.d"
  [ "$(find "${ALF_STATE%.json}.d" -name 'dispositions-*.checked.json' | wc -l | tr -d ' ')" -eq 9 ]
  below
  for i in 1 2 3 4 5; do
    t0="$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')"
    unit_dispatch
    t1="$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')"
    [ "$status" -eq 0 ]
    printf '# run %s: %s ms\n' "$i" $((t1 - t0)) >&3
    [ $((t1 - t0)) -lt 5000 ]
  done
}
