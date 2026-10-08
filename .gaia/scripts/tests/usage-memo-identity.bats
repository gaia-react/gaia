#!/usr/bin/env bats
#
# Identity of the memo-backed usage readout (SPEC-089): the working tree's
# usage.sh against the pre-change e4b57e23 scripts pinned under
# fixtures/usage/baseline-e4b57e23/, over the committed identity fixture. Every
# comparison asserts the outputs carry figures first (a degenerate output would
# let a byte comparison pass with nothing behind it), and every re-attribution
# case requires the appended rows to change the probed output before it checks
# identity, so a change that never reaches the readout fails the test.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/usage-memo-identity.bats
#
# The jq programs and row literals are single-quoted on purpose: their `$` names
# are jq's. `run` sets `status`, which the linter cannot see.
# shellcheck disable=SC2016,SC2154

bats_require_minimum_version 1.5.0

setup() {
  # shellcheck source=.gaia/scripts/tests/helpers/usage-memo-env.sh
  . "$BATS_TEST_DIRNAME/helpers/usage-memo-env.sh"
  umemo_setup
  umemo_load_store identity
  PROBES="$UM_FIXTURES/identity/probes.json"
  CAPTURE_DIRECTORY="$BATS_TEST_TMPDIR/cap"
  MEMO="$UM_TELEMETRY_DIRECTORY/usage-branch-memo.json"
  mkdir -p "$CAPTURE_DIRECTORY"
}

# capture <tag> <old|new> <args...>: one readout, stdout, stderr, exit status and
# memo trace captured to $CAPTURE_DIRECTORY/<tag>.{out,err,rc,trace}. Always returns 0; the
# callers compare the captures.
capture() {
  local tag="$1" variant="$2" exit_status=0
  shift 2
  rm -f "$CAPTURE_DIRECTORY/$tag.trace"
  GAIA_USAGE_MEMO_TRACE="$CAPTURE_DIRECTORY/$tag.trace" UM_OUTPUT_FILE="$CAPTURE_DIRECTORY/$tag.out" UM_ERROR_FILE="$CAPTURE_DIRECTORY/$tag.err" "u_$variant" "$@" || exit_status=$?
  printf '%s\n' "$exit_status" >"$CAPTURE_DIRECTORY/$tag.rc"
  return 0
}

# same_capture <tagA> <tagB>: stdout, stderr and exit status all match.
same_capture() {
  assert_same "$CAPTURE_DIRECTORY/$1.out" "$CAPTURE_DIRECTORY/$2.out" &&
    assert_same "$CAPTURE_DIRECTORY/$1.err" "$CAPTURE_DIRECTORY/$2.err" &&
    assert_same "$CAPTURE_DIRECTORY/$1.rc" "$CAPTURE_DIRECTORY/$2.rc"
}

# memo_trace_has <tag> <event>: the capture's trace holds that exact line.
memo_trace_has() { [ -f "$CAPTURE_DIRECTORY/$1.trace" ] && grep -qxF -- "$2" "$CAPTURE_DIRECTORY/$1.trace"; }

# clean_trace <tag>: the readout stayed on the memo path (no legacy fallback, no
# coverage-miss rerun), so an identity pass is not the legacy sequence agreeing
# with itself.
clean_trace() {
  [ ! -f "$CAPTURE_DIRECTORY/$1.trace" ] && return 0
  grep -qE '^(fallback=legacy|rerun=miss)' "$CAPTURE_DIRECTORY/$1.trace" && {
    printf 'trace of %s left the memo path:\n%s\n' "$1" "$(cat "$CAPTURE_DIRECTORY/$1.trace")" >&2
    return 1
  }
  return 0
}

