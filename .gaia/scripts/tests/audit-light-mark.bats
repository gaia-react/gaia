#!/usr/bin/env bats
# Tests for .gaia/scripts/audit-light-mark.sh, the only writer of a light
# clearance. Every case runs in a light sandbox (a scratch repository carrying
# copies of this checkout's audit machinery). Each refusal is driven from a
# well-formed twin that clears, so a script that printed a constant would fail
# one side of every pair.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# bats file_tags=whole-tree

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck source=.gaia/scripts/tests/helpers/light-sandbox.sh
  . "$REPO_ROOT/.gaia/scripts/tests/helpers/light-sandbox.sh"
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  FRONTEND="code-audit-frontend"
  REPLY_FILE="$BATS_TEST_TMPDIR/reply.json"
}

teardown() {
  chmod -R u+rwx "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

# expect_line <text>: the last `run` exited 0 and printed exactly <text>.
expect_line() {
  [ "$status" -eq 0 ] || { printf 'status %s, output: %s\n' "$status" "$output" >&2; return 1; }
  [ "$output" = "$1" ] || { printf 'want %s, got: %s\n' "$1" "$output" >&2; return 1; }
}

expect_full() {
  expect_line "$(printf 'full\t%s' "$1")"
}

audit_directory() {
  printf '%s/.gaia/local/audit' "$LSB_ROOT"
}

light_directory() {
  printf '%s/.gaia/local/audit/light' "$LSB_ROOT"
}

# marker_path: the earned marker the sandbox's frontend member would have for
# the current digest.
marker_path() {
  printf '%s/%s.ok' "$(audit_directory)" "$(lsb_member_digest "$FRONTEND")"
}

verdict_path() {
  printf '%s/%s.%s.verdict.json' "$(light_directory)" "$(lsb_member_digest "$FRONTEND")" "$FRONTEND"
}

record_path() {
  printf '%s/%s.%s.route.json' "$(light_directory)" "$(lsb_member_digest "$FRONTEND")" "$FRONTEND"
}

ledger_path() {
  printf '%s/%s.reviews.jsonl' "$(light_directory)" "$LSB_SLUG"
}

telemetry_log() {
  printf '%s/.gaia/local/telemetry/audit-light-routing.jsonl' "$LSB_ROOT"
}

# assert_no_marker: no earned marker for the current digest.
assert_no_marker() {
  [ ! -e "$(marker_path)" ] || { printf 'unexpected marker %s\n' "$(marker_path)" >&2; return 1; }
}

# prepare_light [--maintainer]: a full clearance, a small owned Markdown delta,
# and a router run that routed it light.
prepare_light() {
  lsb_init "$@"
  lsb_full_clearance "$FRONTEND"
  lsb_commit frontend/app/notes.md "$(printf 'one\ntwo\nthree')"
  lsb_route "$FRONTEND"
  [ "$output" = "$(printf 'light\tlight-eligible')" ] || { printf 'router: %s\n' "$output" >&2; return 1; }
}

clear_reply_to_file() {
  lsb_clear_reply "$FRONTEND" >"$REPLY_FILE"
}

# reply_edit <jq-filter>: rewrite the reply file through a jq filter.
reply_edit() {
  jq -c "$1" "$REPLY_FILE" >"$REPLY_FILE.new" && mv "$REPLY_FILE.new" "$REPLY_FILE"
}

# full_sidecar_base: the shared key base members use, resolved the way members
# resolve it (the resolver reads its repository from the working directory).
full_sidecar_base() {
  local reference
  reference="$(cd "$LSB_ROOT" && bash .github/audit/resolve-audit-base.sh --member "$FRONTEND" 2>/dev/null | sed -n '3p')"
  lsb_git merge-base "$reference" HEAD
}

# preseed_full_sidecar: a full round's findings sidecar under the key a light
# write would also use, so a clobber would be visible.
preseed_full_sidecar() {
  printf '[]' | bash "$LSB_ROOT/.gaia/scripts/audit-write-findings.sh" --root "$LSB_ROOT" --member "$FRONTEND" \
    --base "$(full_sidecar_base)" --findings - >/dev/null
}

full_sidecar_files() {
  find "$(audit_directory)" -maxdepth 1 -name "*.$FRONTEND.findings.json" ! -name '*.light.findings.json'
}

light_sidecar_files() {
  find "$(audit_directory)" -maxdepth 1 -name "*.$FRONTEND.light.findings.json"
}

# --- happy path -------------------------------------------------------------

@test "a clear verdict on the routed delta clears light with a marker, a light sidecar and a merge the gate allows" {
  prepare_light
  preseed_full_sidecar
  local full_sidecar before
  full_sidecar="$(full_sidecar_files)"
  [ -n "$full_sidecar" ]
  before="$(cksum <"$full_sidecar")"
  clear_reply_to_file
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_line "light-cleared"
  [ "$(jq -r '[.provenance, .review, .digest, .tree] | join(" ")' "$(marker_path)")" = "earned light $(lsb_member_digest "$FRONTEND") $LSB_TREE" ]
  [ "$(light_sidecar_files | wc -l | tr -d ' ')" = "1" ]
  [ "$(jq -c '[.review, .member, (.findings | length)]' "$(light_sidecar_files)")" = "[\"light\",\"$FRONTEND\",0]" ]
  [ "$(cksum <"$full_sidecar")" = "$before" ]
  [ "$(jq -r .review "$full_sidecar")" = "null" ]
  lsb_run_merge_hook 41
  [ "$status" -eq 0 ]
  grep -qF '"permissionDecision": "deny"' <<<"$output" && return 1
  true
}

@test "a reply named by file path clears exactly like the same reply on stdin" {
  prepare_light
  clear_reply_to_file
  lsb_mark_file "$FRONTEND" "$REPLY_FILE"
  expect_line "light-cleared"
  [ "$(jq -r '[.provenance, .review, .digest, .tree] | join(" ")' "$(marker_path)")" = "earned light $(lsb_member_digest "$FRONTEND") $LSB_TREE" ]
  [ "$(light_sidecar_files | wc -l | tr -d ' ')" = "1" ]
  cmp -s "$REPLY_FILE" "$(verdict_path)"
}

@test "a reply file that is not clear is refused by the same checks as stdin" {
  prepare_light
  clear_reply_to_file
  reply_edit '.files[0].verdict = "escalate"'
  lsb_mark_file "$FRONTEND" "$REPLY_FILE"
  expect_full escalate
  assert_no_marker
}

@test "a missing reply file prints full verdict-noop and writes no marker" {
  prepare_light
  lsb_mark_file "$FRONTEND" "$BATS_TEST_TMPDIR/no-such-reply.json"
  expect_full verdict-noop
  assert_no_marker
  [ -z "$(find "$(light_directory)" -name '.verdict.*')" ]
}

@test "a missing reply file never falls back to reading the reply from stdin" {
  prepare_light
  clear_reply_to_file
  run bash -c 'bash "$1" --root "$2" --member "$3" --verdict "$4" <"$5"' _ \
    "$LSB_ROOT/.gaia/scripts/audit-light-mark.sh" "$LSB_ROOT" "$FRONTEND" "$BATS_TEST_TMPDIR/no-such-reply.json" "$REPLY_FILE"
  expect_full verdict-noop
  assert_no_marker
  # Control: the same reply on stdin through the stdin form clears.
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_line "light-cleared"
}

@test "an unreadable reply file prints full verdict-noop and writes no marker" {
  prepare_light
  clear_reply_to_file
  # A directory cannot be read as a reply on any platform or user, root included.
  mkdir "$BATS_TEST_TMPDIR/reply-directory"
  lsb_mark_file "$FRONTEND" "$BATS_TEST_TMPDIR/reply-directory"
  expect_full verdict-noop
  assert_no_marker
  # A mode-000 file, where the user is not root and the mode is enforced.
  cp "$REPLY_FILE" "$BATS_TEST_TMPDIR/locked-reply.json"
  chmod 000 "$BATS_TEST_TMPDIR/locked-reply.json"
  if [ ! -r "$BATS_TEST_TMPDIR/locked-reply.json" ]; then
    lsb_mark_file "$FRONTEND" "$BATS_TEST_TMPDIR/locked-reply.json"
    expect_full verdict-noop
    assert_no_marker
  fi
  # Control: the same reply, readable, clears.
  lsb_mark_file "$FRONTEND" "$REPLY_FILE"
  expect_line "light-cleared"
}

@test "the reply is persisted byte for byte to the keyed verdict path" {
  prepare_light
  clear_reply_to_file
  printf '\n' >>"$REPLY_FILE"
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_line "light-cleared"
  cmp -s "$REPLY_FILE" "$(verdict_path)"
}

@test "an empty reply then a clear reply: verdict-noop, then light-cleared" {
  prepare_light
  lsb_mark "$FRONTEND" ""
  expect_full verdict-noop
  assert_no_marker
  clear_reply_to_file
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_line "light-cleared"
}

@test "the same sequence works in a sandbox with every maintainer-only region stripped" {
  lsb_init --maintainer
  lsb_strip_maintainer_only
  [ ! -e "$LSB_ROOT/.gaia/scripts/audit-light-telemetry.sh" ]
  grep -qF 'audit-light-telemetry.sh' "$LSB_ROOT/.gaia/scripts/audit-light-mark.sh" && return 1
  bash -n "$LSB_ROOT/.gaia/scripts/audit-light-mark.sh"
  lsb_full_clearance "$FRONTEND"
  lsb_commit frontend/app/notes.md "one line"
  lsb_route "$FRONTEND"
  expect_line "$(printf 'light\tlight-eligible')"
  clear_reply_to_file
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_line "light-cleared"
  [ "$(jq -r .review "$(marker_path)")" = "light" ]
}

# --- escalate ---------------------------------------------------------------

@test "an escalate verdict prints full escalate, writes no marker and one escalate ledger line" {
  prepare_light
  lsb_escalate_reply "$FRONTEND" >"$REPLY_FILE"
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full escalate
  assert_no_marker
  [ "$(wc -l <"$(ledger_path)" | tr -d ' ')" = "1" ]
  [ "$(jq -r .verdict "$(ledger_path)")" = "escalate" ]
}

@test "one escalated file among clear files escalates the whole review" {
  lsb_init
  lsb_full_clearance "$FRONTEND"
  lsb_commit frontend/app/one.md "one"
  lsb_commit frontend/app/two.md "two"
  lsb_route "$FRONTEND"
  expect_line "$(printf 'light\tlight-eligible')"
  clear_reply_to_file
  [ "$(jq '.files | length' "$REPLY_FILE")" = "2" ]
  reply_edit '.files[0].verdict = "escalate"'
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full escalate
  assert_no_marker
}

# --- malformed and mismatched replies, each with the clear twin above -----------

@test "non-JSON stdin prints full verdict-noop and writes no marker" {
  prepare_light
  printf 'looks fine to me\n' >"$REPLY_FILE"
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full verdict-noop
  assert_no_marker
  cmp -s "$REPLY_FILE" "$(verdict_path)"
}

@test "JSON without files prints full verdict-noop" {
  prepare_light
  clear_reply_to_file
  reply_edit 'del(.files)'
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full verdict-noop
  assert_no_marker
}

@test "an unknown verdict value prints full verdict-malformed" {
  prepare_light
  clear_reply_to_file
  reply_edit '.verdict = "approve"'
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full verdict-malformed
  assert_no_marker
}

@test "an unknown per-file verdict value prints full verdict-malformed" {
  prepare_light
  clear_reply_to_file
  reply_edit '.files[0].verdict = "approve"'
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full verdict-malformed
  assert_no_marker
}

@test "a wrong schema number prints full verdict-malformed" {
  prepare_light
  clear_reply_to_file
  reply_edit '.schema = 2'
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full verdict-malformed
  assert_no_marker
}

@test "a reply that is a JSON array prints full verdict-noop" {
  prepare_light
  printf '[{"path":"frontend/app/notes.md","verdict":"clear"}]' >"$REPLY_FILE"
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full verdict-noop
  assert_no_marker
}

@test "a files array one short prints full verdict-noop (the expected count catches it)" {
  lsb_init
  lsb_full_clearance "$FRONTEND"
  lsb_commit frontend/app/one.md "one"
  lsb_commit frontend/app/two.md "two"
  lsb_route "$FRONTEND"
  clear_reply_to_file
  reply_edit '.files |= .[0:1]'
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full verdict-noop
  assert_no_marker
}

@test "a file path the route record does not list prints full verdict-mismatch" {
  prepare_light
  clear_reply_to_file
  reply_edit '.files[0].path = "frontend/app/other.md"'
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full verdict-mismatch
  assert_no_marker
}

@test "a duplicated file path in place of a routed one prints full verdict-mismatch" {
  lsb_init
  lsb_full_clearance "$FRONTEND"
  lsb_commit frontend/app/one.md "one"
  lsb_commit frontend/app/two.md "two"
  lsb_route "$FRONTEND"
  clear_reply_to_file
  reply_edit '.files[1].path = .files[0].path'
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full verdict-mismatch
  assert_no_marker
}

@test "a wrong digest in the verdict prints full verdict-mismatch" {
  prepare_light
  clear_reply_to_file
  reply_edit '.digest = "0000000000000000000000000000000000000000000000000000000000000000"'
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full verdict-mismatch
  assert_no_marker
}

@test "a wrong tree in the verdict prints full verdict-mismatch" {
  prepare_light
  clear_reply_to_file
  reply_edit '.tree = "0000000000000000000000000000000000000001"'
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full verdict-mismatch
  assert_no_marker
}

@test "a wrong member in the verdict prints full verdict-mismatch" {
  prepare_light
  clear_reply_to_file
  reply_edit '.member = "code-audit-maintainer-shell"'
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full verdict-mismatch
  assert_no_marker
}

@test "a failure after the reply was persisted appends one failed ledger line" {
  prepare_light
  clear_reply_to_file
  reply_edit '.verdict = "approve"'
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full verdict-malformed
  [ "$(wc -l <"$(ledger_path)" | tr -d ' ')" = "1" ]
  [ "$(jq -r '[.member, .verdict, .digest, .tree] | join(" ")' "$(ledger_path)")" = "$FRONTEND failed $(lsb_member_digest "$FRONTEND") $LSB_TREE" ]
}

# --- the route record -------------------------------------------------------

@test "an absent route record prints full no-route-record" {
  lsb_init
  lsb_full_clearance "$FRONTEND"
  lsb_commit frontend/app/notes.md "one line"
  printf '{}' >"$REPLY_FILE"
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full no-route-record
  assert_no_marker
}

@test "an unparseable route record prints full no-route-record" {
  prepare_light
  clear_reply_to_file
  printf 'not json' >"$(record_path)"
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full no-route-record
  assert_no_marker
}

@test "a route record naming another digest prints full route-stale" {
  prepare_light
  clear_reply_to_file
  jq -c '.digest = "1111111111111111111111111111111111111111111111111111111111111111"' "$(record_path)" >"$BATS_TEST_TMPDIR/record.new"
  mv "$BATS_TEST_TMPDIR/record.new" "$(record_path)"
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full route-stale
  assert_no_marker
}

@test "a route record naming another tree prints full route-stale" {
  prepare_light
  clear_reply_to_file
  jq -c '.tree = "0000000000000000000000000000000000000001"' "$(record_path)" >"$BATS_TEST_TMPDIR/record.new"
  mv "$BATS_TEST_TMPDIR/record.new" "$(record_path)"
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full route-stale
  assert_no_marker
}

@test "a route record whose route is full prints full route-not-light" {
  prepare_light
  clear_reply_to_file
  jq -c '.route = "full"' "$(record_path)" >"$BATS_TEST_TMPDIR/record.new"
  mv "$BATS_TEST_TMPDIR/record.new" "$(record_path)"
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full route-not-light
  assert_no_marker
}

@test "a record stored light that the fresh router now calls full prints full recheck-full" {
  prepare_light
  clear_reply_to_file
  printf 'dirty\n' >>"$LSB_ROOT/frontend/app/notes.md"
  lsb_route "$FRONTEND" --check
  expect_line "$(printf 'full\tdirty-tree')"
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full recheck-full
  assert_no_marker
}

@test "a hard-full edit committed after routing never clears light" {
  prepare_light
  clear_reply_to_file
  lsb_commit .claude/hooks/lib/zz-added-after-routing.txt "touched after routing"
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  [ "$status" -eq 0 ]
  case "$output" in
    "$(printf 'full\tno-route-record')" | "$(printf 'full\troute-stale')" | "$(printf 'full\trecheck-full')") ;;
    *) printf 'unexpected: %s\n' "$output" >&2; return 1 ;;
  esac
  assert_no_marker
}

