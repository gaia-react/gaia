#!/usr/bin/env bats
#
# Tests for `.gaia/scripts/audit-respawn-prune.sh` -- the audit re-spawn
# ledger prune sweep, the reaper the `audit-respawn-ledger` registry entry's
# `reaped_by` field names. Bounds .gaia/local/telemetry/audit-respawn.jsonl
# with two arms: an age window (gaia_respawn_retention_days) and a record cap
# (gaia_respawn_max_records) strictly subordinate to it -- the cap never
# trims an in-window record, and it never resurrects an out-of-window one
# unless the ledger's own pre-prune total was already over the cap (see the
# script's own header for why that gate is load-bearing: without it, the
# default 20000 cap would resurrect every out-of-window record in any
# ordinarily-sized ledger, which criteria 4 and 5 below rule out).
#
# Every fixture writes ledger lines directly (never depends on the spawn
# oracle running) and sources audit-respawn-lib.sh for the ledger-path helper
# and the retention/cap knobs, so the suite and the script under test cannot
# drift on either.
#
# Timestamps are built portably, per .claude/rules/bats-assertions.md: an
# epoch via `date -u +%s` arithmetic, formatted with `jq -rn --argjson e "$e"
# '$e | todateiso8601'` -- never `date -v` (BSD-only) or `date -d` (GNU-only).
# A bulk fixture (hundreds to low thousands of records) computes ITS ONE
# shared timestamp once and loops with plain printf, not one jq fork per
# line: the difference between this suite finishing in under a second and
# taking the better part of a minute.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real):
#   source .gaia/scripts/bats5.sh && bats5 .gaia/scripts/tests/audit-respawn-prune.bats

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIR/../audit-respawn-prune.sh"
  LIB="$THIS_DIR/../audit-respawn-lib.sh"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  HOOK_ABS="$REPO_ROOT/.claude/hooks/wiki-session-start.sh"
  [ -x "$SCRIPT" ] || skip "audit-respawn-prune.sh not executable"
  [ -f "$LIB" ] || skip "audit-respawn-lib.sh missing"
  [ -f "$HOOK_ABS" ] || skip "wiki-session-start.sh missing"

  NOW_EPOCH="$(date -u +%s)"
}

# --- fixture helpers ---------------------------------------------------

# epoch_ts <days_ago>: an ISO-8601 timestamp <days_ago> days before "now".
epoch_ts() {
  local days_ago="$1" e
  e=$((NOW_EPOCH - days_ago * 86400))
  jq -rn --argjson e "$e" '$e | todateiso8601'
}

# make_root: a fresh, plain (non-git) root with .gaia/local/telemetry
# pre-created. Prints the path.
make_root() {
  local d
  d="$(mktemp -d "$BATS_TEST_TMPDIR/root-XXXXXX")"
  mkdir -p "$d/.gaia/local/telemetry"
  printf '%s' "$d"
}

# ledger_for <root>: the ledger path via the SAME lib call the script itself
# uses, so the suite and the script under test cannot drift on the location.
ledger_for() {
  # shellcheck source=/dev/null
  ( . "$LIB"; gaia_respawn_ledger_path "$1" )
}

# append_record <ledger> <ts> <branch>: one C2-shaped line.
append_record() {
  local ledger="$1" ts="$2" branch="$3"
  printf '{"schema":1,"ts":"%s","branch":"%s","head":"aaaa","merge_base":"bbbb","member":"code-audit-frontend","digest":"cccc","cleared":false}\n' \
    "$ts" "$branch" >> "$ledger"
}

# append_bulk <ledger> <count> <ts> <prefix>: <count> records sharing one
# precomputed <ts>.
append_bulk() {
  local ledger="$1" count="$2" ts="$3" prefix="$4" i
  for i in $(seq 1 "$count"); do
    printf '{"schema":1,"ts":"%s","branch":"%s-%s","head":"aaaa","merge_base":"bbbb","member":"code-audit-frontend","digest":"cccc","cleared":false}\n' \
      "$ts" "$prefix" "$i"
  done >> "$ledger"
}

# branches_in <ledger>: every record's `.branch` field, one per line, in file
# order -- greps the literal field rather than parsing JSON, since a
# deliberately malformed test line may not parse at all.
branches_in() {
  grep -o '"branch":"[^"]*"' "$1" 2>/dev/null | sed 's/"branch":"//; s/"$//'
}