# cold_new <tag> <args...> / warm_new <tag> <args...>: a u_new readout with the
# memo deleted first / kept, asserting the trace says which it was.
cold_new() {
  local tag="$1"
  shift
  rm -f "$MEMO"
  capture "$tag" new "$@"
  memo_trace_has "$tag" "path=cold reason=missing" || { printf 'cold run %s traced:\n%s\n' "$tag" "$(cat "$CAPTURE_DIRECTORY/$tag.trace" 2>/dev/null)" >&2; return 1; }
  clean_trace "$tag"
}
warm_new() {
  local tag="$1"
  shift
  capture "$tag" new "$@"
  memo_trace_has "$tag" "path=warm" || { printf 'warm run %s traced:\n%s\n' "$tag" "$(cat "$CAPTURE_DIRECTORY/$tag.trace" 2>/dev/null)" >&2; return 1; }
  clean_trace "$tag"
}

# append_row <usage|links> <json>: one row onto the test's own store copy.
append_row() {
  local store_file="$UM_TELEMETRY_DIRECTORY/$1.jsonl"
  if [ -s "$store_file" ] && [ -n "$(tail -c 1 "$store_file")" ]; then printf '\n' >>"$store_file"; fi
  printf '%s\n' "$2" >>"$store_file"
}

# probe_field <pr> <field>: a probes.json value for that PR's probe.
probe_field() { jq -r --argjson pr_number "$1" --arg field "$2" '[.probes[] | select(.pr == $pr_number)][0][$field] // ""' "$PROBES"; }

# initiative_block <file> <ref>: the `[initiative <ref> ...]` header and the
# indented lines under it, up to the next header.
initiative_block() {
  awk -v heading_prefix="[initiative $2 " 'index($0, heading_prefix) == 1 { printing = 1; print; next } /^\[/ { printing = 0 } printing' "$1"
}

# new_branch_rows <suffix>: appends a segment and a merge row for a branch no
# store names, derived from anchors.new_branch (suffix "" is the anchor
# itself); sets NB_KEY. Its parent is the root its name implies.
new_branch_rows() {
  local key
  key="$(jq -r '.anchors.new_branch.key' "$PROBES")$1"
  NB_KEY="$key"
  append_row usage '{"schema_version":1,"kind":"segment","key":"'"$key"'","session_id":"snb'"$1"'","inherit":false,"first_ts":"2026-09-29T10:00:00Z","last_ts":"2026-09-29T10:00:00Z","messages":2,"by_model":{"claude-opus-5-5":{"fresh_input":50000,"cache_write_5m":5000,"cache_write_1h":0,"cache_read":100000,"output":5000}}}'
  append_row links '{"schema_version":1,"kind":"merge","pr":2999,"key":"'"$key"'","merged_at":"2026-09-29T11:00:00Z","source":"gh-pr-merge","ts":"2026-09-29T11:00:00Z","session_id":null}'
}

# snapshot <out>: every directory and file under the scratch main root (the git
# dir excluded) with size and inode and, for every file but the memo, a content
# hash, so a created, deleted, rewritten or replaced path shows as a line.
snapshot() {
  local listed_path
  {
    find "$UM_MAIN" -path "$UM_MAIN/.git" -prune -o -type d -print
    find "$UM_MAIN" -path "$UM_MAIN/.git" -prune -o -type f -print | while IFS= read -r listed_path; do
      case "$listed_path" in
        */usage-branch-memo.json) printf '%s size=%s inode=%s\n' "$listed_path" "$(wc -c <"$listed_path" | tr -d ' ')" "$(ls -i "$listed_path" | awk '{ print $1 }')" ;;
        *) printf '%s size=%s inode=%s sha=%s\n' "$listed_path" "$(wc -c <"$listed_path" | tr -d ' ')" "$(ls -i "$listed_path" | awk '{ print $1 }')" "$(_umemo_sha256 "$listed_path")" ;;
      esac
    done
  } | LC_ALL=C sort >"$1"
}

# stores_sha <out>: sha256 of the two stores.
stores_sha() {
  local store_name
  for store_name in usage links; do printf '%s %s\n' "$store_name" "$(_umemo_sha256 "$UM_TELEMETRY_DIRECTORY/$store_name.jsonl")"; done >"$1"
}