@test "HEAD moving during the review by an owned change prints full and writes no marker" {
  prepare_light
  clear_reply_to_file
  lsb_commit frontend/app/later.md "committed while the reviewer ran"
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  [ "$status" -eq 0 ]
  case "$output" in
    "$(printf 'full\tno-route-record')" | "$(printf 'full\troute-stale')") ;;
    *) printf 'unexpected: %s\n' "$output" >&2; return 1 ;;
  esac
  assert_no_marker
}

# --- refusal ----------------------------------------------------------------

@test "a same-digest refusal prints full refusal-present and is left untouched" {
  prepare_light
  clear_reply_to_file
  local refusal before
  # A refusal whose tree is no commit in the walk range is invisible to the
  # router, so only this script's own check can see it.
  refusal="$(lsb_marker_json "$FRONTEND" refused "" "0000000000000000000000000000000000000001" "$(awk 'NF { print; exit }' "$LSB_ROOT/.gaia/VERSION" | tr -d '[:space:]')" "$(lsb_member_digest "$FRONTEND")")"
  [ -f "$refusal" ]
  before="$(cksum <"$refusal")"
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full refusal-present
  assert_no_marker
  [ -f "$refusal" ]
  [ "$(cksum <"$refusal")" = "$before" ]
}

# --- refusal-anchored checklist ---------------------------------------------

