#!/usr/bin/env bats

# Cost budget for the shared verb-arming decision (.claude/hooks/lib/verb-arming.sh,
# .claude/hooks/lib/verb-arming-walk.sh). SPEC-075 deliberately deferred the
# per-call number to this plan; this file is the record that closes that
# deferral, per the plan's task-cost-budget.md.
#
# STATED BUDGET (machine: Apple Silicon macOS; bash 3.2.57 stock /bin/bash and
# bash 5.3.15 Homebrew; figures are per-hook-process wall time, median of a
# few runs, at the sizes the arming scan actually sees):
#
#   size    one hook, raw-matching   one hook, non-matching
#   200B    ~19-21ms                 ~16-20ms
#   2KB     ~21-23ms                 ~16-19ms
#   8KB     ~27ms                    ~16-19ms
#   16KB    ~32-38ms                 ~16-20ms
#   32KB (past bound, one hook)      ~25-32ms (identity short-circuit)
#
#   gaia_verb_arm_view alone (library call, no hook process): 16KB ~8-12ms,
#   32KB past-bound ~1-3ms (bash 3.2, the slow host this budget is written for).
#
#   Eleven hooks, one tool call: a 200-character ordinary `git commit` totals
#   ~200-230ms; a 16KB raw-matching `gh pr merge` (8 of 11 hooks pay the walk,
#   3 raw-miss and skip it) totals ~300-345ms.
#
# The audit's own two reference points (plan-time directive, PERF-007): about
# 0.06s span-skipping against about 1.01s byte-walking, PER HOOK, at 16KB on
# stock bash 3.2. Every ceiling below is set against those two figures, not
# against this machine's numbers, so a shared runner being slow cannot red a
# ceiling and only losing the span-skip bound can. Each ceiling states its own
# headroom (over the measured figures above) and margin (below the 1.01s/hook
# byte-walk figure, scaled to how many hooks or how much size a given ceiling
# covers) in its own comment, per acceptance criterion 3.
#
# WHY "ONE HOOK PROCESS" MEANS pr-merge-audit-check.sh FOR THE SIZE SWEEP, and
# token-tally-git-op.sh FOR THE PAST-BOUND CASE. A payload that raw-matches
# and stays masked (the common shape below) never reaches a hook's own
# post-arming logic at all, so which hook is swept barely matters there.
# A GENUINELY ARMED large payload is a different story: pr-merge-audit-check.sh
# calls into repo-scope.sh's `cmd_targets_foreign_repo`, an existing scanner
# unrelated to this SPEC, whose own cost on a large armed command is NOT
# bounded the way the arming walk is (measured 1.2-3.4s on a 32KB armed
# command here, regardless of shape) -- a pre-existing cost issue in a
# different file, filed separately as tech debt, not something this budget
# owns or should let leak into its own ceiling. token-tally-git-op.sh has no
# repo-scope check on its arming path, so it isolates the past-bound case to
# what this budget actually measures: the arming library's own cost.
#
# WHY THE "RAW-MATCHING" PAYLOAD IS A cat-HEREDOC. Per Phase 1's own figure
# (~9ms per gaia_verb_arm_view call on a 16,259-character worst-case `cat`
# heredoc payload), the walk is paid only when the RAW match hits, and the raw
# match hitting on a payload with no `<<` at all costs nothing extra: the
# walker's very first check is "does this text contain `<<` anywhere", and it
# returns immediately when it does not. A plain `gh pr merge 1` padded with
# trailing characters raw-matches at the very start and never reaches that
# check meaningfully at any size, so it would NOT exercise the class this
# budget exists to pin. The heredoc-body shape below -- `cat <<'ZZEOF' > file`
# with the verb on its own line inside the body -- is what a real
# false-arming tool call looks like (a commit whose message or a written file
# happens to carry the verb text), it raw-matches via the separator arm, it
# forces the walk, and BELOW the character bound it ends up correctly
# unarmed once the walker proves the body is data. That "ends up unarmed"
# property is also what keeps this fixture cheap and hook-agnostic: the hook
# takes its normal not-armed fast exit right after the arming call, so no
# fixture here needs the audit-clearance/resolver machinery real merges need.