# memo_inode: the inode of the memo file.
memo_inode() { ls -i "$MEMO" | awk '{ print $1 }'; }

# memo_inode_flips <tree>: the memo's inode differs after a save that updates an
# existing memo. The save is temp plus rename, so a reader never sees a half
# written memo; an in-place writer keeps the inode and fails.
memo_inode_flips() {
  local tree="$1" inode_before inode_after
  umemo_load_store identity || return 1
  rm -f "$MEMO"
  _umemo_run "$tree" "$CAPTURE_DIRECTORY/flip1.out" "$CAPTURE_DIRECTORY/flip1.err" pr 2302 || return 1
  [ -f "$MEMO" ] || { printf 'no memo written by the first run\n' >&2; return 1; }
  inode_before="$(memo_inode)"
  new_branch_rows -flip
  _umemo_run "$tree" "$CAPTURE_DIRECTORY/flip2.out" "$CAPTURE_DIRECTORY/flip2.err" pr --key "$NB_KEY" || return 1
  inode_after="$(memo_inode)"
  [ "$inode_before" != "$inode_after" ] || { printf 'memo inode %s unchanged by an update\n' "$inode_before" >&2; return 1; }
}

# ---------------------------------------------------------------------------

@test "UAT-002: probe identity across pr, pr --key, pr --branch and pr-branch, cold and warm" {
  local probe_count i seen=0 skipped=0 want_skipped pr key raw roots form tag args_string
  local -a args
  probe_count="$(umemo_probe_count "$PROBES")"
  [ "$probe_count" -ge 20 ]
  want_skipped="$(jq '[.probes[] | .key, .raw | select(. == null)] | length' "$PROBES")"
  # The jq above counts null keys and null raws: every one is a skipped form.
  for ((i = 0; i < probe_count; i++)); do
    pr="$(jq -r --argjson probe_position "$i" '.probes[$probe_position].pr' "$PROBES")"
    key="$(jq -r --argjson probe_position "$i" '.probes[$probe_position].key // ""' "$PROBES")"
    raw="$(jq -r --argjson probe_position "$i" '.probes[$probe_position].raw // ""' "$PROBES")"
    roots="$(jq -r --argjson probe_position "$i" '.probes[$probe_position].expect.roots_min // 0' "$PROBES")"
    umemo_check_probe "$PROBES" "$i"
    seen=$((seen + 1))
    for form in pr key branch prbranch; do
      case "$form" in
        pr) args=(pr "$pr") ;;
        key) if [ -z "$key" ]; then skipped=$((skipped + 1)); continue; fi; args=(pr --key "$key") ;;
        branch) if [ -z "$raw" ]; then skipped=$((skipped + 1)); continue; fi; args=(pr "$pr" --branch "$raw" --unconfirmed --partial) ;;
        prbranch) args=(pr-branch "$pr") ;;
      esac
      tag="$i-$form"
      if [ "$form" = pr ]; then
        # umemo_check_probe already ran u_old pr for this probe (and required exit 0).
        cp "$UM_TEMPORARY_DIRECTORY/probe-$pr.out" "$CAPTURE_DIRECTORY/$tag-old.out"
        cp "$UM_TEMPORARY_DIRECTORY/probe-$pr.err" "$CAPTURE_DIRECTORY/$tag-old.err"
        printf '0\n' >"$CAPTURE_DIRECTORY/$tag-old.rc"
      else
        capture "$tag-old" old "${args[@]}"
      fi
      args_string="${args[*]}"
      if [ "$form" != prbranch ] &&
        [ "$(jq -r --argjson probe_position "$i" '(.probes[$probe_position].expect.unresolvable // false) or (.probes[$probe_position].expect.no_spend // false)' "$PROBES")" = false ]; then
        if [ "$roots" -gt 0 ]; then assert_priced "$CAPTURE_DIRECTORY/$tag-old.out" --roots; else assert_priced "$CAPTURE_DIRECTORY/$tag-old.out"; fi
      fi
      if [ "$form" = prbranch ]; then
        # pr-branch reads only links.jsonl and never touches the memo, so one
        # run stands for both the cold and the warm pass.
        rm -f "$MEMO"
        capture "$tag-cold" new "${args[@]}"
        cp "$CAPTURE_DIRECTORY/$tag-cold.out" "$CAPTURE_DIRECTORY/$tag-warm.out"
        cp "$CAPTURE_DIRECTORY/$tag-cold.err" "$CAPTURE_DIRECTORY/$tag-warm.err"
        cp "$CAPTURE_DIRECTORY/$tag-cold.rc" "$CAPTURE_DIRECTORY/$tag-warm.rc"
      else
        cold_new "$tag-cold" "${args[@]}"
        warm_new "$tag-warm" "${args[@]}"
      fi
      same_capture "$tag-old" "$tag-cold" || { printf 'cold mismatch: %s\n' "$args_string" >&2; return 1; }
      same_capture "$tag-old" "$tag-warm" || { printf 'warm mismatch: %s\n' "$args_string" >&2; return 1; }
      [ ! -s "$CAPTURE_DIRECTORY/$tag-cold.err" ] || { printf 'cold stderr not empty for %s:\n%s\n' "$args_string" "$(cat "$CAPTURE_DIRECTORY/$tag-cold.err")" >&2; return 1; }
      [ ! -s "$CAPTURE_DIRECTORY/$tag-warm.err" ] || { printf 'warm stderr not empty for %s:\n%s\n' "$args_string" "$(cat "$CAPTURE_DIRECTORY/$tag-warm.err")" >&2; return 1; }
    done
  done
  [ "$seen" -eq "$probe_count" ]
  [ "$skipped" -eq "$want_skipped" ]
}