# prepare_refusal_anchored <content-after-the-refusal-file-or-empty>: five owned
# lines refused with a warning on line 2 and a suggestion on line 4, then the
# repair (every line rewritten, or the given file body), routed light.
prepare_refusal_anchored() {
  lsb_init
  lsb_commit_lines frontend/app/notes.md 5 line
  lsb_refuse_with_findings "$FRONTEND" "[$(lsb_finding frontend/app/notes.md 2 warning false),$(lsb_finding frontend/app/notes.md 4 suggestion false)]"
  if [ -n "${1:-}" ]; then
    lsb_commit frontend/app/notes.md "$1"
  else
    lsb_commit_lines frontend/app/notes.md 5 fixed
  fi
  lsb_route "$FRONTEND"
  [ "$output" = "$(printf 'light\trefusal-anchored')" ] || { printf 'router: %s\n' "$output" >&2; return 1; }
}

@test "a reply resolving every open finding over a delta that changes every cited line clears light" {
  prepare_refusal_anchored
  clear_reply_to_file
  [ "$(jq -c .resolved "$REPLY_FILE")" = '["r1-1","r1-2"]' ]
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_line "light-cleared"
  [ "$(jq -r '[.provenance, .review, .tree] | join(" ")' "$(marker_path)")" = "earned light $LSB_TREE" ]
}

