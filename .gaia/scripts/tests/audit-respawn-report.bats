#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/audit-respawn-report.sh: the query over
# the audit re-spawn breadcrumb ledger that reports how many Code Audit Team
# re-spawns are attributable to a peer's merge versus the branch's own edits.
#
# Criteria 1-23 (from the task plan) run on hand-written fixture ledgers,
# built via the `rec` helper below, which is the right way to pin the
# query's arithmetic precisely. The final test is deliberately different: it
# rebuilds a real peer-merge fixture through the actual oracle
# (resolve-audit-spawn.sh) in an isolated sandbox and runs this script
# against the ledger those oracle runs actually produced, proving the writer
# and this query agree on what "peer-merge" means.
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/audit-respawn-report.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
# Every expected count below is a literal worked out by hand from its
# fixture: no test recomputes the query's own predicates.

setup() {
  THIS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SCRIPT="$THIS_DIR/../audit-respawn-report.sh"
  LIB="$THIS_DIR/../audit-respawn-lib.sh"
  [ -x "$SCRIPT" ] || skip "audit-respawn-report.sh not executable"
  [ -f "$LIB" ] || skip "audit-respawn-lib.sh not found"
  command -v jq >/dev/null 2>&1 || skip "jq required"
  # shellcheck source=/dev/null
  source "$LIB"

  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT"
  LEDGER="$(gaia_respawn_ledger_path "$ROOT")"
}

# Shared fixture + assertion helpers

# ts_ago <seconds>: an ISO-8601 UTC timestamp <seconds> in the past. Built
# from `date -u +%s` arithmetic plus jq's `todateiso8601`, matching the
# script's own epoch handling -- never `date -v`/`date -d`.
ts_ago() {
  local secs="$1"
  jq -rn --argjson e "$(($(date -u +%s) - secs))" '$e | todateiso8601'
}

# rec <branch> <member> <ts> <digest> <merge_base> <cleared>: appends one
# C2-shaped record to $LEDGER. `head` is a fixed placeholder: the query
# never reads it.
rec() {
  local branch="$1" member="$2" ts="$3" digest="$4" merge_base="$5" cleared="$6"
  mkdir -p "$(dirname "$LEDGER")"
  printf '{"schema":1,"ts":"%s","branch":"%s","head":"h","merge_base":"%s","member":"%s","digest":"%s","cleared":%s}\n' \
    "$ts" "$branch" "$merge_base" "$member" "$digest" "$cleared" >>"$LEDGER"
}

# stdout_only / stderr_only <args...>: the script's stdout or stderr alone,
# since `run` merges both into $output.
stdout_only() {
  "$SCRIPT" "$@" 2>/dev/null
}
# SC2069: deliberate capture-stderr / discard-stdout order.
# shellcheck disable=SC2069
stderr_only() {
  "$SCRIPT" "$@" 2>&1 1>/dev/null
}

# extract_num <label>: the first run of digits on the line of the global
# $output (set by the most recent `run`) that contains LABEL. Only parses
# the rendered text; does not recompute the query.
extract_num() {
  local label="$1"
  grep -F "$label" <<<"$output" | head -1 | grep -oE '[0-9]+' | head -1
}

# A PATH whose dir carries every binary the script needs EXCEPT jq, so
# `command -v jq` fails and the script's own jq-required guard fires.
# Mirrors resolve-audit-spawn.bats's path_without_jq.
path_without_jq() {
  local d="$BATS_TEST_TMPDIR/nojq-bin" b p
  mkdir -p "$d"
  for b in env bash sh git awk sed grep sort head tail tr cat cut wc dirname basename mktemp date rm mkdir printf test expr; do
    p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$d/$b"
  done
  printf '%s' "$d"
}

# 1. --help

@test "criterion 1: --help prints usage and exits 0" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  grep -qF "Usage: audit-respawn-report.sh" <<<"$output" || return 1
}

# 2-3. Absent / empty ledger