@test "UAT-002 guard: the figure assertion fails over a main root with no capture hooks" {
  local bare="$UM_TEMPORARY_DIRECTORY/main-nohooks"
  # The same readout, once under the registered main root and once under a bare
  # one: the first carries figures, the second must trip assert_priced.
  capture hooked new pr 2302
  assert_priced "$CAPTURE_DIRECTORY/hooked.out"
  mkdir -p "$bare/.gaia/local/telemetry"
  git -C "$bare" init -q -b main
  git -C "$bare" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false commit -q --allow-empty -m init
  cp "$UM_TELEMETRY_DIRECTORY"/usage.jsonl "$UM_TELEMETRY_DIRECTORY"/links.jsonl "$bare/.gaia/local/telemetry/"
  UM_MAIN="$bare" UM_TELEMETRY_DIRECTORY="$bare/.gaia/local/telemetry" capture bare new pr 2302
  [ -s "$CAPTURE_DIRECTORY/bare.out" ]
  run assert_priced "$CAPTURE_DIRECTORY/bare.out"
  [ "$status" -ne 0 ]
}

@test "UAT-002: a link that closes a cycle is refused identically and changes nothing" {
  local child parent before
  child="$(jq -r '.anchors.cycle.child' "$PROBES")"
  parent="$(jq -r '.anchors.cycle.parent' "$PROBES")"
  before="$(_umemo_sha256 "$UM_TELEMETRY_DIRECTORY/links.jsonl")"
  capture cyc-old old link "$child" "$parent"
  [ "$(cat "$CAPTURE_DIRECTORY/cyc-old.rc")" = 1 ]
  grep -qF 'would close a cycle' "$CAPTURE_DIRECTORY/cyc-old.err"
  capture cyc-new new link "$child" "$parent"
  [ "$(cat "$CAPTURE_DIRECTORY/cyc-new.rc")" = 1 ]
  same_capture cyc-old cyc-new
  [ "$(_umemo_sha256 "$UM_TELEMETRY_DIRECTORY/links.jsonl")" = "$before" ]
}