@test "a refusal-anchored clear accounts for the open findings in the full sidecar and retires the ledger entries" {
  prepare_refusal_anchored
  clear_reply_to_file
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_line "light-cleared"
  local sidecar ledger
  sidecar="$(full_sidecar_files)"
  [ -f "$sidecar" ]
  [ "$(jq -c '[(.findings | length), [.resolutions[].entry_id]]' "$sidecar")" = '[0,["r1-1","r1-2"]]' ]
  ledger="$(find "$(audit_directory)" -maxdepth 1 -name '*.rerun.json')"
  [ -z "$ledger" ] || { printf 'ledger left behind: %s\n' "$ledger" >&2; return 1; }
}

@test "a reply whose resolved list omits an open finding prints full verdict-incomplete" {
  prepare_refusal_anchored
  clear_reply_to_file
  reply_edit '.resolved = ["r1-1"]'
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full verdict-incomplete
  assert_no_marker
}

@test "a reply with no resolved list at all prints full verdict-incomplete" {
  prepare_refusal_anchored
  clear_reply_to_file
  reply_edit 'del(.resolved)'
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full verdict-incomplete
  assert_no_marker
}

@test "a resolved list naming a key the checklist does not hold prints full verdict-mismatch" {
  prepare_refusal_anchored
  clear_reply_to_file
  reply_edit '.resolved = ["r1-1","r1-2","r9-9"]'
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full verdict-mismatch
  assert_no_marker
}

