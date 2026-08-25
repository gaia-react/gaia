#!/usr/bin/env bats
#
# Bats suite for .claude/hooks/token-rollup-merge.sh (UAT-006/007/010, directive 5).
#
# Every test runs the hook with cwd = a tmp git repo, never the real repo
# root: the hook sources gaia-active-plan.sh and shells out to
# token-rollup.sh via repo-relative paths, and the reader resolves the ledger
# via `git rev-parse --git-common-dir`. Running from the real repo would read
# the live .gaia/local/telemetry/cost.jsonl. Each tmp repo gets its own copy
# of the built libs + the real token-rollup.sh at their repo-relative paths
# (build_repo below), matching what a real checkout has.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HOOK_ABS="$REPO_ROOT/.claude/hooks/token-rollup-merge.sh"
  LIB_SRC="$REPO_ROOT/.claude/hooks/lib/gaia-active-plan.sh"
  ROLLUP_SRC="$REPO_ROOT/.gaia/scripts/token-rollup.sh"
  LIB_PRICING_SRC="$REPO_ROOT/.gaia/scripts/token-pricing-lib.sh"
  LIB_LEDGER_SRC="$REPO_ROOT/.gaia/scripts/ledger-path-lib.sh"
  LIB_MAIN_ROOT_SRC="$REPO_ROOT/.gaia/scripts/main-root-lib.sh"
  VERB_ARMING_SRC="$REPO_ROOT/.claude/hooks/lib/verb-arming.sh"
  VERB_ARMING_WALK_SRC="$REPO_ROOT/.claude/hooks/lib/verb-arming-walk.sh"
  REPO_SCOPE_SRC="$REPO_ROOT/.claude/hooks/lib/repo-scope.sh"

  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  return 0
}

# Scaffolds a tmp git repo with the built libs + the real token-rollup.sh
# copied in at their repo-relative paths, preserving the executable bit.
# Sets $REPO.
build_repo() {
  REPO="$("$HELPERS/tmp-git-repo.sh")"
  mkdir -p "$REPO/.claude/hooks/lib" "$REPO/.gaia/scripts"
  cp "$LIB_SRC" "$REPO/.claude/hooks/lib/gaia-active-plan.sh"
  chmod +x "$REPO/.claude/hooks/lib/gaia-active-plan.sh"
  cp "$ROLLUP_SRC" "$REPO/.gaia/scripts/token-rollup.sh"
  chmod +x "$REPO/.gaia/scripts/token-rollup.sh"
  cp "$LIB_PRICING_SRC" "$REPO/.gaia/scripts/token-pricing-lib.sh"
  cp "$LIB_LEDGER_SRC" "$REPO/.gaia/scripts/ledger-path-lib.sh"
  cp "$LIB_MAIN_ROOT_SRC" "$REPO/.gaia/scripts/main-root-lib.sh"
  cp "$VERB_ARMING_SRC" "$REPO/.claude/hooks/lib/verb-arming.sh"
  cp "$VERB_ARMING_WALK_SRC" "$REPO/.claude/hooks/lib/verb-arming-walk.sh"
  cp "$REPO_SCOPE_SRC" "$REPO/.claude/hooks/lib/repo-scope.sh"
}

write_running() {
  # write_running <plan_dir> <branch> <started>
  mkdir -p "$1"
  { printf 'branch: %s\n' "$2"; printf 'slug: %s\n' "$(basename "$1")"; printf 'started: %s\n' "$3"; } > "$1/RUNNING"
}

write_readme_with_spec() {
  # write_readme_with_spec <plan_dir> <spec_path>
  mkdir -p "$1"
  {
    printf '# Plan\n\n'
    printf '## Source SPEC\n\n'
    printf 'Derived from %s (%s).\n' "$(basename "$(dirname "$2")")" "$2"
  } > "$1/README.md"
}

write_readme_spec_less() {
  mkdir -p "$1"
  printf '# Plan\n\nNo source spec here.\n' > "$1/README.md"
}

ledger_path() {
  printf '%s/.gaia/local/telemetry/cost.jsonl' "$REPO"
}

# write_record <action> <spec_id> <session_id> <total> <ts> [<ended_at>]
write_record() {
  local action="$1" spec_id="$2" sid="$3" total="$4" ts="$5"
  local ended="${6:-$ts}"
  mkdir -p "$(dirname "$(ledger_path)")"
  jq -nc --arg kind "$action" --arg spec_id "$spec_id" --arg sid "$sid" \
    --argjson total "$total" --arg ts "$ts" --arg ended "$ended" \
    '{kind:$kind, spec_id:$spec_id, plan_slug:"my-plan", session_id:$sid,
      buckets:{fresh_input:$total, cache_write:0, cache_read:0, output:0},
      total:$total, partial:false, started_at:$ended, ended_at:$ended,
      duration_seconds:10, duration_available:true, ts:$ts}' >> "$(ledger_path)"
}

