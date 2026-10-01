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
  PROBES="$UM_FX/identity/probes.json"
  CAP="$BATS_TEST_TMPDIR/cap"
  MEMO="$UM_TD/usage-branch-memo.json"
  mkdir -p "$CAP"
}

# cap <tag> <old|new> <args...>: one readout, stdout, stderr, exit status and
# memo trace captured to $CAP/<tag>.{out,err,rc,trace}. Always returns 0; the
# callers compare the captures.
cap() {
  local tag="$1" who="$2" rc=0
  shift 2
  rm -f "$CAP/$tag.trace"
  GAIA_USAGE_MEMO_TRACE="$CAP/$tag.trace" UM_OUT="$CAP/$tag.out" UM_ERR="$CAP/$tag.err" "u_$who" "$@" || rc=$?
  printf '%s\n' "$rc" >"$CAP/$tag.rc"
  return 0
}

# same_cap <tagA> <tagB>: stdout, stderr and exit status all match.
same_cap() {
  assert_same "$CAP/$1.out" "$CAP/$2.out" &&
    assert_same "$CAP/$1.err" "$CAP/$2.err" &&
    assert_same "$CAP/$1.rc" "$CAP/$2.rc"
}

# memo_trace_has <tag> <event>: the capture's trace holds that exact line.
memo_trace_has() { [ -f "$CAP/$1.trace" ] && grep -qxF -- "$2" "$CAP/$1.trace"; }

# clean_trace <tag>: the readout stayed on the memo path (no legacy fallback, no
# coverage-miss rerun), so an identity pass is not the legacy sequence agreeing
# with itself.
clean_trace() {
  [ ! -f "$CAP/$1.trace" ] && return 0
  grep -qE '^(fallback=legacy|rerun=miss)' "$CAP/$1.trace" && {
    printf 'trace of %s left the memo path:\n%s\n' "$1" "$(cat "$CAP/$1.trace")" >&2
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
  cap "$tag" new "$@"
  memo_trace_has "$tag" "path=cold reason=missing" || { printf 'cold run %s traced:\n%s\n' "$tag" "$(cat "$CAP/$tag.trace" 2>/dev/null)" >&2; return 1; }
  clean_trace "$tag"
}
warm_new() {
  local tag="$1"
  shift
  cap "$tag" new "$@"
  memo_trace_has "$tag" "path=warm" || { printf 'warm run %s traced:\n%s\n' "$tag" "$(cat "$CAP/$tag.trace" 2>/dev/null)" >&2; return 1; }
  clean_trace "$tag"
}

# append_row <usage|links|cost> <json>: one row onto the test's own store copy.
append_row() {
  local f="$UM_TD/$1.jsonl"
  if [ -s "$f" ] && [ -n "$(tail -c 1 "$f")" ]; then printf '\n' >>"$f"; fi
  printf '%s\n' "$2" >>"$f"
}

# probe_field <pr> <field>: a probes.json value for that PR's probe.
probe_field() { jq -r --argjson p "$1" --arg f "$2" '[.probes[] | select(.pr == $p)][0][$f] // ""' "$PROBES"; }

# initiative_block <file> <ref>: the `[initiative <ref> ...]` header and the
# indented lines under it, up to the next header.
initiative_block() {
  awk -v h="[initiative $2 " 'index($0, h) == 1 { p = 1; print; next } /^\[/ { p = 0 } p' "$1"
}

# new_branch_rows <suffix>: appends a segment, a cost row and a merge row for a
# branch no store names, derived from anchors.new_branch (suffix "" is the
# anchor itself); sets NB_KEY. Its parent is the anchor's root.
new_branch_rows() {
  local raw key
  raw="$(jq -r '.anchors.new_branch.raw' "$PROBES")$1"
  key="$(jq -r '.anchors.new_branch.key' "$PROBES")$1"
  NB_KEY="$key"
  append_row usage '{"schema_version":1,"kind":"segment","key":"'"$key"'","session_id":"snb'"$1"'","inherit":false,"first_ts":"2026-09-29T10:00:00Z","last_ts":"2026-09-29T10:00:00Z","messages":2,"by_model":{"claude-opus-5-5":{"fresh_input":50000,"cache_write_5m":5000,"cache_write_1h":0,"cache_read":100000,"output":5000}}}'
  append_row cost '{"schema_version":1,"kind":"execute","spec_id":null,"plan_id":null,"plan_slug":null,"session_id":"snb'"$1"'","total":1000,"seq":0,"final":true,"git_branch":"'"$raw"'","ts":"2026-09-29T10:30:00Z","session_cwd":"/work/repo"}'
  append_row links '{"schema_version":1,"kind":"merge","pr":2999,"key":"'"$key"'","merged_at":"2026-09-29T11:00:00Z","source":"gh-pr-merge","ts":"2026-09-29T11:00:00Z","session_id":null}'
}

# snapshot <out>: every directory and file under the scratch main root (the git
# dir excluded) with size and inode and, for every file but the memo, a content
# hash, so a created, deleted, rewritten or replaced path shows as a line.
snapshot() {
  local f
  {
    find "$UM_MAIN" -path "$UM_MAIN/.git" -prune -o -type d -print
    find "$UM_MAIN" -path "$UM_MAIN/.git" -prune -o -type f -print | while IFS= read -r f; do
      case "$f" in
        */usage-branch-memo.json) printf '%s size=%s inode=%s\n' "$f" "$(wc -c <"$f" | tr -d ' ')" "$(ls -i "$f" | awk '{ print $1 }')" ;;
        *) printf '%s size=%s inode=%s sha=%s\n' "$f" "$(wc -c <"$f" | tr -d ' ')" "$(ls -i "$f" | awk '{ print $1 }')" "$(_umemo_sha256 "$f")" ;;
      esac
    done
  } | LC_ALL=C sort >"$1"
}