bats_require_minimum_version 1.5.0

setup() {
  HOOKS_DIR=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)

  REPO=$(mktemp -d -t verb-arming-cost-XXXXXX)
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false
  mkdir -p "$REPO/wiki"
  echo "# wiki" > "$REPO/wiki/index.md"
  git -C "$REPO" add wiki/index.md
  git -C "$REPO" commit --quiet -m init

  GH_BIN="$REPO/.ghbin"
  mkdir -p "$GH_BIN"
  cat > "$GH_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$1" in
  auth) exit 0 ;;
  repo) printf 'gaia-react/gaia\n'; exit 0 ;;
  pr) printf '{"title":"","baseRefName":"","number":"30","state":"MERGED","isCrossRepository":false,"author":{"login":"bot"}}\n'; exit 0 ;;
  issue) printf '[]\n'; exit 0 ;;
  api) printf 'null\n'; exit 0 ;;
  *) exit 0 ;;
esac
GHEOF
  chmod +x "$GH_BIN/gh"

  # A documented test seam (token-tally-review.sh, token-tally-git-op.sh):
  # points the ledger/transcript scan at an empty tree instead of this
  # machine's real ~/.claude/projects, which would make timing depend on
  # however much real session history happens to be on disk.
  TALLY_ROOT="$REPO/.tally-empty"
  mkdir -p "$TALLY_ROOT"

  # token-tally-git-op.sh sources this ONE lib cwd-relatively rather than off
  # its own BASH_SOURCE, unguarded by an `-f` check: on an armed call, a cwd
  # that lacks it makes the hook exit 1 with a "No such file" error instead
  # of its own documented degrade-silently contract (a pre-existing gap,
  # unrelated to the arming decision this file budgets, filed separately as
  # tech debt rather than fixed here). Staging the real file at the cwd path
  # it expects keeps this fixture on the hook's normal fast-exit path instead
  # of tripping that gap.
  mkdir -p "$REPO/.claude/hooks/lib"
  cp "$HOOKS_DIR/lib/gaia-active-plan.sh" "$REPO/.claude/hooks/lib/gaia-active-plan.sh"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  return 0
}

# ---------------------------------------------------------------------------
# Payload builders
# ---------------------------------------------------------------------------