run_hook() {
  # run_hook <command>
  local cmd="$1" input
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash "$cmd")
  invoke_hook "$input" "$HOOK_ABS"
}

# ---------- 1. Renders spec+plan+execute+Total at merge (UAT-006) ----------
@test "renders the roll-up at merge with spec+plan+execute" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_dir="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-042/SPEC.md"
  write_running "$plan_dir" "$branch" "2026-07-01T00:00:00Z"

  write_record spec SPEC-042 sess-spec 100 "2026-06-01T00:00:00Z"
  write_record plan SPEC-042 sess-plan 200 "2026-06-02T00:00:00Z"
  write_record execute SPEC-042 sess-exec 300 "2026-06-03T00:00:00Z"

  run_hook "gh pr merge 7 --squash"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[cycle cost at merge]"* ]]
  [[ "$output" == *"Cycle cost (SPEC-042)"* ]]
  [[ "$output" == *"spec:"* ]]
  [[ "$output" == *"plan:"* ]]
  [[ "$output" == *"execute:"* ]]
  [[ "$output" == *"Total:"* ]]
  [[ "$output" == *"600"* ]]
  # SPEC-019: this synthetic repo carries no committed token-rates.json (see
  # build_repo above), so --show-toplevel resolves to a rate table that
  # doesn't exist here and rate_table_ok=false wins FC-4 precedence -- the
  # dollar block renders "unavailable (rate table unreadable)", not "records
  # predate per-model attribution" (unreachable in this scaffold). Assert only
  # the header substring: marker-agnostic, robust to either degrade form.
  [[ "$output" == *"Est. cost (USD):"* ]]
}

# Spec-derived plans colocate at specs/<SPEC-ID>/plan[-N] rather than
# plans/<slug>. The merge-readout hook's PRIMARY path resolves the feature key
# from the active plan folder via the shared resolver, whose union globs cover
# the colocated location. This proves the readout keys off the colocated plan
# folder itself (not the ledger fallback) and renders the full cycle.
@test "colocated spec plan (specs/<id>/plan) resolves the merge readout key" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_dir="$REPO/.gaia/local/specs/SPEC-042/plan"
  write_readme_with_spec "$plan_dir" ".gaia/local/specs/SPEC-042/SPEC.md"
  write_running "$plan_dir" "$branch" "2026-07-01T00:00:00Z"

  write_record spec SPEC-042 sess-spec 100 "2026-06-01T00:00:00Z"
  write_record plan SPEC-042 sess-plan 200 "2026-06-02T00:00:00Z"
  write_record execute SPEC-042 sess-exec 300 "2026-06-03T00:00:00Z"

  run_hook "gh pr merge 7 --squash"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[cycle cost at merge]"* ]]
  [[ "$output" == *"Cycle cost (SPEC-042)"* ]]
  # Resolved via the colocated active plan folder, NOT the ledger fallback.
  [[ "$output" != *"resolved from the ledger"* ]]
  [[ "$output" == *"600"* ]]
}

# UAT-007
@test "spec-less plan omits the spec line" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_dir="$REPO/.gaia/local/plans/spec-less-plan"
  write_readme_spec_less "$plan_dir"
  write_running "$plan_dir" "$branch" "2026-07-01T00:00:00Z"

  write_record plan spec-less-plan sess-plan 150 "2026-06-02T00:00:00Z"
  write_record execute spec-less-plan sess-exec 250 "2026-06-03T00:00:00Z"

  run_hook "gh pr merge"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[cycle cost at merge]"* ]]
  [[ "$output" != *"spec:"* ]]
  [[ "$output" == *"plan:"* ]]
  [[ "$output" == *"execute:"* ]]
  [[ "$output" == *"Total:"* ]]
  [[ "$output" == *"400"* ]]
}

# ---------- 3. Fresh session, no plan folder -> ledger fallback (directive 5) ----------
@test "fresh session with no active plan folder falls back to the ledger and labels itself" {
  build_repo
  cd "$REPO"
  # No plan folder at all: this is the fresh-top-level-session case.
  write_record execute SPEC-042 sess-exec 300 "2026-06-03T00:00:00Z"

  run_hook "gh pr merge"
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolved from the ledger"* ]]
  [[ "$output" == *"Cycle cost (SPEC-042)"* ]]
  [[ "$output" == *"execute:"* ]]
  [[ "$output" == *"300"* ]]
}