# stores_sha <out>: sha256 of the three stores.
stores_sha() {
  local s
  for s in usage links cost; do printf '%s %s\n' "$s" "$(_umemo_sha256 "$UM_TD/$s.jsonl")"; done >"$1"
}

# memo_inode: the inode of the memo file.
memo_inode() { ls -i "$MEMO" | awk '{ print $1 }'; }

# memo_inode_flips <tree>: the memo's inode differs after a save that updates an
# existing memo. The save is temp plus rename, so a reader never sees a half
# written memo; an in-place writer keeps the inode and fails.
memo_inode_flips() {
  local tree="$1" i1 i2
  umemo_load_store identity || return 1
  rm -f "$MEMO"
  _umemo_run "$tree" "$CAP/flip1.out" "$CAP/flip1.err" pr 2302 || return 1
  [ -f "$MEMO" ] || { printf 'no memo written by the first run\n' >&2; return 1; }
  i1="$(memo_inode)"
  new_branch_rows -flip
  _umemo_run "$tree" "$CAP/flip2.out" "$CAP/flip2.err" pr --key "$NB_KEY" || return 1
  i2="$(memo_inode)"
  [ "$i1" != "$i2" ] || { printf 'memo inode %s unchanged by an update\n' "$i1" >&2; return 1; }
}

# ---------------------------------------------------------------------------