@test "criterion 2: absent ledger reports all-zero counts, exit 0, text names window and ledger path" {
  run "$SCRIPT" --root "$ROOT"
  [ "$status" -eq 0 ]
  grep -qF "window:" <<<"$output" || return 1
  grep -qF "$LEDGER" <<<"$output" || return 1

  run "$SCRIPT" --root "$ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.records' <<<"$output")" = "0" ]
  [ "$(jq -r '.transitions' <<<"$output")" = "0" ]
  [ "$(jq -r '.peer_merge_respawns' <<<"$output")" = "0" ]
  [ "$(jq -r '.own_change_respawns' <<<"$output")" = "0" ]
  [ "$(jq -r '.peer_merge_rotations_upper' <<<"$output")" = "0" ]
}

@test "criterion 3: empty ledger file behaves the same as absent" {
  mkdir -p "$(dirname "$LEDGER")"
  : >"$LEDGER"
  run "$SCRIPT" --root "$ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.records' <<<"$output")" = "0" ]
}

# 4-6. Unanswerable queries: exit 1, stderr diagnostic, nothing on stdout

@test "criterion 4: an unknown flag exits 1 with a stderr diagnostic and no stdout" {
  run "$SCRIPT" --root "$ROOT" --bogus
  [ "$status" -eq 1 ]
  [ -z "$(stdout_only --root "$ROOT" --bogus)" ]
  [ -n "$(stderr_only --root "$ROOT" --bogus)" ]
}

@test "criterion 5: --since abc and --since \"\" both exit 1 with no stdout" {
  run "$SCRIPT" --root "$ROOT" --since abc
  [ "$status" -eq 1 ]
  [ -z "$(stdout_only --root "$ROOT" --since abc)" ]
  [ -n "$(stderr_only --root "$ROOT" --since abc)" ]

  run "$SCRIPT" --root "$ROOT" --since ""
  [ "$status" -eq 1 ]
  [ -z "$(stdout_only --root "$ROOT" --since "")" ]
  [ -n "$(stderr_only --root "$ROOT" --since "")" ]
}

@test "criterion 5b: a leading-zero --since is read in base 10, not as octal" {
  # `$(( ))` reads a leading zero as octal, so an un-normalized `030` would
  # silently report a 24-day window while the text still echoed "030 days",
  # and `08` is not octal at all: the arithmetic errors, leaves its target
  # unset, and trips `set -u` with a raw bash diagnostic in place of this
  # script's own message. The `10#` guard is what prevents both, and without
  # this test nothing turns red if a future edit drops it.
  local since_ts expected_ts
  run "$SCRIPT" --root "$ROOT" --json --since 030
  [ "$status" -eq 0 ]
  [ "$(jq -r '.window_days' <<<"$output")" = "30" ]
  since_ts="$(jq -r '.since' <<<"$output")"
  expected_ts="$(jq -rn --argjson e "$(( $(date -u +%s) - 30 * 86400 ))" '$e | todateiso8601')"
  # Same day, so a second's clock drift between the two calls cannot flake it.
  [ "${since_ts%T*}" = "${expected_ts%T*}" ]

  run "$SCRIPT" --root "$ROOT" --json --since 08
  [ "$status" -eq 0 ]
  [ "$(jq -r '.window_days' <<<"$output")" = "8" ]
}

@test "criterion 6: jq absent from PATH exits 1, stderr diagnostic, nothing on stdout" {
  local nojq
  nojq="$(path_without_jq)"
  run env PATH="$nojq" "$SCRIPT" --root "$ROOT"
  [ "$status" -eq 1 ]
  [ -z "$(PATH="$nojq" "$SCRIPT" --root "$ROOT" 2>/dev/null)" ]
}

# 7. UAT-004 headline case

@test "criterion 7: two branches each carrying a peer-merge transition report peer_merge_respawns=2, text and json" {
  rec "A" "memberX" "$(ts_ago 3600)" "d1" "m1" true
  rec "A" "memberX" "$(ts_ago 1800)" "d2" "m2" false
  rec "B" "memberX" "$(ts_ago 3500)" "e1" "n1" true
  rec "B" "memberX" "$(ts_ago 1700)" "e2" "n2" false

  run "$SCRIPT" --root "$ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.peer_merge_respawns' <<<"$output")" = "2" ]

  run "$SCRIPT" --root "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(extract_num 'peer-merge re-spawns:')" = "2" ]
}

# 8. Own-change vs peer-merge, both directions in one fixture

