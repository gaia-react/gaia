#!/usr/bin/env bats
#
# usage-flush.sh: transcript usage into usage.jsonl segment, binding, and
# cursor rows, counted once at final value (SPEC-087 success criteria 1-2).
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/usage-flush.bats
#
# Every total is compared by summing kind=="segment" rows with plain jq against
# the scenario's golden.json, whose literals were added up by hand from the
# fixture lines (message factor k: fresh k, 5m write 10k, 1h write 100k, cache
# read 1000k, output as written). Fixture paths and cwd values carry @ROOT@
# (the tmp repo), @MAIN@ (its projects-dir encoding), and @SIB@ placeholders.

bats_require_minimum_version 1.5.0

setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FLUSH="$SCRIPTS/usage-flush.sh"
  FIXTURES_DIRECTORY="$BATS_TEST_DIRNAME/fixtures/usage/flush"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export GAIA_RATES_FEED_DISABLE=1 GAIA_RATES_STATE_DIRECTORY="$TEMPORARY_DIRECTORY/rates-state"
  unset GITHUB_ACTIONS GAIA_USAGE_TEST_BARRIER GAIA_USAGE_DEBUG_HOLD GAIA_TALLY_PROJECTS_ROOT
  unset GAIA_LEDGER_LOCK_FORCE_FALLBACK GAIA_LEDGER_LOCK_TIMEOUT_SECONDS
  use_repo "$TEMPORARY_DIRECTORY/repo"
}

# ---------- helpers ----------

make_repo() {
  mkdir -p "$1"
  git -C "$1" init -q -b "${2:-main}"
  git -C "$1" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false \
    commit -q --allow-empty -m init
}

# use_repo <dir> [branch]: a fresh repo as ROOT, with PROJECTS_DIRECTORY and TEL beside it.
use_repo() {
  make_repo "$1" "${2:-main}"
  ROOT="$1"
  PROJECTS_DIRECTORY="${1%/*}/projects-${1##*/}"
  TEL="$ROOT/.gaia/local/telemetry"
  mkdir -p "$PROJECTS_DIRECTORY"
}