@test "a resolved value that is not a list of strings prints full verdict-malformed" {
  prepare_refusal_anchored
  clear_reply_to_file
  reply_edit '.resolved = "r1-1"'
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full verdict-malformed
  assert_no_marker
  reply_edit '.resolved = ["r1-1", 2]'
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full verdict-malformed
  assert_no_marker
}

@test "an escalating reply on a refusal-anchored route still prints full escalate" {
  prepare_refusal_anchored
  lsb_escalate_reply "$FRONTEND" >"$REPLY_FILE"
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full escalate
  assert_no_marker
}

@test "a forged all-resolved reply over a cited line the delta never touched prints full checklist-unchanged" {
  prepare_refusal_anchored "$(printf 'line 1\nfixed 2\nline 3\nline 4\nline 5')"
  clear_reply_to_file
  [ "$(jq -c .resolved "$REPLY_FILE")" = '["r1-1","r1-2"]' ]
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full checklist-unchanged
  assert_no_marker
}

@test "the checklist-unchanged refusal is what blocks the forged reply: a scratch mark script without it clears" {
  prepare_refusal_anchored "$(printf 'line 1\nfixed 2\nline 3\nline 4\nline 5')"
  clear_reply_to_file
  local script="$LSB_ROOT/.gaia/scripts/audit-light-mark.sh"
  # shellcheck disable=SC2016
  grep -qF '[ "$touched" = "true" ] || _light_mark_full checklist-unchanged' "$script"
  # shellcheck disable=SC2016
  sed 's/\[ "\$touched" = "true" \] || _light_mark_full checklist-unchanged/:/' "$script" >"$script.mutant"
  grep -qF '[ "$touched" = "true" ]' "$script.mutant" && return 1
  run bash "$script.mutant" --root "$LSB_ROOT" --member "$FRONTEND" --verdict - <"$REPLY_FILE"
  expect_line "light-cleared"
  [ -f "$(marker_path)" ]
}