@test "criterion 8: an own-change transition counts in own_change_respawns and not in peer_merge_respawns" {
  rec "A" "memberX" "$(ts_ago 3600)" "d1" "m1" true
  rec "A" "memberX" "$(ts_ago 1800)" "d2" "m1" false # merge_base unchanged

  run "$SCRIPT" --root "$ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.own_change_respawns' <<<"$output")" = "1" ]
  [ "$(jq -r '.peer_merge_respawns' <<<"$output")" = "0" ]
}

# 9. merge_base moves, digest doesn't: rotated is false, counts nowhere

@test "criterion 9: merge_base moves but digest is unchanged counts nowhere" {
  rec "A" "memberX" "$(ts_ago 3600)" "dsame" "m1" true
  rec "A" "memberX" "$(ts_ago 1800)" "dsame" "m2" false

  run "$SCRIPT" --root "$ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.transitions' <<<"$output")" = "1" ]
  [ "$(jq -r '.peer_merge_respawns' <<<"$output")" = "0" ]
  [ "$(jq -r '.own_change_respawns' <<<"$output")" = "0" ]
  [ "$(jq -r '.peer_merge_rotations_upper' <<<"$output")" = "0" ]
}

# 10. Never cleared: counts in the upper bound, not the respawn count

@test "criterion 10: a member never cleared counts in peer_merge_rotations_upper but not peer_merge_respawns" {
  rec "A" "memberX" "$(ts_ago 3600)" "d1" "m1" false
  rec "A" "memberX" "$(ts_ago 1800)" "d2" "m2" false

  run "$SCRIPT" --root "$ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.peer_merge_rotations_upper' <<<"$output")" = "1" ]
  [ "$(jq -r '.peer_merge_respawns' <<<"$output")" = "0" ]
}

# 11. Two members on the same branch pair independently

@test "criterion 11: two members on the same branch pair independently, not across each other" {
  # Interleaved chronologically: X1, Y1, X2, Y2. Each member's OWN pair is
  # an own-change transition (merge_base constant per member, digest
  # rotates, clearance lost). A naive whole-file pairing that ignored
  # `member` would instead consecutively pair (X1,Y1), (Y1,X2), (X2,Y2):
  # the middle pair alone would spuriously satisfy rotated (different
  # members' digests always differ) + base_moved (mX != mY) +
  # lost_clearance (Y1 cleared true -> X2 cleared false), inflating
  # peer_merge_respawns to 1 it must never reach.
  rec "A" "memberX" "$(ts_ago 4000)" "dx1" "mX" true
  rec "A" "memberY" "$(ts_ago 3500)" "dy1" "mY" true
  rec "A" "memberX" "$(ts_ago 3000)" "dx2" "mX" false
  rec "A" "memberY" "$(ts_ago 2500)" "dy2" "mY" false

  run "$SCRIPT" --root "$ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.transitions' <<<"$output")" = "2" ]
  [ "$(jq -r '.own_change_respawns' <<<"$output")" = "2" ]
  [ "$(jq -r '.peer_merge_respawns' <<<"$output")" = "0" ]
}

# 12. The same member on two branches pairs independently

@test "criterion 12: the same member on two branches pairs independently, not across each other" {
  # Same shape of proof as criterion 11, with branch and member swapped:
  # one member, two branches, interleaved chronologically.
  rec "P" "memberZ" "$(ts_ago 4000)" "p1" "mP" true
  rec "Q" "memberZ" "$(ts_ago 3500)" "q1" "mQ" true
  rec "P" "memberZ" "$(ts_ago 3000)" "p2" "mP" false
  rec "Q" "memberZ" "$(ts_ago 2500)" "q2" "mQ" false

  run "$SCRIPT" --root "$ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.transitions' <<<"$output")" = "2" ]
  [ "$(jq -r '.own_change_respawns' <<<"$output")" = "2" ]
  [ "$(jq -r '.peer_merge_respawns' <<<"$output")" = "0" ]
}

# 13. Window boundary