@test "fallback picks the execute record with the latest ts" {
  build_repo
  cd "$REPO"
  write_record execute SPEC-001 sess-a 100 "2026-06-01T00:00:00Z"
  write_record execute SPEC-002 sess-b 200 "2026-06-05T00:00:00Z"

  run_hook "gh pr merge"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cycle cost (SPEC-002)"* ]]
  [[ "$output" != *"Cycle cost (SPEC-001)"* ]]
}

@test "active plan folder wins over a newer unrelated feature's execute row" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_dir="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-042/SPEC.md"
  write_running "$plan_dir" "$branch" "2026-07-01T00:00:00Z"

  # SPEC-042's own (older) execute record.
  write_record execute SPEC-042 sess-a 300 "2026-06-01T00:00:00Z"
  # A globally newer execute row for an unrelated, interleaved feature.
  write_record execute SPEC-999 sess-b 999 "2026-06-09T00:00:00Z"

  run_hook "gh pr merge"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cycle cost (SPEC-042)"* ]]
  [[ "$output" != *"Cycle cost (SPEC-999)"* ]]
  [[ "$output" != *"resolved from the ledger"* ]]
}

# ---------- 6. Non-merge command: silent ----------
@test "non-merge git command: silent" {
  build_repo
  cd "$REPO"
  run_hook "git commit -m x"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "gh pr view is not a merge: silent" {
  build_repo
  cd "$REPO"
  run_hook "gh pr view 7"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- 7. Corrupt / missing ledger never blocks (UAT-010) ----------
@test "corrupt ledger line does not block; the good execute record still renders" {
  build_repo
  cd "$REPO"
  write_record execute SPEC-042 sess-a 300 "2026-06-01T00:00:00Z"
  echo 'not-json-garbage' >> "$(ledger_path)"

  run_hook "gh pr merge"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cycle cost (SPEC-042)"* ]]
  [[ "$output" == *"execute:"* ]]
}

@test "no active plan folder and no ledger at all: exit 0, empty stdout" {
  build_repo
  cd "$REPO"
  # No plan folder, no ledger file: nothing to resolve a feature key from.
  run_hook "gh pr merge"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- 8. Heredoc / quoted-string false-match guard ----------
@test "gh pr merge mentioned only inside heredoc body prose: not matched" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_dir="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-042/SPEC.md"
  write_running "$plan_dir" "$branch" "2026-07-01T00:00:00Z"
  write_record execute SPEC-042 sess-a 300 "2026-06-01T00:00:00Z"

  heredoc_cmd=$'cat <<EOF\nPlease remember to gh pr merge later.\nEOF'
  run_hook "$heredoc_cmd"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "gh pr merge mentioned inside a quoted string: not matched" {
  build_repo
  cd "$REPO"
  run_hook 'echo "remember to gh pr merge later"'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- Shared arming decision: readout / no readout / readout ----------
#
# UAT-010's `then` says the positive control renders "and the other two emit
# none", the other two being the heredoc-body payload and the past-bound
# payload. UAT-005 requires the past-bound call to arm and deny (for the
# deny-capable siblings) or, here, to arm and render, because the SPEC's own
# identity-above-bound rule says the view past GAIA_VERB_ARM_MAX_CHARS is the
# identity and the raw match stands. UAT-005 and the identity rule win;
# UAT-010's "other two" clause is superseded as to the past-bound half only.
# See plan/README.md, "Where UAT-010 and UAT-005 conflict, and which wins".
@test "seeded positive control renders, the heredoc-body payload does not, and the past-bound payload renders again" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_dir="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-042/SPEC.md"
  write_running "$plan_dir" "$branch" "2026-07-01T00:00:00Z"
  write_record spec SPEC-042 sess-spec 100 "2026-06-01T00:00:00Z"
  write_record plan SPEC-042 sess-plan 200 "2026-06-02T00:00:00Z"
  write_record execute SPEC-042 sess-exec 300 "2026-06-03T00:00:00Z"

  # 1. Positive control: renders.
  run_hook "gh pr merge 7 --squash"
  [ "$status" -eq 0 ]
  grep -qF -- "[cycle cost at merge]" <<<"$output" || return 1

  # 2. Heredoc-body payload (cat-to-file, proven data): no readout.
  heredoc_cmd=$'cat > /tmp/notes.txt <<EOF\ngh pr merge 7\nEOF'
  run_hook "$heredoc_cmd"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # 3. The same heredoc-body payload padded past the arming bound: renders
  # again. The walker abstains above GAIA_VERB_ARM_MAX_CHARS, so the raw
  # match stands unmasked.
  local pad over_cmd
  pad=$(printf 'x%.0s' $(seq 1 16400))
  over_cmd=$'cat > /tmp/notes.txt <<EOF\n'"$pad"$'\ngh pr merge 7\nEOF'
  [ "${#over_cmd}" -gt 16384 ] || return 1
  run_hook "$over_cmd"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[cycle cost at merge]"* ]]
}

@test "a quoted verb in the first command renders (tokenizer arm; red before this change)" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_dir="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-042/SPEC.md"
  write_running "$plan_dir" "$branch" "2026-07-01T00:00:00Z"
  write_record execute SPEC-042 sess-exec 300 "2026-06-03T00:00:00Z"

  run_hook 'gh pr "merge" 7'
  [ "$status" -eq 0 ]
  [[ "$output" == *"[cycle cost at merge]"* ]]
}

@test "a multi-statement command still renders (no regression)" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_dir="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-042/SPEC.md"
  write_running "$plan_dir" "$branch" "2026-07-01T00:00:00Z"
  write_record execute SPEC-042 sess-exec 300 "2026-06-03T00:00:00Z"

  run_hook "echo start && gh pr merge 7"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[cycle cost at merge]"* ]]
}

# ---------- 9. Renders regardless of the merge subprocess's own exit ----------
@test "renders even when tool_response reports a failed merge" {
  build_repo
  cd "$REPO"
  branch="$(git branch --show-current)"
  plan_dir="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-042/SPEC.md"
  write_running "$plan_dir" "$branch" "2026-07-01T00:00:00Z"
  write_record execute SPEC-042 sess-a 300 "2026-06-01T00:00:00Z"

  input=$(jq -n --arg sid "S1" --arg cmd "gh pr merge 7 --squash" \
    '{session_id:$sid, transcript_path:"/tmp/t.jsonl", cwd:".", hook_event_name:"PostToolUse",
      tool_name:"Bash", tool_input:{command:$cmd},
      tool_response:{stdout:"", stderr:"merge failed", exit_code:1, interrupted:false}}')
  invoke_hook "$input" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cycle cost (SPEC-042)"* ]]
}

@test "the hook file is executable" {
  [ -x "$HOOK_ABS" ]
}

# ---------- library-load degradation (gaia-react/gaia#1556) ----------
# Two ways a library goes unusable, and this hook must render nothing and exit
# 0 through both: it is gone, and it is present but does not parse (an
# unresolved merge conflict, a truncated write). Under `set -e` a failed `.`
# abandons the shell ahead of the ERR trap in both cases; a file bash cannot
# open exits 1, one it cannot parse exits 2.
#
# The loads sit on opposite sides of the arming gate and take different
# repairs, so each gets its own case. gaia-active-plan.sh is past the gate and
# parse-checks; verb-arming.sh runs on every Bash tool call and parse-checks
# too, once the cost figure that argued for a cheaper arm failed to reproduce
# (~3.1ms on 3.2.57, ~5.7ms on 5.3.15), so both halves of the unparseable case
# are closed for both loads.

# Overwrites <path> with an unresolved-merge-conflict body: the file opens and
# reads fine, so an existence test passes it, and bash cannot parse it.
write_conflicted_lib() {
  { printf '<<<<<<< HEAD\n'; printf 'x() { :; }\n'; printf '=======\n'
    printf 'y() { :; }\n'; printf '>>>>>>> other\n'; } > "$1"
}

# The verb-arming load resolves off the hook's own BASH_SOURCE, so corrupting
# it needs a COPY of the hook staged inside the tmp repo. $HOOK_ABS would
# always reach the real checkout's lib, where the case cannot be expressed.
stage_hook_repo() {
  build_repo
  STAGED_HOOK="$REPO/.claude/hooks/token-rollup-merge.sh"
  cp "$HOOK_ABS" "$STAGED_HOOK"
  chmod +x "$STAGED_HOOK"
}

# run_staged_hook <command> [interpreter]
run_staged_hook() {
  local input interp="${2:-bash}"
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash "$1")
  run bash -c 'printf %s "$1" | "$3" "$2"' _ "$input" "$STAGED_HOOK" "$interp"
}