@test "a pure insertion beside each cited line counts as touching it" {
  prepare_refusal_anchored "$(printf 'line 1
line 2
inserted a
line 3
line 4
inserted b
line 5')"
  clear_reply_to_file
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_line "light-cleared"
}

@test "a pure insertion beside only one cited line leaves the other unchanged" {
  prepare_refusal_anchored "$(printf 'line 1
line 2
inserted a
line 3
line 4
line 5')"
  clear_reply_to_file
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full checklist-unchanged
  assert_no_marker
}

# --- telemetry and ledger ---------------------------------------------------

@test "in a maintainer sandbox a clear run appends a light_outcome with the reviewer tokens" {
  prepare_light --maintainer
  clear_reply_to_file
  run bash -c 'bash "$1" --root "$2" --member "$3" --verdict - --reviewer-tokens 4321 --reviewer-duration-ms 987 <"$4"' _ \
    "$LSB_ROOT/.gaia/scripts/audit-light-mark.sh" "$LSB_ROOT" "$FRONTEND" "$REPLY_FILE"
  expect_line "light-cleared"
  [ "$(grep -c '"light_outcome"' "$(telemetry_log)")" = "1" ]
  [ "$(grep '"light_outcome"' "$(telemetry_log)" | jq -r '[.verdict, (.tokens | tostring), (.duration_ms | tostring)] | join(" ")')" = "clear 4321 987" ]
}

@test "a telemetry directory the script cannot write still prints light-cleared" {
  prepare_light --maintainer
  clear_reply_to_file
  chmod 0555 "$(dirname "$(telemetry_log)")"
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_line "light-cleared"
  [ "$(jq -r .review "$(marker_path)")" = "light" ]
}

@test "after one clear and one escalate run the ledger has two lines in the documented shape" {
  prepare_light
  clear_reply_to_file
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_line "light-cleared"
  lsb_commit frontend/app/more.md "more"
  lsb_route "$FRONTEND"
  expect_line "$(printf 'light\tlight-eligible')"
  lsb_escalate_reply "$FRONTEND" >"$REPLY_FILE"
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full escalate
  [ "$(wc -l <"$(ledger_path)" | tr -d ' ')" = "2" ]
  [ "$(jq -c '[keys[]]' "$(ledger_path)" | sort -u)" = '["at","digest","member","tree","verdict"]' ]
  [ "$(jq -r .verdict "$(ledger_path)" | paste -sd, -)" = "clear,escalate" ]
  jq -e '.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$(ledger_path)" >/dev/null
}