@test "criterion 13: a pair is counted iff its LATER record falls inside the window" {
  # In-window pair: earlier record outside a 1-day window, later inside.
  rec "IN" "memberX" "$(ts_ago 172800)" "d1" "m1" true  # 2 days ago
  rec "IN" "memberX" "$(ts_ago 43200)" "d2" "m2" false  # 12 hours ago
  # Out-of-window pair: both records fall outside the 1-day window.
  rec "OUT" "memberX" "$(ts_ago 259200)" "e1" "n1" true # 3 days ago
  rec "OUT" "memberX" "$(ts_ago 172800)" "e2" "n2" false # 2 days ago

  run "$SCRIPT" --root "$ROOT" --json --since 1
  [ "$status" -eq 0 ]
  [ "$(jq -r '.transitions' <<<"$output")" = "1" ]
  [ "$(jq -r '.peer_merge_respawns' <<<"$output")" = "1" ]
}

# 14. records is independent of transitions

@test "criterion 14: records counts records in window independently of transitions" {
  rec "SOLO" "memberX" "$(ts_ago 1800)" "d1" "m1" true # no partner: +1 records, +0 transitions
  rec "PAIR" "memberX" "$(ts_ago 3600)" "e1" "m1" true
  rec "PAIR" "memberX" "$(ts_ago 1800)" "e2" "m2" false

  run "$SCRIPT" --root "$ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.records' <<<"$output")" = "3" ]
  [ "$(jq -r '.transitions' <<<"$output")" = "1" ]
}

# 15. Out-of-order input sorts by ts within each group

@test "criterion 15: out-of-order input lines produce the same counts as sorted input" {
  local l1 l2 l3 l4
  l1="$(printf '{"schema":1,"ts":"%s","branch":"A","head":"h","merge_base":"m1","member":"memberX","digest":"d1","cleared":true}' "$(ts_ago 3600)")"
  l2="$(printf '{"schema":1,"ts":"%s","branch":"A","head":"h","merge_base":"m2","member":"memberX","digest":"d2","cleared":false}' "$(ts_ago 1800)")"
  l3="$(printf '{"schema":1,"ts":"%s","branch":"B","head":"h","merge_base":"n1","member":"memberX","digest":"e1","cleared":true}' "$(ts_ago 3500)")"
  l4="$(printf '{"schema":1,"ts":"%s","branch":"B","head":"h","merge_base":"n2","member":"memberX","digest":"e2","cleared":false}' "$(ts_ago 1700)")"

  mkdir -p "$(dirname "$LEDGER")"
  # Deliberately shuffled, not chronological and not grouped by branch.
  printf '%s\n%s\n%s\n%s\n' "$l4" "$l1" "$l3" "$l2" >"$LEDGER"

  run "$SCRIPT" --root "$ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.transitions' <<<"$output")" = "2" ]
  [ "$(jq -r '.peer_merge_respawns' <<<"$output")" = "2" ]
}

# 16. Malformed line skipped

@test "criterion 16: a malformed line is skipped; the remaining records still produce correct counts" {
  rec "A" "memberX" "$(ts_ago 3600)" "d1" "m1" true
  printf 'not valid json at all\n' >>"$LEDGER"
  rec "A" "memberX" "$(ts_ago 1800)" "d2" "m2" false

  run "$SCRIPT" --root "$ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.peer_merge_respawns' <<<"$output")" = "1" ]
}

# 17. Empty digest / merge_base never satisfy rotated / base_moved

@test "criterion 17: an empty merge_base or digest never satisfies base_moved / rotated" {
  # Empty merge_base on both records of the pair: base_moved stays false
  # (empty is not "both non-empty") even though the digest rotates. That
  # makes this a legitimate OWN-CHANGE transition, not a peer-merge one --
  # an unresolvable origin/main must never inflate the peer-merge count.
  rec "A" "memberX" "$(ts_ago 3600)" "d1" "" true
  rec "A" "memberX" "$(ts_ago 1800)" "d2" "" false
  # Empty digest on both records of the pair: rotated stays false even
  # though merge_base changes, so this pair counts nowhere at all.
  rec "B" "memberY" "$(ts_ago 3600)" "" "m1" true
  rec "B" "memberY" "$(ts_ago 1800)" "" "m2" false

  run "$SCRIPT" --root "$ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.peer_merge_respawns' <<<"$output")" = "0" ]
  [ "$(jq -r '.own_change_respawns' <<<"$output")" = "1" ]
  [ "$(jq -r '.peer_merge_rotations_upper' <<<"$output")" = "0" ]
}

# 18. --json parses under jq -e . with numeric counts