# A PATH carrying every binary the script needs EXCEPT jq (mirrors
# resolve-audit-spawn.bats's path_without_jq).
path_without_jq() {
  local d="$BATS_TEST_TMPDIR/nojq-bin" b p
  mkdir -p "$d"
  for b in env bash sh git awk sed grep sort head tail tr cat cut wc dirname basename mktemp date rm mkdir printf test expr; do
    p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$d/$b"
  done
  printf '%s' "$d"
}

# mutant_script <sed_expr>: a throwaway copy of $SCRIPT with <sed_expr>
# applied, alongside an untouched copy of $LIB so the mutant's own
# BASH_SOURCE-relative lib lookup resolves. Prints the mutant script's path.
# The real tracked $SCRIPT is never touched, so there is nothing to restore.
mutant_script() {
  local sed_expr="$1" dir
  dir="$(mktemp -d "$BATS_TEST_TMPDIR/mutant-XXXXXX")"
  cp "$LIB" "$dir/audit-respawn-lib.sh"
  sed "$sed_expr" "$SCRIPT" > "$dir/audit-respawn-prune.sh"
  chmod +x "$dir/audit-respawn-prune.sh"
  printf '%s' "$dir/audit-respawn-prune.sh"
}

# ========== 1-2: --help, ledger absent ==========

@test "1: --help prints usage and exits 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  grep -qF -- "Usage: audit-respawn-prune.sh" <<<"$output" || return 1
}

@test "1b: -h is the same as --help" {
  run bash "$SCRIPT" -h
  [ "$status" -eq 0 ]
  grep -qF -- "Usage: audit-respawn-prune.sh" <<<"$output" || return 1
}

@test "2: ledger absent exits 0, prints nothing, creates nothing" {
  local root; root="$(make_root)"
  run bash "$SCRIPT" "$root"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$(ledger_for "$root")" ]
}

# ========== 3-7: age arm ==========

@test "3: every record inside the window leaves the ledger byte-identical" {
  local root ledger before after
  root="$(make_root)"; ledger="$(ledger_for "$root")"
  append_record "$ledger" "$(epoch_ts 1)" "a"
  append_record "$ledger" "$(epoch_ts 5)" "b"
  before="$(shasum "$ledger")"
  run bash "$SCRIPT" "$root"
  [ "$status" -eq 0 ]
  after="$(shasum "$ledger")"
  [ "$before" = "$after" ]
}

@test "4: a mix drops exactly the out-of-window records, in-window survive in order, byte-identical" {
  local root ledger before_in1 before_in2
  root="$(make_root)"; ledger="$(ledger_for "$root")"
  append_record "$ledger" "$(epoch_ts 1)" "in-1"
  append_record "$ledger" "$(epoch_ts 200)" "out-1"
  append_record "$ledger" "$(epoch_ts 2)" "in-2"
  before_in1="$(sed -n '1p' "$ledger")"
  before_in2="$(sed -n '3p' "$ledger")"
  run bash "$SCRIPT" "$root"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$ledger" | tr -d ' ')" = "2" ]
  [ "$(sed -n '1p' "$ledger")" = "$before_in1" ]
  [ "$(sed -n '2p' "$ledger")" = "$before_in2" ]
  grep -qF "out-1" "$ledger" && return 1
  return 0
}

@test "4b: a final line with no trailing newline is judged by its own age, not its predecessor's" {
  local root ledger
  root="$(make_root)"; ledger="$(ledger_for "$root")"
  append_record "$ledger" "$(epoch_ts 1)" "in-first"
  append_record "$ledger" "$(epoch_ts 200)" "out-middle"
  # Deliberately unterminated: what a short or interrupted append leaves
  # behind. Line-numbering schemes disagree on exactly this shape, so the
  # last record is where an off-by-one shows up.
  printf '{"schema":1,"ts":"%s","branch":"in-last","head":"aaaa","merge_base":"bbbb","member":"code-audit-frontend","digest":"cccc","cleared":false}' \
    "$(epoch_ts 2)" >> "$ledger"
  run bash "$SCRIPT" "$root"
  [ "$status" -eq 0 ]
  local survivors; survivors="$(branches_in "$ledger")"
  [ "$survivors" = "$(printf 'in-first\nin-last')" ]
  grep -qF '"branch":"out-middle"' "$ledger" && return 1
  return 0
}