@test "UAT-002: probe identity across pr, pr --key, pr --branch and pr-branch, cold and warm" {
  local n i seen=0 skipped=0 want_skipped pr key raw roots form tag args_str
  local -a args
  n="$(umemo_probe_count "$PROBES")"
  [ "$n" -ge 20 ]
  want_skipped="$(jq '[.probes[] | .key, .raw | select(. == null)] | length' "$PROBES")"
  # The jq above counts null keys and null raws: every one is a skipped form.
  for ((i = 0; i < n; i++)); do
    pr="$(jq -r --argjson i "$i" '.probes[$i].pr' "$PROBES")"
    key="$(jq -r --argjson i "$i" '.probes[$i].key // ""' "$PROBES")"
    raw="$(jq -r --argjson i "$i" '.probes[$i].raw // ""' "$PROBES")"
    roots="$(jq -r --argjson i "$i" '.probes[$i].expect.roots_min // 0' "$PROBES")"
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
        cp "$UM_TMP/probe-$pr.out" "$CAP/$tag-old.out"
        cp "$UM_TMP/probe-$pr.err" "$CAP/$tag-old.err"
        printf '0\n' >"$CAP/$tag-old.rc"
      else
        cap "$tag-old" old "${args[@]}"
      fi
      args_str="${args[*]}"
      if [ "$form" != prbranch ] &&
        [ "$(jq -r --argjson i "$i" '(.probes[$i].expect.unresolvable // false) or (.probes[$i].expect.no_spend // false)' "$PROBES")" = false ]; then
        if [ "$roots" -gt 0 ]; then assert_priced "$CAP/$tag-old.out" --roots; else assert_priced "$CAP/$tag-old.out"; fi
      fi
      if [ "$form" = prbranch ]; then
        # pr-branch reads only links.jsonl and never touches the memo, so one
        # run stands for both the cold and the warm pass.
        rm -f "$MEMO"
        cap "$tag-cold" new "${args[@]}"
        cp "$CAP/$tag-cold.out" "$CAP/$tag-warm.out"
        cp "$CAP/$tag-cold.err" "$CAP/$tag-warm.err"
        cp "$CAP/$tag-cold.rc" "$CAP/$tag-warm.rc"
      else
        cold_new "$tag-cold" "${args[@]}"
        warm_new "$tag-warm" "${args[@]}"
      fi
      same_cap "$tag-old" "$tag-cold" || { printf 'cold mismatch: %s\n' "$args_str" >&2; return 1; }
      same_cap "$tag-old" "$tag-warm" || { printf 'warm mismatch: %s\n' "$args_str" >&2; return 1; }
      [ ! -s "$CAP/$tag-cold.err" ] || { printf 'cold stderr not empty for %s:\n%s\n' "$args_str" "$(cat "$CAP/$tag-cold.err")" >&2; return 1; }
      [ ! -s "$CAP/$tag-warm.err" ] || { printf 'warm stderr not empty for %s:\n%s\n' "$args_str" "$(cat "$CAP/$tag-warm.err")" >&2; return 1; }
    done
  done
  [ "$seen" -eq "$n" ]
  [ "$skipped" -eq "$want_skipped" ]
}

@test "UAT-002 guard: the figure assertion fails over a main root with no capture hooks" {
  local bare="$UM_TMP/main-nohooks"
  # The same readout, once under the registered main root and once under a bare
  # one: the first carries figures, the second must trip assert_priced.
  cap hooked new pr 2302
  assert_priced "$CAP/hooked.out"
  mkdir -p "$bare/.gaia/local/telemetry"
  git -C "$bare" init -q -b main
  git -C "$bare" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false commit -q --allow-empty -m init
  cp "$UM_TD"/usage.jsonl "$UM_TD"/links.jsonl "$UM_TD"/cost.jsonl "$bare/.gaia/local/telemetry/"
  UM_MAIN="$bare" UM_TD="$bare/.gaia/local/telemetry" cap bare new pr 2302
  [ -s "$CAP/bare.out" ]
  run assert_priced "$CAP/bare.out"
  [ "$status" -ne 0 ]
}