# Scaffolds the staged repo with the plan folder + ledger rows every case below
# shares, so the control has something real to render.
stage_with_cycle() {
  stage_hook_repo
  cd "$REPO" || return 1
  local branch plan_dir
  branch="$(git branch --show-current)"
  plan_dir="$REPO/.gaia/local/plans/my-plan"
  write_readme_with_spec "$plan_dir" "/abs/root/.gaia/local/specs/SPEC-042/SPEC.md"
  write_running "$plan_dir" "$branch" "2026-07-01T00:00:00Z"
  write_record spec SPEC-042 sess-spec 100 "2026-06-01T00:00:00Z"
  write_record plan SPEC-042 sess-plan 200 "2026-06-02T00:00:00Z"
  write_record execute SPEC-042 sess-exec 300 "2026-06-03T00:00:00Z"
}

# The control that gives the two cases teeth: their assertions (exit 0, no
# output) are equally satisfied by a hook that does nothing at all, so the same
# staging has to be shown rendering normally first.
@test "staged hook, every lib usable: renders the roll-up (control)" {
  stage_with_cycle

  run_staged_hook "gh pr merge 7 --squash"
  [ "$status" -eq 0 ]
  grep -qF -- "Cycle cost (SPEC-042)" <<<"$output"
}

# The stock-/bin/bash control, and it is not redundant with the control above.
# Every pinned case in this suite asserts only exit 0, no output, and no
# artifact, which a hook that does nothing at all under 3.2 satisfies just as
# well as a hook that degrades correctly. Without a control on the SAME
# interpreter proving the normal path still works there, the pinned cases
# cannot separate the repair from total inertness on the one shell they exist
# to exercise. Proved hollow before adding this: inserting an early
# `BASH_VERSINFO -lt 4` exit into the hook left this suite entirely green.
@test "staged hook under stock /bin/bash, every lib usable: renders the roll-up (control)" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  stage_with_cycle

  run_staged_hook "gh pr merge 7 --squash" /bin/bash
  [ "$status" -eq 0 ]
  grep -qF -- "Cycle cost (SPEC-042)" <<<"$output"
}