# --- cwd independence -------------------------------------------------------

@test "run from an unrelated directory the sidecar still lands under the sandbox root" {
  prepare_light
  clear_reply_to_file
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  run bash -c 'cd "$5" && bash "$1" --root "$2" --member "$3" --verdict - <"$4"' _ \
    "$LSB_ROOT/.gaia/scripts/audit-light-mark.sh" "$LSB_ROOT" "$FRONTEND" "$REPLY_FILE" "$BATS_TEST_TMPDIR/elsewhere"
  expect_line "light-cleared"
  [ "$(light_sidecar_files | wc -l | tr -d ' ')" = "1" ]
  [ -z "$(find "$BATS_TEST_TMPDIR/elsewhere" -type f)" ]
}

@test "a script that drops the subshell cd fails closed from an unrelated directory" {
  prepare_light
  clear_reply_to_file
  local script="$LSB_ROOT/.gaia/scripts/audit-light-mark.sh"
  # shellcheck disable=SC2016
  grep -qF '(cd "$root" && bash "$root/.github/audit/resolve-audit-base.sh"' "$script"
  # shellcheck disable=SC2016
  sed 's|(cd "\$root" \&\& bash "\$root/.github/audit/resolve-audit-base.sh"|(bash "$root/.github/audit/resolve-audit-base.sh"|' "$script" >"$script.mutant"
  # shellcheck disable=SC2016
  grep -qF '(cd "$root" && bash "$root/.github/audit/resolve-audit-base.sh"' "$script.mutant" && return 1
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  run bash -c 'cd "$5" && bash "$1" --root "$2" --member "$3" --verdict - <"$4"' _ \
    "$script.mutant" "$LSB_ROOT" "$FRONTEND" "$REPLY_FILE" "$BATS_TEST_TMPDIR/elsewhere"
  expect_full sidecar-failed
  assert_no_marker
}

# --- degraded ---------------------------------------------------------------

@test "an underivable digest prints full degraded and persists nothing" {
  prepare_light --maintainer
  clear_reply_to_file
  local telemetry_lines_before
  telemetry_lines_before="$(grep -c '"light_outcome"' "$(telemetry_log)" || true)"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$LSB_ROOT/.gaia/scripts/audit-member-digest.sh"
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full degraded
  [ -z "$(find "$(light_directory)" -name '*.verdict.json')" ]
  [ ! -e "$(ledger_path)" ]
  [ "$(grep -c '"light_outcome"' "$(telemetry_log)" || true)" = "$telemetry_lines_before" ]
  [ -z "$(find "$(audit_directory)" -maxdepth 1 -name '*.ok' -newer "$REPLY_FILE")" ]
}

# --- usage ------------------------------------------------------------------

@test "usage errors exit 2 and print no decision line" {
  lsb_init
  local script="$LSB_ROOT/.gaia/scripts/audit-light-mark.sh"
  run bash "$script" --root "$LSB_ROOT" --member "$FRONTEND" </dev/null
  [ "$status" -eq 2 ]
  run bash "$script" --root "$LSB_ROOT" --member "$FRONTEND" --verdict </dev/null
  [ "$status" -eq 2 ]
  run bash "$script" --root "$LSB_ROOT" --member "$FRONTEND" --verdict - --reviewer-tokens many </dev/null
  [ "$status" -eq 2 ]
  run bash "$script" --root "$LSB_ROOT" --member "$FRONTEND" --verdict - --reviewer-duration-ms 1.5 </dev/null
  [ "$status" -eq 2 ]
  run bash "$script" --root relative/path --member "$FRONTEND" --verdict - </dev/null
  [ "$status" -eq 2 ]
  run bash "$script" --root "$LSB_ROOT" --member ../escape --verdict - </dev/null
  [ "$status" -eq 2 ]
  run bash "$script" --root "$LSB_ROOT" --member "$FRONTEND" --verdict - --unknown </dev/null
  [ "$status" -eq 2 ]
  grep -qE 'light-cleared|^full' <<<"$output" && return 1
  true
}

# --- structural guards ------------------------------------------------------