@test "UAT-002: a link that closes a cycle is refused identically and changes nothing" {
  local child parent before
  child="$(jq -r '.anchors.cycle.child' "$PROBES")"
  parent="$(jq -r '.anchors.cycle.parent' "$PROBES")"
  before="$(_umemo_sha256 "$UM_TD/links.jsonl")"
  cap cyc-old old link "$child" "$parent"
  [ "$(cat "$CAP/cyc-old.rc")" = 1 ]
  grep -qF 'would close a cycle' "$CAP/cyc-old.err"
  cap cyc-new new link "$child" "$parent"
  [ "$(cat "$CAP/cyc-new.rc")" = 1 ]
  same_cap cyc-old cyc-new
  [ "$(_umemo_sha256 "$UM_TD/links.jsonl")" = "$before" ]
}

@test "UAT-010: initiative and reconcile are byte-identical, cold and warm" {
  local role ref seen=0
  for role in research issue spec; do
    ref="$(jq -r --arg r "$role" '.initiative_roots[$r]' "$PROBES")"
    [ -n "$ref" ] && [ "$ref" != null ]
    cap "i-$role-old" old initiative "$ref"
    grep -qF "[initiative $ref]" "$CAP/i-$role-old.out"
    grep -q 'tokens ' "$CAP/i-$role-old.out"
    cold_new "i-$role-cold" initiative "$ref"
    warm_new "i-$role-warm" initiative "$ref"
    same_cap "i-$role-old" "i-$role-cold"
    same_cap "i-$role-old" "i-$role-warm"
    [ ! -s "$CAP/i-$role-warm.err" ]
    seen=$((seen + 1))
  done
  [ "$seen" -eq 3 ]
  cap rec-old old reconcile
  grep -q 'attributed:   tokens' "$CAP/rec-old.out"
  cold_new rec-cold reconcile
  warm_new rec-warm reconcile
  same_cap rec-old rec-cold
  same_cap rec-old rec-warm
  [ ! -s "$CAP/rec-warm.err" ]
}

@test "AUDIT-9: the cursor-prefilter adversarial rows reach the figures" {
  local i n seen=0 pr
  # The three rows the cursor prefilter could drop: a segment on a branch whose
  # name spells the cursor marker, a cost row whose session_cwd carries the
  # marker text, and a real cursor row in a different key order.
  grep -qF '"key":"branch:fix/cursor-drift"' "$UM_TD/usage.jsonl"
  grep -qF 'session_cwd":"/work/{\"schema_version\":1,\"kind\":\"cursor\"' "$UM_TD/cost.jsonl"
  grep -qF '{"kind":"cursor","schema_version":1,' "$UM_TD/usage.jsonl"
  n="$(umemo_probe_count "$PROBES")"
  for ((i = 0; i < n; i++)); do
    [ "$(jq -r --argjson i "$i" '.probes[$i].category' "$PROBES")" = cursor_adversarial ] || continue
    pr="$(jq -r --argjson i "$i" '.probes[$i].pr' "$PROBES")"
    cap "cur-$pr-old" old pr "$pr"
    assert_priced "$CAP/cur-$pr-old.out"
    grep -qF '  tokens: 0 (' "$CAP/cur-$pr-old.out" && return 1
    cold_new "cur-$pr-cold" pr "$pr"
    warm_new "cur-$pr-warm" pr "$pr"
    grep -qF '  tokens: 0 (' "$CAP/cur-$pr-cold.out" && return 1
    same_cap "cur-$pr-old" "cur-$pr-cold"
    same_cap "cur-$pr-old" "cur-$pr-warm"
    seen=$((seen + 1))
  done
  [ "$seen" -eq 3 ]
}

@test "UAT-003: a binding appended under a warm memo re-attributes the session" {
  local sid root pr pre post
  sid="$(jq -r '.anchors.unbound_session.session_id' "$PROBES")"
  root="$(jq -r '.anchors.unbound_session.root' "$PROBES")"
  pr="$(jq -r '.anchors.unbound_session.pr' "$PROBES")"
  cold_new pre pr "$pr"
  warm_new pre pr "$pr"
  pre="$(initiative_block "$CAP/pre.out" "$root")"
  [ -n "$pre" ]
  append_row usage '{"schema_version":1,"kind":"binding","type":"research","session_id":"'"$sid"'","ts":"2026-09-26T13:00:00Z","ref":"'"$root"'","source":"transcript"}'
  warm_new post pr "$pr"
  post="$(initiative_block "$CAP/post.out" "$root")"
  [ -n "$post" ]
  [ "$pre" != "$post" ]
  cap post-old old pr "$pr"
  cold_new post-cold pr "$pr"
  same_cap post-old post
  same_cap post-old post-cold
}