@test "5: every record out of window leaves a zero-byte file" {
  local root ledger
  root="$(make_root)"; ledger="$(ledger_for "$root")"
  append_record "$ledger" "$(epoch_ts 200)" "out-1"
  append_record "$ledger" "$(epoch_ts 150)" "out-2"
  run bash "$SCRIPT" "$root"
  [ "$status" -eq 0 ]
  [ -f "$ledger" ]
  [ ! -s "$ledger" ]
}

@test "6: a malformed (non-JSON) line survives untouched regardless of position" {
  local root ledger
  root="$(make_root)"; ledger="$(ledger_for "$root")"
  append_record "$ledger" "$(epoch_ts 200)" "out-before"
  printf 'not json at all\n' >> "$ledger"
  append_record "$ledger" "$(epoch_ts 200)" "out-after"
  run bash "$SCRIPT" "$root"
  [ "$status" -eq 0 ]
  grep -qxF "not json at all" "$ledger" || return 1
  [ "$(wc -l < "$ledger" | tr -d ' ')" = "1" ]
}

@test "7: a record with no ts, and one with an unparseable ts, both survive" {
  local root ledger
  root="$(make_root)"; ledger="$(ledger_for "$root")"
  printf '{"schema":1,"branch":"no-ts"}\n' >> "$ledger"
  printf '{"schema":1,"ts":"not-a-date","branch":"bad-ts"}\n' >> "$ledger"
  run bash "$SCRIPT" "$root"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$ledger" | tr -d ' ')" = "2" ]
  grep -qF '"branch":"no-ts"' "$ledger" || return 1
  grep -qF '"branch":"bad-ts"' "$ledger" || return 1
}

# ========== 8: retention-day floor ==========

@test "8a: override=45 (at the floor), a 60-day record is dropped" {
  local root ledger
  root="$(make_root)"; ledger="$(ledger_for "$root")"
  append_record "$ledger" "$(epoch_ts 60)" "aged-60"
  GAIA_AUDIT_RESPAWN_RETENTION_DAYS=45 run bash "$SCRIPT" "$root"
  [ "$status" -eq 0 ]
  [ ! -s "$ledger" ]
}

@test "8b: override=10 (below the floor), a 20-day record survives via the 45-day floor" {
  # Discriminating fixture: 20 days sits BETWEEN the override (10) and the
  # floor (45). With the floor, 20 < 45 -> survives. Without it, 20 > 10 ->
  # would be dropped. A 60-day record here would drop either way and prove
  # nothing (per the task doc's own warning against that false-green shape).
  local root ledger
  root="$(make_root)"; ledger="$(ledger_for "$root")"
  append_record "$ledger" "$(epoch_ts 20)" "aged-20"
  GAIA_AUDIT_RESPAWN_RETENTION_DAYS=10 run bash "$SCRIPT" "$root"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$ledger" | tr -d ' ')" = "1" ]
}

@test "8c: an invalid override (abc) takes the 90-day default, not the 45-day floor" {
  local root ledger
  root="$(make_root)"; ledger="$(ledger_for "$root")"
  append_record "$ledger" "$(epoch_ts 60)" "aged-60"
  GAIA_AUDIT_RESPAWN_RETENTION_DAYS=abc run bash "$SCRIPT" "$root"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$ledger" | tr -d ' ')" = "1" ]
}

# ========== 9: cap arm, subordinate to the window ==========

@test "8d: a leading-zero override (050) keeps a 47-day record, it does not read as octal 40" {
  local root ledger
  root="$(make_root)"; ledger="$(ledger_for "$root")"
  append_record "$ledger" "$(epoch_ts 47)" "aged-47"
  GAIA_AUDIT_RESPAWN_RETENTION_DAYS=050 run bash "$SCRIPT" "$root"
  [ "$status" -eq 0 ]
  # Read as octal the window is 40 days and this record is dropped, silently
  # shortening retention below the 45-day floor no override may cross.
  grep -qF "aged-47" "$ledger" || return 1
}