# review_light_offenders <repo>: tracked *.sh files outside the allowlist that
# spell the literal. The allowlist is the two writers, the one caller, and any
# shell file under a tests directory.
review_light_offenders() {
  local scanned=0 file
  while IFS= read -r -d '' file; do
    scanned=$((scanned + 1))
    case "$file" in
      .gaia/scripts/audit-write-clearance.sh | .gaia/scripts/audit-write-findings.sh | .gaia/scripts/audit-light-mark.sh) continue ;;
      tests/* | */tests/*) continue ;;
    esac
    grep -qF -- '--review light' "$1/$file" 2>/dev/null && printf '%s\n' "$file"
  done < <(git -C "$1" ls-files -z -- '*.sh')
  [ "$scanned" -gt 0 ] || printf 'scanned nothing\n'
  return 0
}

@test "the review-light literal appears in no tracked shell file outside the allowlist" {
  local offenders
  offenders="$(review_light_offenders "$REPO_ROOT")"
  [ -z "$offenders" ] || { printf 'offenders: %s\n' "$offenders" >&2; return 1; }
  # Non-vacuity: the scan reads files that do carry the literal.
  grep -qF -- '--review light' "$REPO_ROOT/.gaia/scripts/audit-write-clearance.sh"
  grep -qF -- '--review light' "$REPO_ROOT/.gaia/scripts/audit-write-findings.sh"
  grep -qF -- '--review light' "$REPO_ROOT/.gaia/scripts/audit-light-mark.sh"
  [ "$(git -C "$REPO_ROOT" ls-files -z -- '*.sh' | tr -cd '\0' | wc -c | tr -d ' ')" -gt 50 ]
}

@test "the guard fails on a scratch fixture with a second shell caller, and ignores prose, bats and tests-directory files" {
  local fixture="$BATS_TEST_TMPDIR/guard-fixture"
  git init -q -b main "$fixture"
  mkdir -p "$fixture/.gaia/scripts/tests/helpers" "$fixture/wiki"
  printf 'x --review light\n' >"$fixture/.gaia/scripts/audit-write-clearance.sh"
  printf 'x --review light\n' >"$fixture/.gaia/scripts/audit-write-findings.sh"
  printf 'x --review light\n' >"$fixture/.gaia/scripts/audit-light-mark.sh"
  printf 'x --review light\n' >"$fixture/.gaia/scripts/tests/helpers/helper.sh"
  printf 'x --review light\n' >"$fixture/wiki/page.md"
  printf 'x --review light\n' >"$fixture/.gaia/scripts/tests/case.bats"
  git -C "$fixture" add -A
  [ -z "$(review_light_offenders "$fixture")" ]
  printf 'bash writer --review light\n' >"$fixture/.gaia/scripts/other-caller.sh"
  git -C "$fixture" add -A
  [ "$(review_light_offenders "$fixture")" = ".gaia/scripts/other-caller.sh" ]
}

@test "the guard reports a scan of nothing instead of passing an empty tree" {
  local fixture="$BATS_TEST_TMPDIR/guard-empty"
  git init -q -b main "$fixture"
  [ "$(review_light_offenders "$fixture")" = "scanned nothing" ]
}

# fenced_telemetry_references <file>: prints `fenced` when every line naming the
# telemetry script sits between the shell maintainer-only markers and at least
# one such line exists.
fenced_telemetry_references() {
  awk -v marker="gaia:""maintainer-only" '
    index($0, "# " marker ":start") { inside = 1; next }
    index($0, "# " marker ":end") { inside = 0; next }
    /audit-light-telemetry\.sh/ { seen++; if (!inside) bad++ }
    END { if (seen > 0 && bad == 0) print "fenced"; else print "unfenced" }
  ' "$1"
}

@test "every line naming the telemetry script sits inside maintainer-only markers" {
  [ "$(fenced_telemetry_references "$REPO_ROOT/.gaia/scripts/audit-light-mark.sh")" = "fenced" ]
}

@test "the fence check fails once the markers are removed from a scratch copy" {
  local copy="$BATS_TEST_TMPDIR/mark-unfenced.sh"
  grep -v 'gaia:maintainer-only' "$REPO_ROOT/.gaia/scripts/audit-light-mark.sh" >"$copy"
  grep -qF 'audit-light-telemetry.sh' "$copy"
  [ "$(fenced_telemetry_references "$copy")" = "unfenced" ]
}