@test "UAT-004: an appended edge adds a root and an appended unlink removes one" {
  local ref pr key ukey uroot upr
  ref="$(jq -r '.anchors.spare_root.ref' "$PROBES")"
  pr="$(jq -r '.anchors.spare_root.pr' "$PROBES")"
  key="$(probe_field "$pr" key)"
  cold_new e-pre pr "$pr"
  warm_new e-pre pr "$pr"
  [ -z "$(initiative_block "$CAP/e-pre.out" "$ref")" ]
  append_row links '{"schema_version":1,"kind":"edge","child":"'"$key"'","parent":"'"$ref"'","source":"link-command","ts":"2026-09-30T00:00:00Z","session_id":null,"sidechain":false}'
  warm_new e-post pr "$pr"
  [ -n "$(initiative_block "$CAP/e-post.out" "$ref")" ]
  [ "$(initiative_block "$CAP/e-post.out" "$ref" | grep -c .)" -gt 0 ]
  cap e-post-old old pr "$pr"
  cold_new e-post-cold pr "$pr"
  same_cap e-post-old e-post
  same_cap e-post-old e-post-cold

  # The unbound_session anchor's PR prints its root through a link edge; an
  # unlink of that edge removes the root from the readout.
  upr="$(jq -r '.anchors.unbound_session.pr' "$PROBES")"
  uroot="$(jq -r '.anchors.unbound_session.root' "$PROBES")"
  ukey="$(probe_field "$upr" key)"
  warm_new u-pre pr "$upr"
  [ -n "$(initiative_block "$CAP/u-pre.out" "$uroot")" ]
  append_row links '{"schema_version":1,"kind":"unlink","child":"'"$ukey"'","parent":"'"$uroot"'","source":"link-command","ts":"2026-09-30T01:00:00Z","session_id":null,"sidechain":false}'
  warm_new u-post pr "$upr"
  [ -z "$(initiative_block "$CAP/u-post.out" "$uroot")" ]
  cap u-post-old old pr "$upr"
  cold_new u-post-cold pr "$upr"
  same_cap u-post-old u-post
  same_cap u-post-old u-post-cold
}

@test "UAT-007: a branch no store or memo has seen is derived on first sight" {
  local raw key parent body
  raw="$(jq -r '.anchors.new_branch.raw' "$PROBES")"
  key="$(jq -r '.anchors.new_branch.key' "$PROBES")"
  parent="$(jq -r '.anchors.new_branch.parent' "$PROBES")"
  cold_new nb-pre pr --key "$key"
  warm_new nb-pre pr --key "$key"
  [ -z "$(initiative_block "$CAP/nb-pre.out" "$parent")" ]
  body="$(sed -n 2p "$MEMO")"
  [ "$(jq -r --arg r "$raw" '.bmap | has($r)' <<<"$body")" = false ]
  [ "$(jq -r --arg k "$key" '.derive | has($k)' <<<"$body")" = false ]
  new_branch_rows ""
  [ "$NB_KEY" = "$key" ]
  warm_new nb-post pr --key "$key"
  [ -n "$(initiative_block "$CAP/nb-post.out" "$parent")" ]
  assert_priced "$CAP/nb-post.out" --roots
  cap nb-old old pr --key "$key"
  cold_new nb-cold pr --key "$key"
  same_cap nb-old nb-post
  same_cap nb-old nb-cold
  warm_new nb-again pr --key "$key"
  same_cap nb-old nb-again
  body="$(sed -n 2p "$MEMO")"
  [ "$(jq -r --arg r "$raw" --arg k "$key" '.bmap[$r].key == $k' <<<"$body")" = true ]
  [ "$(jq -r --arg k "$key" --arg p "$parent" '.derive[$k] | index($p) != null' <<<"$body")" = true ]
}