encode_project_path() { printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'; }

subst() { sed -e "s|@ROOT@|$ROOT|g" -e "s|@SIB@|${SIB:-}|g" "$1"; }

# install <scenario> [live]: the scenario's projects tree into PROJECTS_DIRECTORY. Files are
# aged past every quiet window unless `live` is passed.
install() {
  local source_directory="$FIXTURES_DIRECTORY/$1/projects" relative_path destination_path encoded_root
  encoded_root="$(encode_project_path "$ROOT")"
  while IFS= read -r relative_path; do
    destination_path="$PROJECTS_DIRECTORY/${relative_path#./}"
    destination_path="${destination_path//@MAIN@/$encoded_root}"
    mkdir -p "${destination_path%/*}"
    subst "$source_directory/$relative_path" >"$destination_path"
    [ "${2:-}" = live ] || touch -t 202001010000 "$destination_path"
  done < <(cd "$source_directory" && find . -type f -name '*.jsonl')
}

main_projects_directory() { printf '%s/%s' "$PROJECTS_DIRECTORY" "$(encode_project_path "$ROOT")"; }

flush() { bash "${FLUSHER:-$FLUSH}" --projects-root "$PROJECTS_DIRECTORY" --main-root "$ROOT" "$@"; }

file_size() { wc -c <"$1" | tr -d ' '; }

totals() {
  jq -S -s '[.[] | select(.kind == "segment")]
    | reduce .[] as $segment ({}; reduce ($segment.by_model | to_entries[]) as $model (.;
        reduce ($model.value | to_entries[]) as $bucket (.; .[$segment.key][$model.key][$bucket.key] += $bucket.value)))' "$TEL/usage.jsonl"
}

# assert_golden <scenario> [jq filter over the golden file]
assert_golden() {
  local want got
  want="$(jq -S "${2:-.}" "$FIXTURES_DIRECTORY/$1/golden.json")"
  got="$(totals)"
  [ "$got" = "$want" ] || { printf 'want:\n%s\ngot:\n%s\n' "$want" "$got" >&2; return 1; }
}

# scratch_flusher <sed-expr> <file>: a copy of the flusher and its libraries
# with one mutation applied to <file>; fails when the sed changed nothing.
scratch_flusher() {
  local scratch_directory="$TEMPORARY_DIRECTORY/scratch"
  mkdir -p "$scratch_directory/.gaia/scripts" "$scratch_directory/.gaia/scripts/spec"
  cp "$SCRIPTS"/usage-flush.sh "$SCRIPTS"/usage-parse-lib.sh "$SCRIPTS"/usage-lib.sh "$SCRIPTS"/main-root-lib.sh \
    "$SCRIPTS"/branch-name-lib.sh "$SCRIPTS"/ledger-path-lib.sh "$scratch_directory/.gaia/scripts/"
  cp "$SCRIPTS/spec/with-ledger-lock.sh" "$scratch_directory/.gaia/scripts/spec/"
  sed "$1" "$SCRIPTS/$2" >"$scratch_directory/.gaia/scripts/$2.m"
  if cmp -s "$SCRIPTS/$2" "$scratch_directory/.gaia/scripts/$2.m"; then
    echo "mutation did not apply to $2" >&2
    return 1
  fi
  mv "$scratch_directory/.gaia/scripts/$2.m" "$scratch_directory/.gaia/scripts/$2"
  FLUSHER="$scratch_directory/.gaia/scripts/usage-flush.sh"
}

wait_for() {
  local i=0
  while [ ! -e "$1" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$1" ]
}

# ---------- UAT-001 ----------

@test "UAT-001: a fix/foo session flushed with --finished-main equals golden; its cached offset is the file length" {
  install branch
  run --separate-stderr flush --session s-branch --finished-main
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  assert_golden branch
  local transcript_file offset
  transcript_file="$(main_projects_directory)/s-branch.jsonl"
  offset="$(jq --arg transcript_path "$transcript_file" '.files[$transcript_path].offset' "$TEL/usage-cursors.json")"
  [ "$offset" -eq "$(file_size "$transcript_file")" ]
}

# ---------- UAT-002 ----------

@test "UAT-002: main, then two worktree branches, with sidecars and a workflow sidecar: each line keyed by its own gitBranch" {
  install multi
  run flush --session s-multi --finished-main
  [ "$status" -eq 0 ]
  assert_golden multi
  jq -e -s '[.[] | select(.kind == "cursor") | .role] | sort
    == ["main", "subagents/agent-a1.jsonl", "subagents/agent-a2.jsonl", "subagents/agent-a3.jsonl",
        "subagents/workflows/wf_x/agent-y.jsonl"]' "$TEL/usage.jsonl"
}

# ---------- UAT-004 (write side) ----------

@test "UAT-004: a research Write binds research:<slug> by a binding row, never a segment key, and splits a segment at its timestamp" {
  install research
  run flush --session s-res --finished-main
  [ "$status" -eq 0 ]
  subst "$FIXTURES_DIRECTORY/research/append.jsonl" >>"$(main_projects_directory)/s-res.jsonl"
  run flush --session s-res --finished-main
  [ "$status" -eq 0 ]
  assert_golden research
  [ "$(jq -s '[.[] | select(.kind == "segment" and (.key | startswith("research:")))] | length' "$TEL/usage.jsonl")" -eq 0 ]
  jq -e -s '[.[] | select(.kind == "binding")] == [{"schema_version":1,"kind":"binding","type":"research","session_id":"s-res",
    "ts":"2026-10-01T00:05:02.000Z","ref":"research:topic-a-2026-10-01","source":"transcript"}]' "$TEL/usage.jsonl"
  jq -e -s 'any(.[]; .kind == "segment" and .first_ts == "2026-10-01T00:05:02.000Z")' "$TEL/usage.jsonl"
  jq -e -s 'any(.[]; .kind == "segment" and .last_ts == "2026-10-01T00:05:01.000Z")' "$TEL/usage.jsonl"
}

# ---------- UAT-014 / TST-004 ----------

# holdback_run: the two-flush sequence on a live file, then quiescence.
holdback_run() {
  local transcript_file
  install holdback live
  transcript_file="$(main_projects_directory)/s-hold.jsonl"
  flush --sweep 2>/dev/null
  HB_FIRST_SEGMENTS="$(jq -s '[.[] | select(.kind == "segment")] | length' "$TEL/usage.jsonl")"
  HB_FIRST_OFFSET="$(jq --arg transcript_path "$transcript_file" '.files[$transcript_path].offset' "$TEL/usage-cursors.json")"
  HB_LINE1="$(head -n 1 "$transcript_file" | wc -c | tr -d ' ')"
  subst "$FIXTURES_DIRECTORY/holdback/append.jsonl" >>"$transcript_file"
  flush --sweep 2>/dev/null
  HB_SECOND_OUTPUT="$(jq -s '[.[] | select(.kind == "segment") | .by_model[].output] | add' "$TEL/usage.jsonl")"
  touch -t 202001010000 "$transcript_file"
  flush --sweep 2>/dev/null
}