# A same-length "cat <<'ZZEOF' > file" heredoc body carrying VERB on its own
# line, padded with 'y' filler to exactly TOTAL characters (best-effort at the
# smallest sizes, where the fixed overhead dominates). Raw-matches via the
# separator arm (the newline ahead of VERB), pays for the walk, and -- below
# GAIA_VERB_ARM_MAX_CHARS -- ends up correctly unarmed once the body is
# proven data.
build_armed_payload() {
  local verb="$1" total="$2"
  local opener=$'cat <<'"'"'ZZEOF'"'"' > /tmp/gaia-va-cost.out\n'
  local closer=$'\nZZEOF\n'
  local fixed=$(( ${#opener} + ${#closer} + ${#verb} + 2 ))
  local pad=$(( total - fixed ))
  [ "$pad" -lt 0 ] && pad=0
  local half=$(( pad / 2 )) rest fillA fillB
  rest=$(( pad - half ))
  fillA=$(head -c "$half" < /dev/zero | tr '\0' 'y')
  fillB=$(head -c "$rest" < /dev/zero | tr '\0' 'y')
  printf '%s%s\n%s\n%s%s' "$opener" "$fillA" "$verb" "$fillB" "$closer"
}

# A payload that raw-matches nothing: the raw match never hits, so the walk
# is never paid regardless of size. 'echo ' is turned away by every one of
# the eleven hooks' tokenizer pre-filters too (no verb fragment's first word
# starts with 'e').
build_nonmatch_payload() {
  local total="$1" prefix='echo '
  local n=$(( total - ${#prefix} ))
  [ "$n" -lt 0 ] && n=0
  printf '%s%s' "$prefix" "$(head -c "$n" < /dev/zero | tr '\0' 'x')"
}

# A plain (non-heredoc) armed payload: raw-matches at the very start, so it
# never reaches the walker's "does this contain <<" check meaningfully. Used
# only for the past-bound case, where the point is that the bound short-
# circuits BEFORE the walker does any real work at all.
build_plain_armed_payload() {
  local verb="$1" total="$2"
  local n=$(( total - ${#verb} - 1 ))
  [ "$n" -lt 0 ] && n=0
  printf '%s %s' "$verb" "$(head -c "$n" < /dev/zero | tr '\0' 'y')"
}

# ---------------------------------------------------------------------------
# Timing helpers
# ---------------------------------------------------------------------------

# Writes a PreToolUse Bash JSON envelope for CMD to a tmp file and prints its
# path. --rawfile keeps this argv-free for a 16-32KB payload, unlike --arg.
json_envelope_for() {
  local cmd="$1" cmdfile jsonfile
  cmdfile=$(mktemp)
  jsonfile=$(mktemp)
  printf '%s' "$cmd" > "$cmdfile"
  jq -n --rawfile c "$cmdfile" \
    '{tool_name:"Bash", tool_input:{command:$c}, tool_response:{stdout:"",stderr:"",interrupted:false}, hook_event_name:"PreToolUse", session_id:"cost-budget", stop_hook_active:false}' \
    > "$jsonfile"
  rm -f "$cmdfile"
  printf '%s' "$jsonfile"
}

# Runs HOOK against CMD's JSON envelope from $REPO, with the gh stub on PATH,
# and sets REPLY_MS to the elapsed wall time in milliseconds. Uses bash's own
# `time` reserved word plus TIMEFORMAT, a builtin with millisecond-plus
# resolution on every bash version: nothing here depends on a GNU-only or
# BSD-only `date` flag (acceptance criterion 5), unlike `date +%s%N` (GNU
# only) or `date -v`/`date -d` (BSD/GNU split).
time_hook_ms() {
  local hook="$1" cmd="$2" jsonfile t
  jsonfile=$(json_envelope_for "$cmd")
  t=$(
    cd "$REPO" || exit 1
    PATH="$GH_BIN:$PATH"
    export GAIA_TALLY_PROJECTS_ROOT="$TALLY_ROOT"
    TIMEFORMAT='%R'
    { time bash "$hook" < "$jsonfile" >/dev/null 2>&1; } 2>&1
  )
  rm -f "$jsonfile"
  REPLY_MS=$(awk -v s="$t" 'BEGIN{printf "%d", (s*1000)+0.5}')
}

# Same as gaia_verb_arm_view (loaded fresh each call), timed directly with no
# hook process around it. Isolates the walker's own cost from a hook's fixed
# per-process overhead (bash startup, jq parse, git calls).
time_view_ms() {
  local text="$1" lib walk t
  lib=$(cd "$HOOKS_DIR/lib" && pwd)/verb-arming.sh
  walk=$(cd "$HOOKS_DIR/lib" && pwd)/verb-arming-walk.sh
  t=$(bash -c '
    TIMEFORMAT="%R"
    . "$1"
    . "$2"
    { time gaia_verb_arm_view "$3" >/dev/null; } 2>&1
  ' _ "$lib" "$walk" "$text")
  REPLY_MS=$(awk -v s="$t" 'BEGIN{printf "%d", (s*1000)+0.5}')
}

# The eleven adopting hooks, per README.md's frozen contract table.
eleven_hooks() {
  printf '%s\n' \
    pr-merge-audit-check.sh \
    worthiness-presence-check.sh \
    audit-disposition-check.sh \
    distribution-preflight-check.sh \
    post-findings-block-on-merge.sh \
    token-tally-git-op.sh \
    token-tally-review.sh \
    token-rollup-merge.sh \
    issue-claim-release.sh \
    debt-sentinel-touch.sh \
    capture-gh-artifact.sh
}

# ---------------------------------------------------------------------------
# Ceilings. Each states its measured baseline, its headroom over that
# baseline, and its margin below the audit's ~1.01s-per-hook byte-walking
# figure (scaled per ceiling), per acceptance criterion 3.
# ---------------------------------------------------------------------------

# One hook, raw-matching heredoc payload, up to 16KB. Measured max ~38ms.
# Headroom: 300/38 ~= 7.9x. Margin below the 1010ms byte-walk failure mode:
# 1010/300 ~= 3.4x.
CEILING_ONE_HOOK_RAWMATCH_MS=300

# One hook, non-matching payload, any size: the raw match never hits, so
# this should stay near baseline (~16-21ms measured) regardless of size.
# Headroom: 150/21 ~= 7.1x. Margin below the failure this catches (the
# raw-match gate breaking so a non-matching payload takes the armed path
# instead, which for several hooks is a >1s cost class, not just the 1010ms
# byte-walk figure): 1010/150 ~= 6.7x, conservatively.
CEILING_ONE_HOOK_NONMATCH_MS=150

# Eleven hooks, one 200-character ordinary `git commit` tool call. Measured
# ~220ms. Headroom: 1000/220 ~= 4.5x. Margin below eleven hooks each paying
# the 1010ms byte-walk figure (the "walk gets paid unconditionally" failure
# this also guards against): 11110/1000 ~= 11.1x.
CEILING_ELEVEN_ORDINARY_MS=1000

# Eleven hooks, one 16KB raw-matching `gh pr merge` tool call (8 of 11 pay
# the walk; 3 raw-miss and skip it). Measured ~300-345ms. Headroom:
# 2000/345 ~= 5.8x. Margin below 8 hooks each byte-walking at 1010ms:
# 8080/2000 ~= 4.0x.
CEILING_ELEVEN_RAWMATCH_MS=2000

# Past-bound (32KB), one hook (token-tally-git-op.sh), armed for real: the
# walker's length check must short-circuit before it does any real work, so
# this should cost about what an unmatched payload costs (measured
# ~25-71ms across runs). Headroom: 300/71 ~= 4.2x. Margin below a
# conservative doubling of the 16KB byte-walk figure for a 32KB unbounded
# walk (2020ms): 2020/300 ~= 6.7x.
CEILING_PAST_BOUND_MS=300

# gaia_verb_arm_view alone, 256KB, well past the bound: the length check must
# short-circuit before any real work, so this should cost about what the
# 16KB view call costs (measured ~6-21ms), not what actually walking 256KB
# costs. A 256KB single-heredoc payload is chosen (rather than the smaller
# 32KB above) because the separation is what makes this ceiling ROBUST rather
# than borderline: measured identity cost at this size is ~6-21ms, while
# measured real-walk cost at this size (GAIA_VERB_ARM_MAX_CHARS raised past
# it) is ~760ms on bash 3.2 -- a ~36x gap, wide enough that ordinary run-to-
# run jitter cannot cross it by accident. Headroom: 150/21 ~= 7.1x. Margin
# below the measured real-walk failure mode (760ms): 760/150 ~= 5.1x. This is
# the ceiling that demonstrably reds when GAIA_VERB_ARM_MAX_CHARS is removed
# or raised past this payload's size (see the plan's red-first discipline;
# proven by hand, not committed as a self-mutating test).
CEILING_VIEW_PAST_BOUND_MS=150

# gaia_verb_arm_view alone, 16KB, no hook process around it. Measured
# ~8-12ms on bash 3.2. Headroom: 100/12 ~= 8.3x. Margin below 1010ms:
# 1010/100 = 10.1x.
CEILING_VIEW_16K_MS=100

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "cost: gaia_verb_arm_view alone stays inside the span-skipping ceiling at 16KB" {
  local p
  p=$(build_armed_payload "gh pr merge 1" 16384)
  time_view_ms "$p"
  echo "gaia_verb_arm_view at 16KB: ${REPLY_MS}ms (ceiling ${CEILING_VIEW_16K_MS}ms)" >&2
  [ "$REPLY_MS" -le "$CEILING_VIEW_16K_MS" ]
}

@test "cost: a raw-matching payload's per-hook cost stays inside the span-skipping envelope, 200B through 16KB" {
  local sz p
  for sz in 200 2048 8192 16384; do
    p=$(build_armed_payload "gh pr merge 1" "$sz")
    time_hook_ms "$HOOKS_DIR/pr-merge-audit-check.sh" "$p"
    echo "raw-matching size=$sz: ${REPLY_MS}ms (ceiling ${CEILING_ONE_HOOK_RAWMATCH_MS}ms)" >&2
    [ "$REPLY_MS" -le "$CEILING_ONE_HOOK_RAWMATCH_MS" ]
  done
}

@test "cost: a non-matching payload never pays the walk, 200B through 16KB" {
  local sz p
  for sz in 200 2048 8192 16384; do
    p=$(build_nonmatch_payload "$sz")
    time_hook_ms "$HOOKS_DIR/pr-merge-audit-check.sh" "$p"
    echo "non-matching size=$sz: ${REPLY_MS}ms (ceiling ${CEILING_ONE_HOOK_NONMATCH_MS}ms)" >&2
    [ "$REPLY_MS" -le "$CEILING_ONE_HOOK_NONMATCH_MS" ]
  done
}

@test "cost: a payload past the character bound costs about what an unmatched payload costs" {
  local hook="$HOOKS_DIR/token-tally-git-op.sh"
  local armed nonmatch
  armed=$(build_plain_armed_payload "git commit -m x" 32768)
  nonmatch=$(build_nonmatch_payload 32768)

  time_hook_ms "$hook" "$armed"
  local armed_ms="$REPLY_MS"
  time_hook_ms "$hook" "$nonmatch"
  local nonmatch_ms="$REPLY_MS"

  echo "past-bound armed (32KB): ${armed_ms}ms; non-matching (32KB): ${nonmatch_ms}ms (ceiling ${CEILING_PAST_BOUND_MS}ms)" >&2
  [ "$armed_ms" -le "$CEILING_PAST_BOUND_MS" ]
  [ "$nonmatch_ms" -le "$CEILING_PAST_BOUND_MS" ]
}

@test "cost: gaia_verb_arm_view past the bound costs about what identity costs, not what a real walk costs" {
  # 256KB, not 32KB: see CEILING_VIEW_PAST_BOUND_MS's comment for why the
  # larger size is what makes this assertion able to actually red rather
  # than merely pass.
  local p
  p=$(build_armed_payload "gh pr merge 1" 262144)
  time_view_ms "$p"
  echo "gaia_verb_arm_view past bound (256KB): ${REPLY_MS}ms (ceiling ${CEILING_VIEW_PAST_BOUND_MS}ms)" >&2
  [ "$REPLY_MS" -le "$CEILING_VIEW_PAST_BOUND_MS" ]
}

@test "cost: eleven hooks process one ordinary 200-byte git-commit tool call within budget" {
  local cmd
  cmd="git commit -m x $(head -c 180 < /dev/zero | tr '\0' 'y')"
  local total=0 h
  while IFS= read -r h; do
    time_hook_ms "$HOOKS_DIR/$h" "$cmd"
    total=$(( total + REPLY_MS ))
  done < <(eleven_hooks)
  echo "eleven-process total, 200B ordinary git commit: ${total}ms (ceiling ${CEILING_ELEVEN_ORDINARY_MS}ms)" >&2
  [ "$total" -le "$CEILING_ELEVEN_ORDINARY_MS" ]
}

@test "cost: eleven hooks process one 16KB raw-matching gh-pr-merge tool call within budget" {
  local cmd
  cmd=$(build_armed_payload "gh pr merge 1" 16384)
  local total=0 h
  while IFS= read -r h; do
    time_hook_ms "$HOOKS_DIR/$h" "$cmd"
    total=$(( total + REPLY_MS ))
  done < <(eleven_hooks)
  echo "eleven-process total, 16KB raw-matching gh pr merge: ${total}ms (ceiling ${CEILING_ELEVEN_RAWMATCH_MS}ms)" >&2
  [ "$total" -le "$CEILING_ELEVEN_RAWMATCH_MS" ]
}