@test "UAT-010: initiative and reconcile are byte-identical, cold and warm" {
  local role reference seen=0
  for role in research issue spec; do
    reference="$(jq -r --arg role "$role" '.initiative_roots[$role]' "$PROBES")"
    [ -n "$reference" ] && [ "$reference" != null ]
    capture "i-$role-old" old initiative "$reference"
    grep -qF "[initiative $reference]" "$CAPTURE_DIRECTORY/i-$role-old.out"
    grep -q 'tokens ' "$CAPTURE_DIRECTORY/i-$role-old.out"
    cold_new "i-$role-cold" initiative "$reference"
    warm_new "i-$role-warm" initiative "$reference"
    same_capture "i-$role-old" "i-$role-cold"
    same_capture "i-$role-old" "i-$role-warm"
    [ ! -s "$CAPTURE_DIRECTORY/i-$role-warm.err" ]
    seen=$((seen + 1))
  done
  [ "$seen" -eq 3 ]
  capture rec-old old reconcile
  grep -q 'attributed:   tokens' "$CAPTURE_DIRECTORY/rec-old.out"
  cold_new rec-cold reconcile
  warm_new rec-warm reconcile
  same_capture rec-old rec-cold
  same_capture rec-old rec-warm
  [ ! -s "$CAPTURE_DIRECTORY/rec-warm.err" ]
}

@test "AUDIT-9: the cursor-prefilter adversarial rows reach the figures" {
  local i probe_count seen=0 pr
  # The rows the cursor prefilter could drop: a segment on a branch whose name
  # spells the cursor marker, and a real cursor row in a different key order.
  grep -qF '"key":"branch:fix/cursor-drift"' "$UM_TELEMETRY_DIRECTORY/usage.jsonl"
  grep -qF '{"kind":"cursor","schema_version":1,' "$UM_TELEMETRY_DIRECTORY/usage.jsonl"
  probe_count="$(umemo_probe_count "$PROBES")"
  for ((i = 0; i < probe_count; i++)); do
    [ "$(jq -r --argjson probe_position "$i" '.probes[$probe_position].category' "$PROBES")" = cursor_adversarial ] || continue
    pr="$(jq -r --argjson probe_position "$i" '.probes[$probe_position].pr' "$PROBES")"
    capture "cur-$pr-old" old pr "$pr"
    assert_priced "$CAPTURE_DIRECTORY/cur-$pr-old.out"
    grep -qF '  tokens: 0 (' "$CAPTURE_DIRECTORY/cur-$pr-old.out" && return 1
    cold_new "cur-$pr-cold" pr "$pr"
    warm_new "cur-$pr-warm" pr "$pr"
    grep -qF '  tokens: 0 (' "$CAPTURE_DIRECTORY/cur-$pr-cold.out" && return 1
    same_capture "cur-$pr-old" "cur-$pr-cold"
    same_capture "cur-$pr-old" "cur-$pr-warm"
    seen=$((seen + 1))
  done
  [ "$seen" -eq 3 ]
}

@test "UAT-003: a binding appended under a warm memo re-attributes the session" {
  local session_id root pr block_before block_after
  session_id="$(jq -r '.anchors.unbound_session.session_id' "$PROBES")"
  root="$(jq -r '.anchors.unbound_session.root' "$PROBES")"
  pr="$(jq -r '.anchors.unbound_session.pr' "$PROBES")"
  cold_new pre pr "$pr"
  warm_new pre pr "$pr"
  block_before="$(initiative_block "$CAPTURE_DIRECTORY/pre.out" "$root")"
  [ -n "$block_before" ]
  append_row usage '{"schema_version":1,"kind":"binding","type":"research","session_id":"'"$session_id"'","ts":"2026-09-26T13:00:00Z","ref":"'"$root"'","source":"transcript"}'
  warm_new post pr "$pr"
  block_after="$(initiative_block "$CAPTURE_DIRECTORY/post.out" "$root")"
  [ -n "$block_after" ]
  [ "$block_before" != "$block_after" ]
  capture post-old old pr "$pr"
  cold_new post-cold pr "$pr"
  same_capture post-old post
  same_capture post-old post-cold
}