@test "UAT-014: a streamed message split across flushes is held, then counted once at its final value" {
  holdback_run
  [ "$HB_FIRST_SEGMENTS" -eq 0 ]
  [ "$HB_FIRST_OFFSET" -eq "$HB_LINE1" ]
  [ "$HB_SECOND_OUTPUT" -eq 50 ]
  assert_golden holdback
}

@test "UAT-014 guard: with the holdback disabled in a scratch copy the total no longer equals golden" {
  scratch_flusher 's/| (if $finished then null else $trailing_line end) as $hold/| null as $hold/' usage-parse-lib.sh
  holdback_run
  run assert_golden holdback
  [ "$status" -ne 0 ]
  [ "$(totals | jq '[.[][].output] | add')" -eq 12 ]
}

# ---------- relocation and truncation (AUDIT RT-004, MIG-012) ----------

@test "relocation: a copy with header lines in a second candidate dir adds only its new message" {
  install reloc
  run flush --session s-rel --finished-main
  [ "$status" -eq 0 ]
  local worktree_directory
  worktree_directory="$(main_projects_directory)--claude-worktrees-rel"
  mkdir -p "$worktree_directory"
  { cat "$FIXTURES_DIRECTORY/reloc/header.jsonl"; cat "$(main_projects_directory)/s-rel.jsonl"; subst "$FIXTURES_DIRECTORY/reloc/new.jsonl"; } >"$worktree_directory/s-rel.jsonl"
  run flush --session s-rel --finished-main
  [ "$status" -eq 0 ]
  assert_golden reloc '{"branch:fix/rel": .["branch:fix/rel"]}'
  jq -e --arg transcript_path "$worktree_directory/s-rel.jsonl" '.files[$transcript_path].offset > 0' "$TEL/usage-cursors.json"
}

@test "truncation: a file rewritten shorter than its cursor is reread from 0 and adds only its new message" {
  install reloc
  local transcript_file offset
  transcript_file="$(main_projects_directory)/s-trunc.jsonl"
  run flush --session s-trunc --finished-main
  [ "$status" -eq 0 ]
  offset="$(jq --arg transcript_path "$transcript_file" '.files[$transcript_path].offset' "$TEL/usage-cursors.json")"
  subst "$FIXTURES_DIRECTORY/reloc/rewrite.jsonl" >"$transcript_file"
  [ "$(file_size "$transcript_file")" -lt "$offset" ]
  run flush --session s-trunc --finished-main
  [ "$status" -eq 0 ]
  assert_golden reloc '{"branch:fix/trunc": .["branch:fix/trunc"]}'
  [ "$(jq --arg transcript_path "$transcript_file" '.files[$transcript_path].offset' "$TEL/usage-cursors.json")" -eq "$(file_size "$transcript_file")" ]
}

# ---------- UAT-012 / PERF-006 ----------

@test "UAT-012: a cold sweep reads every file from byte 0, leaves cost.jsonl byte-identical, and equals golden" {
  install sweep
  mkdir -p "$TEL"
  subst "$FIXTURES_DIRECTORY/sweep/cost.jsonl" >"$TEL/cost.jsonl"
  cp "$TEL/cost.jsonl" "$TEMPORARY_DIRECTORY/cost.before"
  run flush --sweep
  [ "$status" -eq 0 ]
  cmp "$TEL/cost.jsonl" "$TEMPORARY_DIRECTORY/cost.before"
  assert_golden sweep
  # The cost.jsonl row between s-sw2's two messages is a split point.
  [ "$(jq -s '[.[] | select(.kind == "segment" and .session_id == "s-sw2")] | length' "$TEL/usage.jsonl")" -eq 2 ]
  [ "$(jq -s '[.[] | select(.kind == "cursor")] | length' "$TEL/usage.jsonl")" -eq 6 ]
}

@test "UAT-012: a sweep killed after its first parse loses nothing and counts nothing twice on the next sweep" {
  install sweep
  local pid
  # The flusher itself, not a function subshell, so the signal reaches it.
  GAIA_USAGE_TEST_BARRIER="$TEMPORARY_DIRECTORY/bar" bash "$FLUSH" --projects-root "$PROJECTS_DIRECTORY" --main-root "$ROOT" --sweep 2>/dev/null 3>&- &
  pid=$!
  wait_for "$TEMPORARY_DIRECTORY/bar.parsed"
  kill -TERM "$pid"
  wait "$pid" || true
  [ -e "$TEL/usage-sweep.lock.d" ] && return 1
  run flush --sweep
  [ "$status" -eq 0 ]
  assert_golden sweep
}