@test "8e: a leading-zero cap override does not abort the sweep" {
  local root ledger
  root="$(make_root)"; ledger="$(ledger_for "$root")"
  append_record "$ledger" "$(epoch_ts 1)" "in-1"
  # 08 and 09 are not valid octal, so an un-normalized value reaches the
  # arithmetic as an error, leaves its target unset, and trips `set -u`.
  GAIA_AUDIT_RESPAWN_MAX_RECORDS=08000 run bash "$SCRIPT" "$root"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -qF "in-1" "$ledger" || return 1
}

@test "9a: 1200 all-in-window records under cap=1000 all survive, byte-identical (cap does not fire)" {
  local root ledger ts before after
  root="$(make_root)"; ledger="$(ledger_for "$root")"
  ts="$(epoch_ts 1)"
  append_bulk "$ledger" 1200 "$ts" "in"
  before="$(shasum "$ledger")"
  GAIA_AUDIT_RESPAWN_MAX_RECORDS=1000 run bash "$SCRIPT" "$root"
  [ "$status" -eq 0 ]
  after="$(shasum "$ledger")"
  [ "$before" = "$after" ]
}

@test "9b: 1200 in-window + 500 out-of-window under cap=1000: the 500 are gone, all 1200 survive" {
  local root ledger
  root="$(make_root)"; ledger="$(ledger_for "$root")"
  append_bulk "$ledger" 1200 "$(epoch_ts 1)" "in"
  append_bulk "$ledger" 500 "$(epoch_ts 200)" "out"
  GAIA_AUDIT_RESPAWN_MAX_RECORDS=1000 run bash "$SCRIPT" "$root"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$ledger" | tr -d ' ')" = "1200" ]
  grep -qF '"out-' "$ledger" && return 1
  return 0
}

@test "9c: cap arm engages only once the pre-prune total exceeds the cap (default cap, small mix stays fully age-arm-governed)" {
  # Guards the gate the script's own header documents: with the DEFAULT cap
  # (20000) and a small ledger, in-window count is always far below cap, so a
  # naive budget = cap - inwindow would resurrect every out-of-window record.
  # This must not happen -- it is what tests 4 and 5 above already assert
  # under default settings; this test states the gate explicitly.
  local root ledger
  root="$(make_root)"; ledger="$(ledger_for "$root")"
  append_record "$ledger" "$(epoch_ts 1)" "in-1"
  append_record "$ledger" "$(epoch_ts 200)" "out-1"
  run bash "$SCRIPT" "$root"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$ledger" | tr -d ' ')" = "1" ]
  grep -qF "out-1" "$ledger" && return 1
  return 0
}

@test "9d: once the cap arm engages, it resurrects exactly the newest out-of-window records up to budget, in original order" {
  # inwindow=998, cap=1000 -> budget=2. 5 out-of-window candidates at
  # distinct ages: only the 2 NEWEST (closest to the cutoff) must survive.
  local root ledger ts
  root="$(make_root)"; ledger="$(ledger_for "$root")"
  ts="$(epoch_ts 1)"
  append_bulk "$ledger" 998 "$ts" "in"
  append_record "$ledger" "$(epoch_ts 200)" "oow-200"
  append_record "$ledger" "$(epoch_ts 180)" "oow-180"
  append_record "$ledger" "$(epoch_ts 150)" "oow-150"
  append_record "$ledger" "$(epoch_ts 120)" "oow-120"
  append_record "$ledger" "$(epoch_ts 100)" "oow-100"
  GAIA_AUDIT_RESPAWN_MAX_RECORDS=1000 run bash "$SCRIPT" "$root"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$ledger" | tr -d ' ')" = "1000" ]
  local survivors; survivors="$(branches_in "$ledger" | grep '^oow-')"
  [ "$survivors" = "$(printf 'oow-120\noow-100')" ]
  # Original relative order preserved: the surviving out-of-window records
  # still trail every in-window record, exactly as appended.
  [ "$(tail -n 2 "$ledger" | grep -c oow)" = "2" ]
}

# ========== 10: jq absent ==========

@test "10: jq absent leaves the ledger byte-identical and exits 0" {
  local root ledger before after nojq
  root="$(make_root)"; ledger="$(ledger_for "$root")"
  append_record "$ledger" "$(epoch_ts 200)" "out-1"
  before="$(shasum "$ledger")"
  nojq="$(path_without_jq)"
  PATH="$nojq" run bash "$SCRIPT" "$root"
  [ "$status" -eq 0 ]
  after="$(shasum "$ledger")"
  [ "$before" = "$after" ]
}