@test "UAT-004: an appended edge adds a root and an appended unlink removes one" {
  local reference pr key unbound_key unbound_root unbound_pr
  reference="$(jq -r '.anchors.spare_root.ref' "$PROBES")"
  pr="$(jq -r '.anchors.spare_root.pr' "$PROBES")"
  key="$(probe_field "$pr" key)"
  cold_new e-pre pr "$pr"
  warm_new e-pre pr "$pr"
  [ -z "$(initiative_block "$CAPTURE_DIRECTORY/e-pre.out" "$reference")" ]
  append_row links '{"schema_version":1,"kind":"edge","child":"'"$key"'","parent":"'"$reference"'","source":"link-command","ts":"2026-09-30T00:00:00Z","session_id":null,"sidechain":false}'
  warm_new e-post pr "$pr"
  [ -n "$(initiative_block "$CAPTURE_DIRECTORY/e-post.out" "$reference")" ]
  [ "$(initiative_block "$CAPTURE_DIRECTORY/e-post.out" "$reference" | grep -c .)" -gt 0 ]
  capture e-post-old old pr "$pr"
  cold_new e-post-cold pr "$pr"
  same_capture e-post-old e-post
  same_capture e-post-old e-post-cold

  # The unbound_session anchor's PR prints its root through a link edge; an
  # unlink of that edge removes the root from the readout.
  unbound_pr="$(jq -r '.anchors.unbound_session.pr' "$PROBES")"
  unbound_root="$(jq -r '.anchors.unbound_session.root' "$PROBES")"
  unbound_key="$(probe_field "$unbound_pr" key)"
  warm_new u-pre pr "$unbound_pr"
  [ -n "$(initiative_block "$CAPTURE_DIRECTORY/u-pre.out" "$unbound_root")" ]
  append_row links '{"schema_version":1,"kind":"unlink","child":"'"$unbound_key"'","parent":"'"$unbound_root"'","source":"link-command","ts":"2026-09-30T01:00:00Z","session_id":null,"sidechain":false}'
  warm_new u-post pr "$unbound_pr"
  [ -z "$(initiative_block "$CAPTURE_DIRECTORY/u-post.out" "$unbound_root")" ]
  capture u-post-old old pr "$unbound_pr"
  cold_new u-post-cold pr "$unbound_pr"
  same_capture u-post-old u-post
  same_capture u-post-old u-post-cold
}

@test "UAT-007: a branch no store or memo has seen is derived on first sight" {
  local key parent body
  key="$(jq -r '.anchors.new_branch.key' "$PROBES")"
  parent="$(jq -r '.anchors.new_branch.parent' "$PROBES")"
  cold_new nb-pre pr --key "$key"
  warm_new nb-pre pr --key "$key"
  [ -z "$(initiative_block "$CAPTURE_DIRECTORY/nb-pre.out" "$parent")" ]
  body="$(sed -n 2p "$MEMO")"
  [ "$(jq -r --arg key "$key" '.derive | has($key)' <<<"$body")" = false ]
  new_branch_rows ""
  [ "$NB_KEY" = "$key" ]
  warm_new nb-post pr --key "$key"
  [ -n "$(initiative_block "$CAPTURE_DIRECTORY/nb-post.out" "$parent")" ]
  assert_priced "$CAPTURE_DIRECTORY/nb-post.out" --roots
  capture nb-old old pr --key "$key"
  cold_new nb-cold pr --key "$key"
  same_capture nb-old nb-post
  same_capture nb-old nb-cold
  warm_new nb-again pr --key "$key"
  same_capture nb-old nb-again
  body="$(sed -n 2p "$MEMO")"
  [ "$(jq -r --arg key "$key" --arg parent "$parent" '.derive[$key] | index($parent) != null' <<<"$body")" = true ]
}