@test "UAT-019: a closing cost row appended under a warm memo moves an open-start interval" {
  local sid key pr raw spec
  sid="$(jq -r '.anchors.open_start.session_id' "$PROBES")"
  key="$(jq -r '.anchors.open_start.key' "$PROBES")"
  pr="$(jq -r '.anchors.open_start.pr' "$PROBES")"
  raw="$(probe_field "$pr" raw)"
  spec="SPEC-$(sed -E 's|^branch:plan/spec-([0-9]+).*|\1|' <<<"$key")"
  [ "$spec" = SPEC-506 ]
  cold_new cl-pre pr "$pr"
  warm_new cl-pre pr "$pr"
  assert_priced "$CAP/cl-pre.out"
  append_row cost '{"schema_version":1,"kind":"spec","spec_id":"'"$spec"'","plan_id":null,"plan_slug":null,"session_id":"'"$sid"'","total":1000,"seq":0,"final":true,"git_branch":"'"$raw"'","ts":"2026-09-27T10:00:00Z","session_cwd":"/work/repo"}'
  warm_new cl-post pr "$pr"
  assert_priced "$CAP/cl-post.out"
  cmp -s "$CAP/cl-pre.out" "$CAP/cl-post.out" && return 1
  cap cl-old old pr "$pr"
  cold_new cl-cold pr "$pr"
  same_cap cl-old cl-post
  same_cap cl-old cl-cold
}

@test "UAT-005: a readout writes nothing but the memo, and each update replaces it" {
  local glob tmpl name before="$CAP/snap.before" after="$CAP/snap.after" sub i
  local -a subs=("pr 2305" "initiative issue:2330" "reconcile")
  stores_sha "$CAP/sha.before"
  snapshot "$before"
  for sub in "${subs[@]}"; do
    rm -f "$MEMO"
    snapshot "$before"
    # shellcheck disable=SC2086
    cap "int-cold" new $sub
    [ "$(cat "$CAP/int-cold.rc")" = 0 ]
    [ -f "$MEMO" ]
    snapshot "$after"
    [ -z "$(diff "$before" "$after" | grep '^[<>]' | grep -v 'usage-branch-memo.json')" ]
    stores_sha "$CAP/sha.after"
    assert_same "$CAP/sha.before" "$CAP/sha.after"
    snapshot "$before"
    # shellcheck disable=SC2086
    cap "int-warm" new $sub
    snapshot "$after"
    [ -z "$(diff "$before" "$after" | grep '^[<>]' | grep -v 'usage-branch-memo.json')" ]
    assert_same "$CAP/sha.before" "$CAP/sha.after" || return 1
  done
  # The appends are the test's own writes: re-record the hashes after them,
  # then require that the readouts that absorb them leave the stores alone.
  new_branch_rows ""
  stores_sha "$CAP/sha.before"
  snapshot "$before"
  i1="$(memo_inode)"
  cap int-update new pr --key "$NB_KEY"
  [ "$(cat "$CAP/int-update.rc")" = 0 ]
  snapshot "$after"
  stores_sha "$CAP/sha.after"
  assert_same "$CAP/sha.before" "$CAP/sha.after"
  [ -z "$(diff "$before" "$after" | grep '^[<>]' | grep -v 'usage-branch-memo.json')" ]
  [ "$i1" != "$(memo_inode)" ]
  [ -z "$(find "$UM_TD" "$UM_MAIN" -path "$UM_MAIN/.git" -prune -o -name '.usage-*.tmp.*' -print)" ]
  # The memo's temp name matches the glob the state registry registers.
  glob="$(jq -r '.entries // . | (if type == "array" then . else [.[]?] end) | map(select(.id == "telemetry-usage-tmp"))[0].path' "$UM_SRC/.gaia/state-registry.json")"
  [ -n "$glob" ] && [ "$glob" != null ]
  glob="${glob##*/}"
  tmpl="$(grep -o '\.usage-branch-memo\.tmp\.X*' "$UM_NEW/.gaia/scripts/usage-memo-lib.sh" | head -n 1)"
  [ -n "$tmpl" ]
  name="${tmpl%%X*}abc123"
  # shellcheck disable=SC2254
  case "$name" in $glob) ;; *) printf 'temp name %s does not match registered glob %s\n' "$name" "$glob" >&2; return 1 ;; esac
}