# ========== 11: no temp file left behind ==========

@test "11a: after a successful prune, the ledger's directory holds exactly the ledger" {
  local root ledger dir
  root="$(make_root)"; ledger="$(ledger_for "$root")"
  append_record "$ledger" "$(epoch_ts 1)" "in-1"
  append_record "$ledger" "$(epoch_ts 200)" "out-1"
  run bash "$SCRIPT" "$root"
  [ "$status" -eq 0 ]
  dir="$(dirname "$ledger")"
  [ "$(ls -A "$dir")" = "$(basename "$ledger")" ]
}

@test "11b: after a jq-absent no-op, no temp file is left behind" {
  local root ledger dir nojq
  root="$(make_root)"; ledger="$(ledger_for "$root")"
  append_record "$ledger" "$(epoch_ts 200)" "out-1"
  nojq="$(path_without_jq)"
  PATH="$nojq" run bash "$SCRIPT" "$root"
  [ "$status" -eq 0 ]
  dir="$(dirname "$ledger")"
  [ "$(ls -A "$dir")" = "$(basename "$ledger")" ]
}

# ========== 12: unwritable ledger directory ==========

@test "12: an unwritable ledger directory exits 0, no crash, ledger untouched" {
  local root ledger dir before after
  root="$(make_root)"; ledger="$(ledger_for "$root")"
  append_record "$ledger" "$(epoch_ts 200)" "out-1"
  before="$(shasum "$ledger")"
  dir="$(dirname "$ledger")"
  chmod 555 "$dir"
  run bash "$SCRIPT" "$root"
  chmod 755 "$dir"
  [ "$status" -eq 0 ]
  after="$(shasum "$ledger")"
  [ "$before" = "$after" ]
}

# ========== 13: bash 3.2 ==========

@test "13: runs correctly under the system bash (3.2 on macOS)" {
  [ -x /bin/bash ] || skip "/bin/bash not present"
  local root ledger
  root="$(make_root)"; ledger="$(ledger_for "$root")"
  append_record "$ledger" "$(epoch_ts 1)" "in-1"
  append_record "$ledger" "$(epoch_ts 200)" "out-1"
  run /bin/bash "$SCRIPT" "$root"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$ledger" | tr -d ' ')" = "1" ]
}

# ========== 15: the SessionStart hook, sandboxed only ==========
#
# .claude/hooks/wiki-session-start.sh is a REAL SessionStart hook with side
# effects on the live checkout (records HEAD, fires local-janitor.sh's nine
# sweeps over the live .gaia/local). Every test below runs it against a
# throwaway `git init` sandbox and never against the real repository.

# make_hook_sandbox: a throwaway git repo with a copy of the real prune
# script + its lib at the sandbox's own .gaia/scripts/, exactly where the
# hook's relative-path [ -f ... ] guard and the script's own BASH_SOURCE
# lookup both expect to find them. Prints the sandbox path.
make_hook_sandbox() {
  local d
  d="$(mktemp -d "$BATS_TEST_TMPDIR/hooksandbox-XXXXXX")"
  git init -q --initial-branch=main "$d"
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name T
  git -C "$d" config commit.gpgsign false
  printf 'x\n' > "$d/f"
  git -C "$d" add f
  git -C "$d" commit -q -m init
  mkdir -p "$d/.gaia/scripts" "$d/.gaia/local/telemetry"
  cp "$SCRIPT" "$d/.gaia/scripts/audit-respawn-prune.sh"
  cp "$LIB" "$d/.gaia/scripts/audit-respawn-lib.sh"
  chmod +x "$d/.gaia/scripts/audit-respawn-prune.sh"
  printf '%s' "$d"
}

@test "15a: the hook exits 0 in a sandbox with the prune script present" {
  local sandbox
  sandbox="$(make_hook_sandbox)"
  cd "$sandbox" || return 1
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
}

@test "15b: the hook exits 0 in a sandbox with the prune script renamed away (adopter-clone no-op)" {
  local sandbox
  sandbox="$(make_hook_sandbox)"
  mv "$sandbox/.gaia/scripts/audit-respawn-prune.sh" "$sandbox/.gaia/scripts/audit-respawn-prune.sh.gone"
  cd "$sandbox" || return 1
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
}