# The pinned baseline cannot read a close row, so this case compares the
# working tree's warm readout with its own cold one rather than with the
# baseline.
@test "a close row appended under a warm memo moves an open-start interval, warm as cold" {
  local session_id key pr spec
  session_id="$(jq -r '.anchors.open_start.session_id' "$PROBES")"
  key="$(jq -r '.anchors.open_start.key' "$PROBES")"
  pr="$(jq -r '.anchors.open_start.pr' "$PROBES")"
  spec="SPEC-$(sed -E 's|^branch:plan/spec-([0-9]+).*|\1|' <<<"$key")"
  [ "$spec" = SPEC-506 ]
  cold_new cl-pre initiative "spec:$spec"
  warm_new cl-pre initiative "spec:$spec"
  append_row usage '{"schema_version":1,"kind":"binding","type":"close","session_id":"'"$session_id"'","ts":"2026-09-27T10:00:00Z","ref":"spec:'"$spec"'","workflow":"gaia-spec","source":"record-command"}'
  warm_new cl-post initiative "spec:$spec"
  grep -qF "  spec:$spec  tokens " "$CAPTURE_DIRECTORY/cl-post.out"
  cmp -s "$CAPTURE_DIRECTORY/cl-pre.out" "$CAPTURE_DIRECTORY/cl-post.out" && return 1
  cold_new cl-cold initiative "spec:$spec"
  same_capture cl-post cl-cold
}

@test "UAT-005: a readout writes nothing but the memo, and each update replaces it" {
  local glob template name before="$CAPTURE_DIRECTORY/snap.before" after="$CAPTURE_DIRECTORY/snap.after" subcommand i
  local -a subcommands=("pr 2305" "initiative issue:2330" "reconcile")
  stores_sha "$CAPTURE_DIRECTORY/sha.before"
  snapshot "$before"
  for subcommand in "${subcommands[@]}"; do
    rm -f "$MEMO"
    snapshot "$before"
    # shellcheck disable=SC2086
    capture "int-cold" new $subcommand
    [ "$(cat "$CAPTURE_DIRECTORY/int-cold.rc")" = 0 ]
    [ -f "$MEMO" ]
    snapshot "$after"
    [ -z "$(diff "$before" "$after" | grep '^[<>]' | grep -v 'usage-branch-memo.json')" ]
    stores_sha "$CAPTURE_DIRECTORY/sha.after"
    assert_same "$CAPTURE_DIRECTORY/sha.before" "$CAPTURE_DIRECTORY/sha.after"
    snapshot "$before"
    # shellcheck disable=SC2086
    capture "int-warm" new $subcommand
    snapshot "$after"
    [ -z "$(diff "$before" "$after" | grep '^[<>]' | grep -v 'usage-branch-memo.json')" ]
    assert_same "$CAPTURE_DIRECTORY/sha.before" "$CAPTURE_DIRECTORY/sha.after" || return 1
  done
  # The appends are the test's own writes: re-record the hashes after them,
  # then require that the readouts that absorb them leave the stores alone.
  new_branch_rows ""
  stores_sha "$CAPTURE_DIRECTORY/sha.before"
  snapshot "$before"
  inode_before="$(memo_inode)"
  capture int-update new pr --key "$NB_KEY"
  [ "$(cat "$CAPTURE_DIRECTORY/int-update.rc")" = 0 ]
  snapshot "$after"
  stores_sha "$CAPTURE_DIRECTORY/sha.after"
  assert_same "$CAPTURE_DIRECTORY/sha.before" "$CAPTURE_DIRECTORY/sha.after"
  [ -z "$(diff "$before" "$after" | grep '^[<>]' | grep -v 'usage-branch-memo.json')" ]
  [ "$inode_before" != "$(memo_inode)" ]
  [ -z "$(find "$UM_TELEMETRY_DIRECTORY" "$UM_MAIN" -path "$UM_MAIN/.git" -prune -o -name '.usage-*.tmp.*' -print)" ]
  # The memo's temp name matches the glob the state registry registers.
  glob="$(jq -r '.entries // . | (if type == "array" then . else [.[]?] end) | map(select(.id == "telemetry-usage-tmp"))[0].path' "$UM_SOURCE_ROOT/.gaia/state-registry.json")"
  [ -n "$glob" ] && [ "$glob" != null ]
  glob="${glob##*/}"
  template="$(grep -o '\.usage-branch-memo\.tmp\.X*' "$UM_NEW/.gaia/scripts/usage-memo-lib.sh" | head -n 1)"
  [ -n "$template" ]
  name="${template%%X*}abc123"
  # shellcheck disable=SC2254
  case "$name" in $glob) ;; *) printf 'temp name %s does not match registered glob %s\n' "$name" "$glob" >&2; return 1 ;; esac
}

