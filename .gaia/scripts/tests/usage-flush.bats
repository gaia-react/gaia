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
  FIXDIR="$BATS_TEST_DIRNAME/fixtures/usage/flush"
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export GAIA_RATES_FEED_DISABLE=1 GAIA_RATES_STATE_DIR="$TMP/rates-state"
  unset GITHUB_ACTIONS GAIA_USAGE_TEST_BARRIER GAIA_USAGE_DEBUG_HOLD GAIA_TALLY_PROJECTS_ROOT
  unset GAIA_LEDGER_LOCK_FORCE_FALLBACK GAIA_LEDGER_LOCK_TIMEOUT_SECS
  use_repo "$TMP/repo"
}

# ---------- helpers ----------

mk_repo() {
  mkdir -p "$1"
  git -C "$1" init -q -b "${2:-main}"
  git -C "$1" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false \
    commit -q --allow-empty -m init
}

# use_repo <dir> [branch]: a fresh repo as ROOT, with PROJ and TEL beside it.
use_repo() {
  mk_repo "$1" "${2:-main}"
  ROOT="$1"
  PROJ="${1%/*}/projects-${1##*/}"
  TEL="$ROOT/.gaia/local/telemetry"
  mkdir -p "$PROJ"
}

enc() { printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'; }

subst() { sed -e "s|@ROOT@|$ROOT|g" -e "s|@SIB@|${SIB:-}|g" "$1"; }

# install <scenario> [live]: the scenario's projects tree into PROJ. Files are
# aged past every quiet window unless `live` is passed.
install() {
  local src="$FIXDIR/$1/projects" rel out e
  e="$(enc "$ROOT")"
  while IFS= read -r rel; do
    out="$PROJ/${rel#./}"
    out="${out//@MAIN@/$e}"
    mkdir -p "${out%/*}"
    subst "$src/$rel" >"$out"
    [ "${2:-}" = live ] || touch -t 202001010000 "$out"
  done < <(cd "$src" && find . -type f -name '*.jsonl')
}

main_dir() { printf '%s/%s' "$PROJ" "$(enc "$ROOT")"; }

flush() { bash "${FLUSHER:-$FLUSH}" --projects-root "$PROJ" --main-root "$ROOT" "$@"; }

fsize() { wc -c <"$1" | tr -d ' '; }

totals() {
  jq -S -s '[.[] | select(.kind == "segment")]
    | reduce .[] as $s ({}; reduce ($s.by_model | to_entries[]) as $m (.;
        reduce ($m.value | to_entries[]) as $b (.; .[$s.key][$m.key][$b.key] += $b.value)))' "$TEL/usage.jsonl"
}

# assert_golden <scenario> [jq filter over the golden file]
assert_golden() {
  local want got
  want="$(jq -S "${2:-.}" "$FIXDIR/$1/golden.json")"
  got="$(totals)"
  [ "$got" = "$want" ] || { printf 'want:\n%s\ngot:\n%s\n' "$want" "$got" >&2; return 1; }
}

# scratch_flusher <sed-expr> <file>: a copy of the flusher and its libraries
# with one mutation applied to <file>; fails when the sed changed nothing.
scratch_flusher() {
  local d="$TMP/scratch"
  mkdir -p "$d/.gaia/scripts" "$d/.specify/extensions/gaia/lib"
  cp "$SCRIPTS"/usage-flush.sh "$SCRIPTS"/usage-parse-lib.sh "$SCRIPTS"/usage-lib.sh "$SCRIPTS"/main-root-lib.sh \
    "$SCRIPTS"/branch-name-lib.sh "$SCRIPTS"/ledger-path-lib.sh "$d/.gaia/scripts/"
  cp "$SCRIPTS/../../.specify/extensions/gaia/lib/with-ledger-lock.sh" "$d/.specify/extensions/gaia/lib/"
  sed "$1" "$SCRIPTS/$2" >"$d/.gaia/scripts/$2.m"
  if cmp -s "$SCRIPTS/$2" "$d/.gaia/scripts/$2.m"; then
    echo "mutation did not apply to $2" >&2
    return 1
  fi
  mv "$d/.gaia/scripts/$2.m" "$d/.gaia/scripts/$2"
  FLUSHER="$d/.gaia/scripts/usage-flush.sh"
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
  local f off
  f="$(main_dir)/s-branch.jsonl"
  off="$(jq --arg p "$f" '.files[$p].offset' "$TEL/usage-cursors.json")"
  [ "$off" -eq "$(fsize "$f")" ]
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
  subst "$FIXDIR/research/append.jsonl" >>"$(main_dir)/s-res.jsonl"
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
  local f
  install holdback live
  f="$(main_dir)/s-hold.jsonl"
  flush --sweep 2>/dev/null
  HB_FIRST_SEGMENTS="$(jq -s '[.[] | select(.kind == "segment")] | length' "$TEL/usage.jsonl")"
  HB_FIRST_OFFSET="$(jq --arg p "$f" '.files[$p].offset' "$TEL/usage-cursors.json")"
  HB_LINE1="$(head -n 1 "$f" | wc -c | tr -d ' ')"
  subst "$FIXDIR/holdback/append.jsonl" >>"$f"
  flush --sweep 2>/dev/null
  HB_SECOND_OUTPUT="$(jq -s '[.[] | select(.kind == "segment") | .by_model[].output] | add' "$TEL/usage.jsonl")"
  touch -t 202001010000 "$f"
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
  scratch_flusher 's/| (if $finished then null else $a end) as $hold/| null as $hold/' usage-parse-lib.sh
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
  local wt
  wt="$(main_dir)--claude-worktrees-rel"
  mkdir -p "$wt"
  { cat "$FIXDIR/reloc/header.jsonl"; cat "$(main_dir)/s-rel.jsonl"; subst "$FIXDIR/reloc/new.jsonl"; } >"$wt/s-rel.jsonl"
  run flush --session s-rel --finished-main
  [ "$status" -eq 0 ]
  assert_golden reloc '{"branch:fix/rel": .["branch:fix/rel"]}'
  jq -e --arg p "$wt/s-rel.jsonl" '.files[$p].offset > 0' "$TEL/usage-cursors.json"
}

@test "truncation: a file rewritten shorter than its cursor is reread from 0 and adds only its new message" {
  install reloc
  local f off
  f="$(main_dir)/s-trunc.jsonl"
  run flush --session s-trunc --finished-main
  [ "$status" -eq 0 ]
  off="$(jq --arg p "$f" '.files[$p].offset' "$TEL/usage-cursors.json")"
  subst "$FIXDIR/reloc/rewrite.jsonl" >"$f"
  [ "$(fsize "$f")" -lt "$off" ]
  run flush --session s-trunc --finished-main
  [ "$status" -eq 0 ]
  assert_golden reloc '{"branch:fix/trunc": .["branch:fix/trunc"]}'
  [ "$(jq --arg p "$f" '.files[$p].offset' "$TEL/usage-cursors.json")" -eq "$(fsize "$f")" ]
}

# ---------- UAT-012 / PERF-006 ----------

@test "UAT-012: a cold sweep reads every file from byte 0, leaves cost.jsonl byte-identical, and equals golden" {
  install sweep
  mkdir -p "$TEL"
  subst "$FIXDIR/sweep/cost.jsonl" >"$TEL/cost.jsonl"
  cp "$TEL/cost.jsonl" "$TMP/cost.before"
  run flush --sweep
  [ "$status" -eq 0 ]
  cmp "$TEL/cost.jsonl" "$TMP/cost.before"
  assert_golden sweep
  # The cost.jsonl row between s-sw2's two messages is a split point.
  [ "$(jq -s '[.[] | select(.kind == "segment" and .session_id == "s-sw2")] | length' "$TEL/usage.jsonl")" -eq 2 ]
  [ "$(jq -s '[.[] | select(.kind == "cursor")] | length' "$TEL/usage.jsonl")" -eq 6 ]
}

@test "UAT-012: a sweep killed after its first parse loses nothing and counts nothing twice on the next sweep" {
  install sweep
  local pid
  # The flusher itself, not a function subshell, so the signal reaches it.
  GAIA_USAGE_TEST_BARRIER="$TMP/bar" bash "$FLUSH" --projects-root "$PROJ" --main-root "$ROOT" --sweep 2>/dev/null 3>&- &
  pid=$!
  wait_for "$TMP/bar.parsed"
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
  member_run "$TMP/m1"
  assert_golden member
  grep -F -e 'fix/decoy' -e 'fix/web' -e 'fix/other' "$TEL/usage.jsonl" && return 1
  true
}

@test "UAT-020 guard: with membership bypassed in a scratch copy the sibling's tokens are counted" {
  scratch_flusher 's/(usage_member(\$x.cwd; \$roots) | not)/false/' usage-parse-lib.sh
  member_run "$TMP/m2"
  run assert_golden member
  [ "$status" -ne 0 ]
  jq -e -s 'any(.[]; .kind == "segment" and .key == "branch:fix/decoy")' "$TEL/usage.jsonl"
}

# ---------- UAT-024 ----------

@test "UAT-024: with origin/HEAD at master, master and HEAD lines key session:<sid>" {
  use_repo "$TMP/repo-master" master
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
  run bash -c 'cd "$1" && shift && bash "$@"' _ "$TMP" "$FLUSH" --projects-root "$PROJ" --main-root "$ROOT" \
    --session s-sec --finished-main
  [ "$status" -eq 0 ]
  [ -z "$(find "$BATS_TEST_TMPDIR" -name pwn)" ]
  jq -c . "$TEL/usage.jsonl" >/dev/null
  local want
  want="branch:%$(printf '%s' 'x$(touch${IFS}pwn)' | shasum -a 256 | cut -c1-16)"
  jq -e -s --arg k "$want" '[.[] | select(.kind == "segment") | .key] == [$k]' "$TEL/usage.jsonl"
  [ "$(jq -s '[.[] | select(.kind == "binding")] | length' "$TEL/usage.jsonl")" -eq 0 ]
}

# ---------- UAT-013 / UAT-028 (flusher side) ----------

@test "UAT-013: with jq absent from PATH the flusher exits 0 and creates no telemetry dir" {
  install branch
  mkdir -p "$TMP/nojq"
  run env PATH="$TMP/nojq" "$BASH" "$FLUSH" --projects-root "$PROJ" --main-root "$ROOT" --session s-branch --finished-main
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
  GAIA_USAGE_TEST_BARRIER="$TMP/bar" flush --session s-branch --finished-main 2>/dev/null 3>&- &
  pid=$!
  wait_for "$TMP/bar.parsed"
  FLUSHER="" flush --session s-branch --finished-main 2>/dev/null
  : >"$TMP/bar"
  wait "$pid"
}

@test "UAT-010: a flusher whose cursor moved under it while parked reparses and counts nothing twice" {
  cas_run
  assert_golden branch
}

@test "UAT-010 guard: with the compare-and-swap removed in a scratch copy the parked flusher double counts" {
  scratch_flusher '/_uf_cas_conflict "\$sid"/d' usage-flush.sh
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
  GAIA_LEDGER_LOCK_TIMEOUT_SECS=1 GAIA_LEDGER_LOCK_POLL_SECS=0.1 run flush --session s-branch --finished-main
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
  GAIA_USAGE_TEST_BARRIER="$TMP/bar" flush --sweep 2>/dev/null 3>&- &
  pid=$!
  wait_for "$TMP/bar.parsed"
  [ -d "$TEL/usage-sweep.lock.d" ]
  run flush --sweep
  [ "$status" -eq 0 ]
  [ -e "$TEL/usage.jsonl" ] && return 1
  : >"$TMP/bar"
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