@test "15e: the hook's prune delegation sits inside maintainer-only markers" {
  # The prune script is release-excluded, so a shipped hook referencing it
  # outside the markers is a runtime-dependency leak that fails the release
  # build long after this PR merges. `release runtime-deps` strips
  # marker-delimited blocks before extracting path references, so the wrap is
  # what keeps the reference invisible to the scan.
  local delegation_line start_line end_line
  delegation_line="$(grep -n 'bash .gaia/scripts/audit-respawn-prune.sh' "$HOOK_ABS" | head -1 | cut -d: -f1)"
  [ -n "$delegation_line" ]
  start_line="$(awk -v n="$delegation_line" 'NR < n && /gaia:maintainer-only:start/ { l = NR } END { print l + 0 }' "$HOOK_ABS")"
  end_line="$(awk -v n="$delegation_line" 'NR > n && /gaia:maintainer-only:end/ { print NR; exit }' "$HOOK_ABS")"
  [ "$start_line" -gt 0 ]
  [ -n "$end_line" ]
  [ "$start_line" -lt "$delegation_line" ]
  [ "$end_line" -gt "$delegation_line" ]
}

@test "15c: the reaped_by literal joins the registry entry to this script" {
  grep -qF 'audit re-spawn ledger prune sweep' "$SCRIPT" || return 1
  local reaped_by
  reaped_by="$(jq -r '.entries[] | select(.id == "audit-respawn-ledger") | .reaped_by' "$REPO_ROOT/.gaia/state-registry.json")"
  [ "$reaped_by" = "audit re-spawn ledger prune sweep" ]
}

@test "15d: the session-start path reaps the registered ledger path (out-of-window gone, in-window survives)" {
  local sandbox ledger
  sandbox="$(make_hook_sandbox)"
  ledger="$(ledger_for "$sandbox")"
  append_record "$ledger" "$(epoch_ts 1)" "in-1"
  append_record "$ledger" "$(epoch_ts 200)" "out-1"
  cd "$sandbox" || return 1
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$ledger" | tr -d ' ')" = "1" ]
  grep -qF "in-1" "$ledger" || return 1
  grep -qF "out-1" "$ledger" && return 1
  return 0
}

# ========== mutation proof: each mechanism, one at a time ==========
#
# Every mutant is a throwaway copy (mutant_script above); the tracked $SCRIPT
# is never touched, so there is nothing to restore afterward.

@test "mutation: deleting the age filter (pass every line through) turns test 5 red" {
  local root ledger mutant
  root="$(make_root)"; ledger="$(ledger_for "$root")"
  append_record "$ledger" "$(epoch_ts 200)" "out-1"
  append_record "$ledger" "$(epoch_ts 150)" "out-2"
  mutant="$(mutant_script 's/\$epoch == null or \$epoch >= \$cutoff/true/')"
  run bash "$mutant" "$root"
  [ "$status" -eq 0 ]
  # Correct behavior (test 5) is a zero-byte file; the mutant must NOT
  # produce one -- both records pass straight through.
  [ -s "$ledger" ]
}

@test "mutation: reversing the cap's ordering (keep oldest, not newest) turns test 9d red" {
  local root ledger ts mutant
  root="$(make_root)"; ledger="$(ledger_for "$root")"
  ts="$(epoch_ts 1)"
  append_bulk "$ledger" 998 "$ts" "in"
  append_record "$ledger" "$(epoch_ts 200)" "oow-200"
  append_record "$ledger" "$(epoch_ts 180)" "oow-180"
  append_record "$ledger" "$(epoch_ts 150)" "oow-150"
  append_record "$ledger" "$(epoch_ts 120)" "oow-120"
  append_record "$ledger" "$(epoch_ts 100)" "oow-100"
  mutant="$(mutant_script 's/-k1,1nr/-k1,1n/')"
  GAIA_AUDIT_RESPAWN_MAX_RECORDS=1000 run bash "$mutant" "$root"
  [ "$status" -eq 0 ]
  local survivors; survivors="$(branches_in "$ledger" | grep '^oow-')"
  # Correct behavior (test 9d) keeps oow-120 and oow-100 (the newest). The
  # reversed mutant must keep the OLDEST pair instead.
  [ "$survivors" = "$(printf 'oow-200\noow-180')" ]
}