@test "UAT-005 guard: an in-place memo writer fails the inode check" {
  local mutant_tree="$UM_TEMPORARY_DIRECTORY/tree-inplace"
  cp -R "$UM_NEW" "$mutant_tree"
  sed 's|mv -f "\$temporary_file" "\$memo"|cat "$temporary_file" >"$memo"|' "$UM_NEW/.gaia/scripts/usage-memo-lib.sh" >"$mutant_tree/.gaia/scripts/usage-memo-lib.sh"
  cmp -s "$UM_NEW/.gaia/scripts/usage-memo-lib.sh" "$mutant_tree/.gaia/scripts/usage-memo-lib.sh" && return 1
  memo_inode_flips "$UM_NEW"
  run memo_inode_flips "$mutant_tree"
  [ "$status" -ne 0 ]
}

# epoch_all <scripts dir> <corpus>: usage_epoch of every corpus value through
# that tree's own GAIA_USAGE_RESOLVE_JQ, as a JSON array of tojson strings (an
# error is captured as "error", so a value the jq cannot parse still compares).
epoch_all() {
  local scripts_directory="$1" corpus="$2"
  bash -c '
    . "$1/usage-lib.sh" && . "$1/usage-resolve-lib.sh" || exit 1
    jq -nc --slurpfile values "$2" "$GAIA_USAGE_JQ_DEFS$GAIA_USAGE_RESOLVE_JQ"'\''[$values[0][] | (try (usage_epoch | tojson) catch "error")]'\''
  ' _ "$scripts_directory" "$corpus"
}

@test "UAT-013: usage_epoch agrees with the pre-change body over the epoch corpus" {
  local corpus="$UM_FIXTURES/epoch/corpus.json" corpus_count old new
  corpus_count="$(jq 'length' "$corpus")"
  [ "$corpus_count" -ge 25 ]
  old="$(epoch_all "$UM_OLD/.gaia/scripts" "$corpus")"
  new="$(epoch_all "$UM_NEW/.gaia/scripts" "$corpus")"
  [ "$(jq 'length' <<<"$old")" -eq "$corpus_count" ]
  [ "$(jq 'length' <<<"$new")" -eq "$corpus_count" ]
  # The corpus must exercise both outcomes, or an all-null pair agrees trivially.
  [ "$(jq '[.[] | select(. != "null" and . != "\"error\"")] | length' <<<"$old")" -ge 10 ]
  [ "$(jq '[.[] | select(. == "null")] | length' <<<"$old")" -ge 5 ]
  [ "$old" = "$new" ]
}

@test "UAT-013 guard: a fast path that drops the fraction term disagrees with the baseline" {
  local corpus="$UM_FIXTURES/epoch/corpus.json" mutant_tree="$UM_TEMPORARY_DIRECTORY/tree-epoch" old new
  mkdir -p "$mutant_tree"
  cp "$UM_NEW"/.gaia/scripts/*.sh "$mutant_tree/"
  bash "$UM_FIXTURES/epoch/mutant-drop-fraction.sh" "$UM_NEW/.gaia/scripts/usage-resolve-lib.sh" "$mutant_tree/usage-resolve-lib.sh"
  old="$(epoch_all "$UM_OLD/.gaia/scripts" "$corpus")"
  new="$(epoch_all "$mutant_tree" "$corpus")"
  [ -n "$new" ]
  [ "$old" != "$new" ]
}