@test "criterion 18: --json output parses under jq -e . and all five counts are numbers" {
  run "$SCRIPT" --root "$ROOT" --json
  [ "$status" -eq 0 ]
  jq -e . >/dev/null 2>&1 <<<"$output" || return 1
  jq -e '[.records,.transitions,.peer_merge_respawns,.own_change_respawns,.peer_merge_rotations_upper] | all(type=="number")' \
    >/dev/null 2>&1 <<<"$output" || return 1
}

# 19. Text output prints all three caveats

@test "criterion 19: text output prints all three caveats" {
  run "$SCRIPT" --root "$ROOT"
  [ "$status" -eq 0 ]
  grep -qF "so within its class this is an upper bound" <<<"$output" || return 1
  grep -qF "is a lower bound on total incidence" <<<"$output" || return 1
  grep -qF "attribution is a query over recorded facts" <<<"$output" || return 1
}

# 24. The one end-to-end join: a real oracle ledger, not a fixture.
#
# Every criterion above runs on a hand-written fixture. This rebuilds
# task-breadcrumb-writer's UAT-002 peer-merge fixture against the REAL
# oracle (resolve-audit-spawn.sh) in its own isolated sandbox -- mirroring
# resolve-audit-spawn.bats's own setup -- then runs THIS script against the
# ledger those oracle runs actually produced. No hand-written line appears
# in that ledger.

e2e_write_full_roster() {
  local sb="$1"
  cat >"$sb/.gaia/audit-ci.yml" <<'YAML'
auditors:
  - name: code-audit-frontend
    globs:
      - "app/**"
      - "test/**"
      - ".storybook/**"
    scope: adopter
    push_fixes: true
    default: true
  - name: code-audit-maintainer-shell
    globs:
      - ".gaia/**/*.sh"
      - ".gaia/**/*.bats"
      - ".claude/hooks/**/*.sh"
      - ".specify/extensions/gaia/lib/*.sh"
      - ".github/**/*.sh"
      - ".github/**/*.bats"
    scope: maintainer-only
    push_fixes: false
  - name: code-audit-maintainer-node
    globs:
      - ".gaia/cli/src/**"
    scope: maintainer-only
    push_fixes: false
YAML
}

e2e_stage() {
  local sb="$1" p
  shift
  for p in "$@"; do
    mkdir -p "$sb/$(dirname "$p")"
    printf 'x\n' >"$sb/$p"
    git -C "$sb" add "$p"
  done
}

e2e_commit() {
  git -C "$1" commit --quiet -m "$2"
}

e2e_member_digest_for() {
  local sb="$1" member="$2"
  bash -c '. "$1"; audit_member_digest "$2" "$3"' _ \
    "$THIS_DIR/../../../.claude/hooks/lib/audit-digest.sh" "$sb" "$member"
}

e2e_write_marker() {
  local sb="$1" member="$2" digest sha tree infix sidecar
  digest="$(e2e_member_digest_for "$sb" "$member")"
  sha="$(git -C "$sb" rev-parse HEAD)"
  tree="$(git -C "$sb" rev-parse 'HEAD^{tree}')"
  if [ "$member" = "code-audit-frontend" ]; then
    infix=""
    sidecar="true"
  else
    infix=".$member"
    sidecar="false"
  fi
  mkdir -p "$sb/.gaia/local/audit"
  printf '{"version":"1.6.1","schema":3,"member":"%s","provenance":"earned","digest":"%s","tree":"%s","sha":"%s","audited_at":"2026-07-14T10:00:00Z","sidecar":%s}\n' \
    "$member" "$digest" "$tree" "$sha" "$sidecar" \
    >"$sb/.gaia/local/audit/${digest}${infix}.ok"
}

e2e_sync_origin_main() {
  local sb="$1" sha
  sha="$(git -C "$sb" rev-parse main)"
  git -C "$sb" update-ref refs/remotes/origin/main "$sha"
}