@test "mutation: making the cap absolute (naive tail -n \$max over the post-age result) turns test 9a red" {
  local root ledger ts mutant lineno
  root="$(make_root)"; ledger="$(ledger_for "$root")"
  ts="$(epoch_ts 1)"
  append_bulk "$ledger" 1200 "$ts" "in"
  # The unique K-only selection line ('$2 == "K" { print $1 }' <<<"$classified",
  # the in-window-survivors half of the final selection, i.e. the "post-age
  # result"); appending "| tail -n \"\$cap\"" to it is the naive absolute-cap
  # bug the contract warns against.
  lineno="$(grep -nF '2 == "K" { print' "$SCRIPT" | head -1 | cut -d: -f1)"
  mutant="$(mutant_script "${lineno}s/\$/ | tail -n \"\$cap\"/")"
  GAIA_AUDIT_RESPAWN_MAX_RECORDS=1000 run bash "$mutant" "$root"
  [ "$status" -eq 0 ]
  # Correct behavior (test 9a) keeps all 1200. The absolute-cap mutant must
  # wrongly truncate to 1000.
  [ "$(wc -l < "$ledger" | tr -d ' ')" = "1000" ]
}

@test "mutation: dropping malformed lines instead of keeping them turns test 6/7 red" {
  local root ledger mutant
  root="$(make_root)"; ledger="$(ledger_for "$root")"
  printf 'not json at all\n' >> "$ledger"
  printf '{"schema":1,"branch":"no-ts"}\n' >> "$ledger"
  mutant="$(mutant_script 's/\$epoch == null or \$epoch >= \$cutoff/\$epoch >= \$cutoff/')"
  run bash "$mutant" "$root"
  [ "$status" -eq 0 ]
  # Correct behavior (tests 6, 7) keeps both. The mutant reclassifies a null
  # epoch as out-of-window, and with a tiny default-cap fixture the cap arm's
  # budget is 0, so both are dropped.
  [ ! -s "$ledger" ]
}

@test "mutation: taking the line number from jq's input_line_number turns test 4b red" {
  local root ledger mutant
  root="$(make_root)"; ledger="$(ledger_for "$root")"
  append_record "$ledger" "$(epoch_ts 1)" "in-first"
  append_record "$ledger" "$(epoch_ts 200)" "out-middle"
  printf '{"schema":1,"ts":"%s","branch":"in-last","head":"aaaa","merge_base":"bbbb","member":"code-audit-frontend","digest":"cccc","cleared":false}' \
    "$(epoch_ts 2)" >> "$ledger"
  # Restore the second numbering scheme wholesale: jq reads the ledger
  # directly and numbers the rows itself, while the selection pass counts with
  # awk's FNR. Removing the awk pass is what makes the mutation bite, since
  # that pass also re-terminates the final line; leaving it in place would hand
  # jq an already-normalized stream where its own counter is correct.
  mutant="$(mutant_script 's#awk -v OFS="\$tab" .{ print FNR, \$0 }. "\$ledger"#cat "$ledger"#; s#(\$row\[:\$i\]) as \$n#(input_line_number | tostring) as $n#; s#(\$row\[(\$i + 1):\]) as \$line#$row as $line#')"
  run bash "$mutant" "$root"
  [ "$status" -eq 0 ]
  # Correct behavior (test 4b) keeps in-first and in-last and drops
  # out-middle. The mutant must NOT reproduce that.
  local survivors; survivors="$(branches_in "$ledger")"
  [ "$survivors" = "$(printf 'in-first\nin-last')" ] && return 1
  return 0
}

@test "mutation: removing the retention floor clamp (raw env var) turns test 8b red" {
  local root ledger mutant
  root="$(make_root)"; ledger="$(ledger_for "$root")"
  append_record "$ledger" "$(epoch_ts 20)" "aged-20"
  mutant="$(mutant_script 's/days="\$(gaia_respawn_retention_days)"/days="\${GAIA_AUDIT_RESPAWN_RETENTION_DAYS:-90}"/')"
  GAIA_AUDIT_RESPAWN_RETENTION_DAYS=10 run bash "$mutant" "$root"
  [ "$status" -eq 0 ]
  # Correct behavior (test 8b) keeps the 20-day record (floored to 45).
  # The unfloored mutant applies the raw 10-day window and drops it.
  [ ! -s "$ledger" ]
}