# ---------- UAT-020 / SEC-002 / COV-015 ----------

# The underscore makes the repo and its sibling `repo-m` share one encoded
# projects dir, so only the per-line cwd check keeps the sibling out.
member_run() {
  use_repo "$1/repo_m"
  SIB="$1/repo-m"
  install member
  flush --sweep 2>/dev/null
}

@test "UAT-020: sibling-repo lines in a shared encoded dir, a -web decoy, and an unrelated dir add zero tokens" {
  member_run "$TEMPORARY_DIRECTORY/m1"
  assert_golden member
  grep -F -e 'fix/decoy' -e 'fix/web' -e 'fix/other' "$TEL/usage.jsonl" && return 1
  true
}

@test "UAT-020 guard: with membership bypassed in a scratch copy the sibling's tokens are counted" {
  scratch_flusher 's/(usage_member(\$record.cwd; \$roots) | not)/false/' usage-parse-lib.sh
  member_run "$TEMPORARY_DIRECTORY/m2"
  run assert_golden member
  [ "$status" -ne 0 ]
  jq -e -s 'any(.[]; .kind == "segment" and .key == "branch:fix/decoy")' "$TEL/usage.jsonl"
}

# ---------- UAT-024 ----------

@test "UAT-024: with origin/HEAD at master, master and HEAD lines key session:<sid>" {
  use_repo "$TEMPORARY_DIRECTORY/repo-master" master
  git -C "$ROOT" branch main
  git -C "$ROOT" update-ref refs/remotes/origin/master HEAD
  git -C "$ROOT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
  install master
  run flush --session s-master --finished-main
  [ "$status" -eq 0 ]
  assert_golden master
  grep -F -e '"branch:master"' -e '"branch:HEAD"' "$TEL/usage.jsonl" && return 1
  true
}

# ---------- UAT-019 (flusher side) ----------

@test "UAT-019: Edit, Bash, foreign, dot-dot, and loose non-.md writes bind nothing; a dotted dir and a loose .md bind" {
  install research19
  run flush --sweep
  [ "$status" -eq 0 ]
  [ "$(jq -s '[.[] | select(.kind == "cursor")] | length' "$TEL/usage.jsonl")" -eq 6 ]
  [ "$(jq -s '[.[] | select(.kind == "binding" and (.session_id | startswith("s-rn")))] | length' "$TEL/usage.jsonl")" -eq 0 ]
  jq -e -s '[.[] | select(.kind == "binding") | .ref] | sort == ["research:DEBT-LOOP-DIAGNOSIS", "research:release-2.0.0-readiness"]' \
    "$TEL/usage.jsonl"
}

# ---------- SEC-005 ----------

@test "SEC-005: a shell-bearing gitBranch and a quoted slug reach jq as data; the branch is hash-keyed" {
  install sec
  run bash -c 'cd "$1" && shift && bash "$@"' _ "$TEMPORARY_DIRECTORY" "$FLUSH" --projects-root "$PROJECTS_DIRECTORY" --main-root "$ROOT" \
    --session s-sec --finished-main
  [ "$status" -eq 0 ]
  [ -z "$(find "$BATS_TEST_TMPDIR" -name pwn)" ]
  jq -c . "$TEL/usage.jsonl" >/dev/null
  local want
  want="branch:%$(printf '%s' 'x$(touch${IFS}pwn)' | shasum -a 256 | cut -c1-16)"
  jq -e -s --arg expected_key "$want" '[.[] | select(.kind == "segment") | .key] == [$expected_key]' "$TEL/usage.jsonl"
  [ "$(jq -s '[.[] | select(.kind == "binding")] | length' "$TEL/usage.jsonl")" -eq 0 ]
}

# ---------- UAT-013 / UAT-028 (flusher side) ----------

@test "UAT-013: with jq absent from PATH the flusher exits 0 and creates no telemetry dir" {
  install branch
  mkdir -p "$TEMPORARY_DIRECTORY/nojq"
  run env PATH="$TEMPORARY_DIRECTORY/nojq" "$BASH" "$FLUSH" --projects-root "$PROJECTS_DIRECTORY" --main-root "$ROOT" --session s-branch --finished-main
  [ "$status" -eq 0 ]
  [ -e "$ROOT/.gaia/local/telemetry" ] && return 1
  true
}