@test "UAT-005 guard: an in-place memo writer fails the inode check" {
  local mut="$UM_TMP/tree-inplace"
  cp -R "$UM_NEW" "$mut"
  sed 's|mv -f "\$tmp" "\$memo"|cat "$tmp" >"$memo"|' "$UM_NEW/.gaia/scripts/usage-memo-lib.sh" >"$mut/.gaia/scripts/usage-memo-lib.sh"
  cmp -s "$UM_NEW/.gaia/scripts/usage-memo-lib.sh" "$mut/.gaia/scripts/usage-memo-lib.sh" && return 1
  memo_inode_flips "$UM_NEW"
  run memo_inode_flips "$mut"
  [ "$status" -ne 0 ]
}

# epoch_all <scripts dir> <corpus>: usage_epoch of every corpus value through
# that tree's own GAIA_USAGE_RESOLVE_JQ, as a JSON array of tojson strings (an
# error is captured as "error", so a value the jq cannot parse still compares).
epoch_all() {
  local dir="$1" corpus="$2"
  bash -c '
    . "$1/usage-lib.sh" && . "$1/usage-resolve-lib.sh" || exit 1
    jq -nc --slurpfile v "$2" "$GAIA_USAGE_JQ_DEFS$GAIA_USAGE_RESOLVE_JQ"'\''[$v[0][] | (try (usage_epoch | tojson) catch "error")]'\''
  ' _ "$dir" "$corpus"
}

@test "UAT-013: usage_epoch agrees with the pre-change body over the epoch corpus" {
  local corpus="$UM_FX/epoch/corpus.json" n old new
  n="$(jq 'length' "$corpus")"
  [ "$n" -ge 25 ]
  old="$(epoch_all "$UM_OLD/.gaia/scripts" "$corpus")"
  new="$(epoch_all "$UM_NEW/.gaia/scripts" "$corpus")"
  [ "$(jq 'length' <<<"$old")" -eq "$n" ]
  [ "$(jq 'length' <<<"$new")" -eq "$n" ]
  # The corpus must exercise both outcomes, or an all-null pair agrees trivially.
  [ "$(jq '[.[] | select(. != "null" and . != "\"error\"")] | length' <<<"$old")" -ge 10 ]
  [ "$(jq '[.[] | select(. == "null")] | length' <<<"$old")" -ge 5 ]
  [ "$old" = "$new" ]
}

@test "UAT-013 guard: a fast path that drops the fraction term disagrees with the baseline" {
  local corpus="$UM_FX/epoch/corpus.json" mut="$UM_TMP/tree-epoch" old new
  mkdir -p "$mut"
  cp "$UM_NEW"/.gaia/scripts/*.sh "$mut/"
  bash "$UM_FX/epoch/mutant-drop-fraction.sh" "$UM_NEW/.gaia/scripts/usage-resolve-lib.sh" "$mut/usage-resolve-lib.sh"
  old="$(epoch_all "$UM_OLD/.gaia/scripts" "$corpus")"
  new="$(epoch_all "$mut" "$corpus")"
  [ -n "$new" ]
  [ "$old" != "$new" ]
}