# Advances origin/main by one commit that actually changes PATH's content to
# CONTENT: a real content diff, so absorbing it genuinely rotates the
# member's digest. Built via a throwaway GIT_INDEX_FILE so the sandbox's
# real index and checked-out working tree are untouched; only the
# remote-tracking ref moves.
e2e_advance_origin_main_with_change() {
  local sb="$1" path="$2" content="$3" parent idx blob new_tree new_commit
  parent="$(git -C "$sb" rev-parse main)"
  idx="$BATS_TEST_TMPDIR/e2e-idx-$RANDOM"
  GIT_INDEX_FILE="$idx" git -C "$sb" read-tree main
  blob="$(printf '%s\n' "$content" | git -C "$sb" hash-object -w --stdin)"
  GIT_INDEX_FILE="$idx" git -C "$sb" update-index --add --cacheinfo "100644,${blob},${path}"
  new_tree="$(GIT_INDEX_FILE="$idx" git -C "$sb" write-tree)"
  rm -f "$idx"
  new_commit="$(git -C "$sb" commit-tree "$new_tree" -p "$parent" -m "origin change to $path")"
  git -C "$sb" update-ref refs/remotes/origin/main "$new_commit"
}

e2e_run_oracle() {
  (cd "$1" && ./.gaia/scripts/resolve-audit-spawn.sh 2>/dev/null)
}

@test "criterion 24: end-to-end join - a real oracle ledger reports peer_merge_respawns >= 1" {
  local sb resolver_src oracle_src lib_dir
  sb="$BATS_TEST_TMPDIR/e2e-sandbox"
  resolver_src="$THIS_DIR/../resolve-audit-members.sh"
  oracle_src="$THIS_DIR/../resolve-audit-spawn.sh"
  lib_dir="$THIS_DIR/../../../.claude/hooks/lib"
  [ -x "$resolver_src" ] || skip "resolve-audit-members.sh not executable"
  [ -x "$oracle_src" ] || skip "resolve-audit-spawn.sh not executable"

  mkdir -p "$sb/.gaia/scripts" "$sb/.claude/hooks/lib"
  printf '1.6.1\n' >"$sb/.gaia/VERSION"

  git -C "$sb" init --quiet --initial-branch=main
  git -C "$sb" config user.email "test@example.com"
  git -C "$sb" config user.name "Test"
  git -C "$sb" config commit.gpgsign false

  echo "# readme" >"$sb/README.md"
  git -C "$sb" add README.md
  git -C "$sb" commit --quiet -m "init"
  git -C "$sb" checkout --quiet -b feature

  cp "$resolver_src" "$sb/.gaia/scripts/resolve-audit-members.sh"
  chmod +x "$sb/.gaia/scripts/resolve-audit-members.sh"
  cp "$oracle_src" "$sb/.gaia/scripts/resolve-audit-spawn.sh"
  chmod +x "$sb/.gaia/scripts/resolve-audit-spawn.sh"
  cp "$LIB" "$sb/.gaia/scripts/audit-respawn-lib.sh"
  cp "$lib_dir/audit-scope.sh" "$sb/.claude/hooks/lib/audit-scope.sh"
  cp "$lib_dir/audit-machinery.sh" "$sb/.claude/hooks/lib/audit-machinery.sh"
  cp "$lib_dir/audit-clearance.sh" "$sb/.claude/hooks/lib/audit-clearance.sh"
  cp "$lib_dir/audit-digest.sh" "$sb/.claude/hooks/lib/audit-digest.sh"

  e2e_write_full_roster "$sb"
  e2e_stage "$sb" .gaia/scripts/y.sh
  e2e_commit "$sb" "chore"
  e2e_write_marker "$sb" code-audit-maintainer-shell
  e2e_sync_origin_main "$sb"

  e2e_run_oracle "$sb" >/dev/null

  # origin/main gains a REAL content change to a file the shell member owns.
  e2e_advance_origin_main_with_change "$sb" .gaia/scripts/peer-owned.sh "peer change"
  git -C "$sb" merge --quiet --no-edit refs/remotes/origin/main

  e2e_run_oracle "$sb" >/dev/null

  run "$SCRIPT" --root "$sb" --json
  [ "$status" -eq 0 ]
  local peer_json
  peer_json="$(jq -r '.peer_merge_respawns' <<<"$output")"
  [ "$peer_json" -ge 1 ] || return 1

  run "$SCRIPT" --root "$sb"
  [ "$status" -eq 0 ]
  local peer_text
  peer_text="$(extract_num 'peer-merge re-spawns:')"
  [ "$peer_text" -ge 1 ] || return 1
}