@test "UAT-028: under GITHUB_ACTIONS the flusher exits 0 and creates no telemetry dir; unset, it records" {
  install branch
  GITHUB_ACTIONS=true run flush --session s-branch --finished-main
  [ "$status" -eq 0 ]
  [ -e "$ROOT/.gaia/local/telemetry" ] && return 1
  run flush --session s-branch --finished-main
  [ "$status" -eq 0 ]
  [ -d "$TEL" ]
  assert_golden branch
}

# ---------- start evidence ----------

@test "start evidence: a Skill and a <command-name> line in the closed set bind a start; simplify, gaia-handoff, gaia-pickup do not" {
  install start
  run flush --session s-start --finished-main
  [ "$status" -eq 0 ]
  jq -e -s '[.[] | select(.kind == "binding" and .type == "start") | [.workflow, .ts, .source]]
    == [["gaia-spec", "2026-10-01T00:00:01.000Z", "transcript"], ["gaia-debt", "2026-10-01T00:00:02.000Z", "transcript"],
        ["gaia-plan", "2026-10-01T00:00:06.000Z", "transcript"]]' "$TEL/usage.jsonl"
  grep -F -e 'gaia-handoff' -e 'gaia-pickup' -e 'simplify' "$TEL/usage.jsonl" && return 1
  true
}

# ---------- UAT-010 compare-and-swap ----------

# cas_run: flusher A parks after its parse; B flushes the same session; A resumes.
cas_run() {
  local pid
  install branch
  GAIA_USAGE_TEST_BARRIER="$TEMPORARY_DIRECTORY/bar" flush --session s-branch --finished-main 2>/dev/null 3>&- &
  pid=$!
  wait_for "$TEMPORARY_DIRECTORY/bar.parsed"
  FLUSHER="" flush --session s-branch --finished-main 2>/dev/null
  : >"$TEMPORARY_DIRECTORY/bar"
  wait "$pid"
}

@test "UAT-010: a flusher whose cursor moved under it while parked reparses and counts nothing twice" {
  cas_run
  assert_golden branch
}

@test "UAT-010 guard: with the compare-and-swap removed in a scratch copy the parked flusher double counts" {
  scratch_flusher '/_uf_cas_conflict "\$session_id"/d' usage-flush.sh
  cas_run
  run assert_golden branch
  [ "$status" -ne 0 ]
  [ "$(totals | jq '.["branch:fix/foo"]["claude-opus-5-5"].fresh_input')" -eq 12 ]
}

# ---------- TST-012b lock timeout ----------

@test "TST-012b: a lock timeout writes nothing; once the lock is free the rerun commits and equals golden" {
  install branch
  export GAIA_LEDGER_LOCK_FORCE_FALLBACK=1
  mkdir -p "$TEL/specs.lock.d"
  GAIA_LEDGER_LOCK_TIMEOUT_SECONDS=1 GAIA_LEDGER_LOCK_POLL_SECONDS=0.1 run flush --session s-branch --finished-main
  [ "$status" -eq 0 ]
  [ -e "$TEL/usage.jsonl" ] && return 1
  [ -e "$TEL/usage-cursors.json" ] && return 1
  rmdir "$TEL/specs.lock.d"
  run flush --session s-branch --finished-main
  [ "$status" -eq 0 ]
  assert_golden branch
}

# ---------- sweep singleton ----------

@test "sweep singleton: a second sweep exits 0 without writing while the first holds the lock" {
  install sweep
  local pid
  GAIA_USAGE_TEST_BARRIER="$TEMPORARY_DIRECTORY/bar" flush --sweep 2>/dev/null 3>&- &
  pid=$!
  wait_for "$TEMPORARY_DIRECTORY/bar.parsed"
  [ -d "$TEL/usage-sweep.lock.d" ]
  run flush --sweep
  [ "$status" -eq 0 ]
  [ -e "$TEL/usage.jsonl" ] && return 1
  : >"$TEMPORARY_DIRECTORY/bar"
  wait "$pid"
  assert_golden sweep
}

@test "sweep singleton: a lock dir older than the reclaim age is reclaimed" {
  install sweep
  mkdir -p "$TEL/usage-sweep.lock.d"
  touch -t 202001010000 "$TEL/usage-sweep.lock.d"
  run flush --sweep
  [ "$status" -eq 0 ]
  assert_golden sweep
  [ -e "$TEL/usage-sweep.lock.d" ] && return 1
  true
}