# Unpinned on purpose: the form this load replaced was a bare `.` inside an
# `-f` test, carrying no arm at all, so it dies on bash 5 as well as 3.2 and
# this case has teeth on Linux CI.
#
# The assertion is the LEDGER FALLBACK, not silence, and the difference is the
# repair's whole point. An unusable plan-folder lib is the same situation as no
# active plan folder, so the hook degrades one step sideways into the fallback
# rather than out of the hook entirely; the control above proves the primary
# path renders unlabeled from the same fixture, so the label is what separates
# the two. Asserting silence here would have pinned a hook that loses the
# roll-up whenever the lib is unusable, which is a worse contract than the one
# this change is repairing.
@test "gaia-active-plan.sh holds conflict markers: exit 0, renders via the ledger fallback" {
  stage_with_cycle
  write_conflicted_lib "$REPO/.claude/hooks/lib/gaia-active-plan.sh"

  run_staged_hook "gh pr merge 7 --squash"
  [ "$status" -eq 0 ]
  grep -qF -- "no active plan folder was found" <<<"$output"
}

# The fallback's own lib, past the gate and parse-checked for the same reason.
# With both libs unusable there is nothing left to key on, so the hook renders
# nothing at all -- the silence the case above deliberately does not assert.
@test "both gaia-active-plan.sh and ledger-path-lib.sh hold conflict markers: exit 0, renders nothing" {
  stage_with_cycle
  write_conflicted_lib "$REPO/.claude/hooks/lib/gaia-active-plan.sh"
  write_conflicted_lib "$REPO/.gaia/scripts/ledger-path-lib.sh"

  run_staged_hook "gh pr merge 7 --squash"
  [ "$status" -eq 0 ]
  grep -qF -- "cycle cost at merge" <<<"$output" && return 1
  return 0
}

# The pre-gate verb-arming load parse-checks, so BOTH halves of the unparseable
# case are closed and the pair below says so: unpinned for the bash 5 half, and
# pinned to /bin/bash for the 3.2 half that the `{ . lib || true; }` arm this
# load first carried would have left open. Both have teeth: the bare source the
# arm replaced dies on bash 5, and the arm itself dies on 3.2, so each case reds
# against the spelling it supersedes.
@test "verb-arming.sh holds conflict markers: exit 0, renders nothing" {
  stage_with_cycle
  write_conflicted_lib "$REPO/.claude/hooks/lib/verb-arming.sh"

  run_staged_hook "gh pr merge 7 --squash"
  [ "$status" -eq 0 ]
  grep -qF -- "Cycle cost" <<<"$output" && return 1
  return 0
}

@test "verb-arming.sh holds conflict markers, under stock /bin/bash: exit 0, renders nothing" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  stage_with_cycle
  write_conflicted_lib "$REPO/.claude/hooks/lib/verb-arming.sh"

  run_staged_hook "gh pr merge 7 --squash" /bin/bash
  [ "$status" -eq 0 ]
  grep -qF -- "Cycle cost" <<<"$output" && return 1
  return 0
}
