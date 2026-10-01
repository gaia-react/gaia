#!/usr/bin/env bash
# Shared harness for the usage-readout memo suites (SPEC-089): two scratch
# script trees (the working tree's scripts and a pre-change copy pinned at
# e4b57e23), one scratch main root with the capture hooks registered, and the
# comparison and assertion helpers. Source it from bats `setup()` and call
# `umemo_setup`.
#
# Why a pinned copy: CI checks out at depth 1, so the pre-change scripts cannot
# come from git at test time. Only the four files the plan changes are pinned
# (fixtures/usage/baseline-e4b57e23/, checked against SHA256SUMS); every other
# script comes from the working tree, so an unrelated later change to, say, the
# pricing lib cannot break an identity suite. A missing or altered pinned file
# fails the test, never skips it.
#
# `status` and `output` come from bats' own `run`, and the suites read the
# variables umemo_setup sets, neither of which the linter can see from here.
# The jq programs are single-quoted on purpose: their `$` names are jq's.
# shellcheck disable=SC2154,SC2034,SC2016

# The files the plan changes, pinned beside their SHA256SUMS.
UMEMO_PINNED="usage.sh usage-lib.sh usage-resolve-lib.sh usage-render-lib.sh"

# The probe vocabulary of probes.json (the C8 contract): closed lists, so a typo
# in a fixture or a scratch copy is an error rather than a silently ignored key.
UMEMO_CATEGORIES="first_merge repeat_merge multi_root inherit interval no_spend unresolvable lower_bound cursor_adversarial wide_root"
UMEMO_EXPECT_KEYS="lower_bound roots_min no_spend unresolvable nonzero inherit interval merges"

_umemo_fail() {
  printf 'usage-memo harness: %s\n' "$*" >&2
  return 1
}

_umemo_sha256() {
  local out
  if out="$(shasum -a 256 "$1" 2>/dev/null)" && [ -n "$out" ]; then :
  elif out="$(sha256sum "$1" 2>/dev/null)" && [ -n "$out" ]; then :
  else return 1; fi
  printf '%s' "${out%% *}"
}

# umemo_verify_baseline [dir]: rc 0 when every pinned file is present and
# matches SHA256SUMS; otherwise names the file and the reason on stderr.
umemo_verify_baseline() {
  local dir="${1:-$UM_BASELINE_DIR}" n want got
  [ -f "$dir/SHA256SUMS" ] || { _umemo_fail "baseline SHA256SUMS missing in $dir"; return 1; }
  for n in $UMEMO_PINNED; do
    [ -f "$dir/$n" ] || { _umemo_fail "baseline file missing: $n (expected in $dir)"; return 1; }
    want="$(awk -v n="$n" '$2 == n { print $1 }' "$dir/SHA256SUMS")"
    [ -n "$want" ] || { _umemo_fail "baseline SHA256SUMS has no line for $n"; return 1; }
    got="$(_umemo_sha256 "$dir/$n")" || { _umemo_fail "no sha256 tool (shasum or sha256sum) to verify the baseline"; return 1; }
    [ "$got" = "$want" ] || { _umemo_fail "baseline sha256 mismatch for $n: want $want, got $got"; return 1; }
  done
  return 0
}

# _umemo_build_tree <root>: the scripts a usage readout loads, copied from the
# working tree, laid out as in a real checkout so the lock lib resolves.
_umemo_build_tree() {
  local root="$1" f
  mkdir -p "$root/.gaia/scripts" "$root/.specify/extensions/gaia/lib"
  for f in "$UM_SRC"/.gaia/scripts/usage*.sh "$UM_SRC"/.gaia/scripts/token-pricing-lib.sh \
    "$UM_SRC"/.gaia/scripts/token-rates-local-lib.sh "$UM_SRC"/.gaia/scripts/token-rates-feed-lib.sh \
    "$UM_SRC"/.gaia/scripts/ledger-path-lib.sh "$UM_SRC"/.gaia/scripts/main-root-lib.sh \
    "$UM_SRC"/.gaia/scripts/branch-name-lib.sh "$UM_SRC"/.gaia/scripts/token-rollup.sh; do
    cp "$f" "$root/.gaia/scripts/" || return 1
  done
  cp "$UM_SRC/.specify/extensions/gaia/lib/with-ledger-lock.sh" "$root/.specify/extensions/gaia/lib/" || return 1
  cat >"$root/.gaia/scripts/token-rates.json" <<'EOF'
{
  "cache_multipliers": { "read": 0.1, "write_5m": 1.25, "write_1h": 2.0 },
  "models": { "claude-opus-5-5": [ { "input": 2, "output": 10 } ] }
}
EOF
}

# umemo_setup: builds $UM_NEW and $UM_OLD (script trees), $UM_MAIN (scratch main
# root, capture hooks registered), $UM_TD (its telemetry dir), $UM_PROJ (empty
# projects root), $UM_RATES (the committed rate table), and the hermetic env.
# Idempotent: a second call rebuilds over the first.
umemo_setup() {
  local f
  UM_SRC="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)" || return 1
  UM_FX="$BATS_TEST_DIRNAME/fixtures/usage"
  UM_BASELINE_DIR="${UM_BASELINE_DIR:-$UM_FX/baseline-e4b57e23}"
  umemo_verify_baseline "$UM_BASELINE_DIR" || return 1
  UM_TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)" || return 1
  UM_NEW="$UM_TMP/tree-new"
  UM_OLD="$UM_TMP/tree-old"
  _umemo_build_tree "$UM_NEW" || return 1
  _umemo_build_tree "$UM_OLD" || return 1
  for f in $UMEMO_PINNED; do
    cp "$UM_BASELINE_DIR/$f" "$UM_OLD/.gaia/scripts/$f" || return 1
  done
  UM_MAIN="$UM_TMP/main"
  UM_TD="$UM_MAIN/.gaia/local/telemetry"
  UM_PROJ="$UM_TMP/projects"
  UM_RATES="$UM_FX/identity/rates.json"
  mkdir -p "$UM_MAIN/.claude" "$UM_TD" "$UM_PROJ" || return 1
  if [ ! -d "$UM_MAIN/.git" ]; then
    git -C "$UM_MAIN" init -q -b main || return 1
    git -C "$UM_MAIN" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false \
      commit -q --allow-empty -m init || return 1
  fi
  cat >"$UM_MAIN/.claude/settings.json" <<'EOF'
{"hooks": {
  "Stop": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/usage-capture.sh"}]}],
  "SessionStart": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/usage-capture.sh"}]}]
}}
EOF
  UM_OUT="$UM_TMP/u.out"
  UM_ERR="$UM_TMP/u.err"
  export GAIA_RATES_FEED_DISABLE=1 GAIA_RATES_STATE_DIR="$UM_TMP/rates-state"
  unset CLAUDE_CODE_SESSION_ID GAIA_TALLY_PROJECTS_ROOT GITHUB_ACTIONS GAIA_USAGE_MEMO_TRACE GAIA_USAGE_MEMO_SEAM
  return 0
}

# _umemo_run <tree> <out> <err> <args...>: one usage.sh run, stdout and stderr
# captured separately; returns the script's exit status.
_umemo_run() {
  local tree="$1" out="$2" err="$3" rc=0
  shift 3
  bash "$tree/.gaia/scripts/usage.sh" "$@" --main-root "$UM_MAIN" --telemetry-dir "$UM_TD" \
    --rate-table "$UM_RATES" --projects-root "$UM_PROJ" >"$out" 2>"$err" || rc=$?
  return "$rc"
}

# Output lands in $UM_OUT and $UM_ERR (reassign either before a call to keep an
# earlier run's capture); under bats' `run` the function is a subshell, so read
# the files, not $output.
u_new() { _umemo_run "$UM_NEW" "$UM_OUT" "$UM_ERR" "$@"; }
u_old() { _umemo_run "$UM_OLD" "$UM_OUT" "$UM_ERR" "$@"; }

# umemo_load_store <name>: copies fixtures/usage/<name>/{usage,links,cost}.jsonl
# into $UM_TD (replacing whatever was there).
umemo_load_store() {
  local f d="$UM_FX/$1"
  [ -d "$d" ] || { _umemo_fail "no fixture store named '$1' under $UM_FX"; return 1; }
  mkdir -p "$UM_TD" || return 1
  for f in usage.jsonl links.jsonl cost.jsonl; do
    if [ -f "$d/$f" ]; then cp "$d/$f" "$UM_TD/$f" || return 1; else rm -f "$UM_TD/$f"; fi
  done
}

# assert_priced <file> [--roots]: the file carries token and dollar figures
# (and an initiative line with --roots). A degenerate output (a header-only
# block, a rate table that did not load) would let a byte comparison pass
# vacuously, so every compared pr output goes through this first.
assert_priced() {
  local f="$1" roots="${2:-}"
  grep -q '^  tokens: ' "$f" || { printf 'assert_priced: no "  tokens: " line in %s:\n%s\n' "$f" "$(cat "$f")" >&2; return 1; }
  grep -qF 'est. cost (USD): $' "$f" || { printf 'assert_priced: no "est. cost (USD): $" figure in %s:\n%s\n' "$f" "$(cat "$f")" >&2; return 1; }
  if [ "$roots" = --roots ]; then
    grep -q '^\[initiative ' "$f" || { printf 'assert_priced: no "[initiative " line in %s:\n%s\n' "$f" "$(cat "$f")" >&2; return 1; }
  fi
  return 0
}

# assert_same <a> <b>: byte-identical files, with a unified diff on failure.
assert_same() {
  cmp -s "$1" "$2" && return 0
  printf 'assert_same: %s and %s differ:\n' "$1" "$2" >&2
  diff -u "$1" "$2" >&2 || true
  return 1
}

# umemo_validate_probes <probes.json>: the C8 schema, exactly. Prints one line
# per violation to stdout; rc 1 when there is any.
umemo_validate_probes() {
  local errs
  errs="$(jq -r --arg cats "$UMEMO_CATEGORIES" --arg eks "$UMEMO_EXPECT_KEYS" '
    . as $R | ($cats | split(" ")) as $C | ($eks | split(" ")) as $E
    | def keys_are($o; $want; $what): if ($o | type) != "object" then "\($what): not an object"
        elif ($o | keys) != ($want | sort) then "\($what): keys are \($o | keys | join(",")), want \($want | sort | join(","))"
        else empty end;
      def isint: type == "number" and . == floor;
      def need($cat): {first_merge: "merges", repeat_merge: "merges", multi_root: "roots_min", wide_root: "roots_min",
        inherit: "inherit", interval: "interval", no_spend: "no_spend", unresolvable: "unresolvable",
        lower_bound: "lower_bound", cursor_adversarial: "nonzero"}[$cat];
      keys_are($R; ["probes", "initiative_roots", "anchors"]; "top level"),
      (if ($R.probes | type) != "array" then "probes: not an array"
       elif ($R.probes | length) < 20 then "probes: \($R.probes | length) entries, want at least 20"
       else empty end),
      (($R.probes // [])[]? | . as $p
        | (keys_are($p; ["pr", "key", "raw", "category", "expect"]; "probe \($p.pr)"),
           (if ($p.pr | isint | not) then "probe \($p.pr): pr is not an integer" else empty end),
           (if ($p.key != null and (($p.key | type) != "string" or ($p.key | startswith("branch:") | not))) then "probe \($p.pr): key is neither null nor a branch ref" else empty end),
           (if ($p.raw != null and ($p.raw | type) != "string") then "probe \($p.pr): raw is neither null nor a string" else empty end),
           (if ($C | index($p.category)) == null then "probe \($p.pr): unknown category \($p.category)"
            else
              (if ($p.expect | type) != "object" then "probe \($p.pr): expect is not an object"
               else
                 ($p.expect | keys[] | select(. as $k | ($E | index($k)) == null) | "probe \($p.pr): unknown expect key \(.)"),
                 (need($p.category) as $n | if $n == null then empty
                  elif ($p.expect | has($n) | not) then "probe \($p.pr): category \($p.category) needs expect.\($n)"
                  else empty end),
                 ($p.expect | to_entries[] | select(.key == "roots_min" or .key == "merges") | select(.value | isint | not) | "probe \($p.pr): expect.\(.key) is not an integer"),
                 ($p.expect | to_entries[] | select(.key != "roots_min" and .key != "merges") | select(.value | type != "boolean") | "probe \($p.pr): expect.\(.key) is not a boolean"),
                 (if $p.category == "first_merge" and ($p.expect.merges != 1) then "probe \($p.pr): first_merge wants merges 1" else empty end),
                 (if $p.category == "repeat_merge" and (($p.expect.merges // 0) < 2) then "probe \($p.pr): repeat_merge wants merges of 2 or more" else empty end),
                 (if $p.category == "multi_root" and (($p.expect.roots_min // 0) < 2) then "probe \($p.pr): multi_root wants roots_min of 2 or more" else empty end),
                 (if $p.category == "wide_root" and (($p.expect.roots_min // 0) < 1) then "probe \($p.pr): wide_root wants roots_min of 1 or more" else empty end)
               end)
            end),
           (if $p.category == "unresolvable" and $p.key != null then "probe \($p.pr): an unresolvable probe has a null key" else empty end),
           (if $p.category != "unresolvable" and $p.key == null then "probe \($p.pr): only an unresolvable probe has a null key" else empty end))),
      ([$C[] | select(. != "cursor_adversarial" and . != "wide_root")] as $eight
        | $eight[] | . as $c | select([($R.probes // [])[]? | select(.category == $c)] | length == 0) | "no probe has category \($c)"),
      keys_are($R.initiative_roots; ["research", "issue", "spec"]; "initiative_roots"),
      keys_are($R.anchors; ["open_start", "unbound_session", "spare_root", "new_branch", "cycle"]; "anchors"),
      keys_are($R.anchors.open_start; ["session_id", "key", "pr"]; "anchors.open_start"),
      keys_are($R.anchors.unbound_session; ["session_id", "root", "pr"]; "anchors.unbound_session"),
      keys_are($R.anchors.spare_root; ["ref", "pr"]; "anchors.spare_root"),
      keys_are($R.anchors.new_branch; ["raw", "key", "parent"]; "anchors.new_branch"),
      keys_are($R.anchors.cycle; ["child", "parent"]; "anchors.cycle")
  ' "$1" 2>&1)" || { printf 'probes.json is not valid JSON or the validator failed:\n%s\n' "$errs"; return 1; }
  [ -z "$errs" ] && return 0
  printf '%s\n' "$errs"
  return 1
}

# umemo_probe_count <probes.json>: how many probes the file holds.
umemo_probe_count() { jq -r '.probes | length' "$1"; }

# _umemo_store_jq <filter> [jq args...]: the stores in $UM_TD as $u, $l, $c and
# the pinned lib's $keys object, with the pinned usage and resolve defs ahead of
# the filter. Pinned so a sibling task editing the working tree's jq cannot
# move what a fixture is checked against.
_umemo_store_jq() {
  local filter="$1" u="$UM_TD/usage.jsonl" l="$UM_TD/links.jsonl" c="$UM_TD/cost.jsonl"
  shift
  [ -f "$u" ] || u=/dev/null
  [ -f "$l" ] || l=/dev/null
  [ -f "$c" ] || c=/dev/null
  (
    # shellcheck source=/dev/null
    . "$UM_OLD/.gaia/scripts/usage-lib.sh" && . "$UM_OLD/.gaia/scripts/usage-resolve-lib.sh" || exit 1
    keys="$(gaia_usage_keys_json "$UM_MAIN" "$u" "$l" "$c")" || exit 1
    jq -n --rawfile u "$u" --rawfile l "$l" --rawfile c "$c" --argjson keys "$keys" "$@" \
      "$GAIA_USAGE_JQ_DEFS$GAIA_USAGE_RESOLVE_JQ$filter"
  )
}

# umemo_check_probe <probes.json> <index>: the probe at <index> exhibits every
# expect key it carries, as C8's table defines it. Output checks read
# `u_old pr <N>`; store checks run the pinned jq defs over the stores in $UM_TD.
# Prints each failure on stderr; rc 1 on any.
umemo_check_probe() {
  local pj="$1" i="$2" pr key out err ek ev rc=0 got n
  pr="$(jq -r --argjson i "$i" '.probes[$i].pr' "$pj")" || return 1
  key="$(jq -r --argjson i "$i" '.probes[$i].key // ""' "$pj")"
  out="$UM_TMP/probe-$pr.out" err="$UM_TMP/probe-$pr.err"
  _umemo_run "$UM_OLD" "$out" "$err" pr "$pr" || { _umemo_fail "probe $pr: u_old pr exited non-zero"; return 1; }
  while IFS=$'\t' read -r ek ev; do
    case "$ek" in
      lower_bound)
        got=false
        grep -qxF '  ! lower bound: branch spend may predate coverage start' "$out" && got=true
        [ "$got" = "$ev" ] || { _umemo_fail "probe $pr: lower_bound is $got, expect $ev"; rc=1; }
        ;;
      roots_min)
        n="$(grep -c '^\[initiative ' "$out")" || n=0
        [ "$n" -ge "$ev" ] || { _umemo_fail "probe $pr: $n initiative line(s), expect at least $ev"; rc=1; }
        ;;
      no_spend)
        # A PR that owns no spend still renders a dollar figure ($0.00), so
        # "no spend" is a zero token count with a zero dollar figure.
        got=false
        if grep -qF '  tokens: 0 (' "$out" && grep -qxF '  est. cost (USD): $0.00' "$out"; then got=true; fi
        [ "$got" = "$ev" ] || { _umemo_fail "probe $pr: no_spend is $got, expect $ev"; rc=1; }
        ;;
      unresolvable)
        got=false
        grep -qF '(branch unresolved)' "$out" && got=true
        [ "$got" = "$ev" ] || { _umemo_fail "probe $pr: unresolvable is $got, expect $ev"; rc=1; }
        ;;
      nonzero)
        got=false
        if grep -q '^  tokens: ' "$out" && ! grep -qF '  tokens: 0 (' "$out"; then got=true; fi
        [ "$got" = "$ev" ] || { _umemo_fail "probe $pr: nonzero is $got, expect $ev"; rc=1; }
        ;;
      merges)
        got="$(_umemo_store_jq 'usage_rows($l) | [.[] | select(.kind == "merge" and .key == $k)] | length' --arg k "$key")" || got=error
        [ "$got" = "$ev" ] || { _umemo_fail "probe $pr: $got merge row(s) for $key, expect $ev"; rc=1; }
        ;;
      inherit)
        got="$(_umemo_store_jq 'usage_rows($u) as $ur | [$ur[] | select(.kind == "binding")] as $b
          | usage_resolve([$ur[] | select(.kind == "segment")]; $b; usage_intervals($b; usage_rows($c)))
          | any(.[]; .inherit == true and .rkey == $k)' --arg k "$key")" || got=error
        [ "$got" = "$ev" ] || { _umemo_fail "probe $pr: inherit is $got for $key, expect $ev"; rc=1; }
        ;;
      interval)
        # An interval resolves a session's segments to a spec: or plan: key, so
        # the segment is found at the probe key or at one of its ancestors (the
        # spec or plan its branch name implies), inside a closed interval.
        got="$(_umemo_store_jq 'usage_rows($u) as $ur | usage_rows($l) as $links | usage_rows($c) as $cost
          | [$ur[] | select(.kind == "binding")] as $b
          | usage_intervals($b; $cost) as $iv
          | usage_resolve_t([$ur[] | select(.kind == "segment")]; $b; $iv) as $segs
          | usage_walk(usage_edges($links; $cost; $keys); $k; true).seen as $up
          | any($segs[]; . as $s | ($s.rkey | type) == "string" and ($s.rkey | test("^(spec|plan):"))
              and any($up[]; . == $s.rkey)
              and any($iv[]; .session_id == $s.session_id and .key == $s.rkey
                and $s._t != null and .t0 <= $s._t and $s._t <= .t1))' --arg k "$key")" || got=error
        [ "$got" = "$ev" ] || { _umemo_fail "probe $pr: interval is $got for $key, expect $ev"; rc=1; }
        ;;
      *) _umemo_fail "probe $pr: unknown expect key $ek"; rc=1 ;;
    esac
  done < <(jq -r --argjson i "$i" '.probes[$i].expect | to_entries[] | "\(.key)\t\(.value | tojson)"' "$pj")
  return "$rc"
}

# umemo_check_anchor <probes.json> <name>: the named anchor's precondition holds
# over the stores in $UM_TD (and, for cycle, over a refused `link`). Prints the
# failure on stderr; rc 1 on failure.
umemo_check_anchor() {
  local pj="$1" a="$2" sid key pr root ref raw parent child got out err before
  case "$a" in
    open_start)
      sid="$(jq -r '.anchors.open_start.session_id' "$pj")" key="$(jq -r '.anchors.open_start.key' "$pj")"
      pr="$(jq -r '.anchors.open_start.pr' "$pj")"
      got="$(_umemo_store_jq 'usage_rows($u) as $ur | usage_rows($l) as $links | usage_rows($c) as $cost
        | [$ur[] | select(.kind == "binding")] as $b
        | usage_resolve([$ur[] | select(.kind == "segment")]; $b; usage_intervals($b; $cost)) as $segs
        | usage_edges($links; $cost; $keys) as $e
        | any($b[]; .type == "start" and .session_id == $sid)
          and ([$cost[] | select(.session_id == $sid)] | length == 0)
          and ([$segs[] | select(.session_id == $sid)] | length > 0)
          and all($segs[] | select(.session_id == $sid); .rkey == "session:" + $sid)
          and any($e[]; .child == $k and (.parent | test("^(spec|plan):")))' --arg sid "$sid" --arg k "$key")" || got=error
      [ "$got" = true ] || { _umemo_fail "anchor open_start: $sid is not an open-start session whose key $key would claim (got $got)"; return 1; }
      [ "$(jq -r --argjson p "$pr" --arg k "$key" '[.probes[] | select(.pr == $p and .key == $k)] | length' "$pj")" = 1 ] ||
        { _umemo_fail "anchor open_start: no probe has pr $pr and key $key"; return 1; }
      ;;
    unbound_session)
      sid="$(jq -r '.anchors.unbound_session.session_id' "$pj")" root="$(jq -r '.anchors.unbound_session.root' "$pj")"
      pr="$(jq -r '.anchors.unbound_session.pr' "$pj")"
      got="$(_umemo_store_jq 'usage_rows($u) as $ur | [$ur[] | select(.kind == "binding")] as $b
        | usage_resolve([$ur[] | select(.kind == "segment")]; $b; usage_intervals($b; usage_rows($c))) as $segs
        | ([$segs[] | select(.session_id == $sid)] | length > 0)
          and all($segs[] | select(.session_id == $sid); .rkey == "session:" + $sid)' --arg sid "$sid")" || got=error
      [ "$got" = true ] || { _umemo_fail "anchor unbound_session: segments of $sid do not all resolve to session:$sid (got $got)"; return 1; }
      out="$UM_TMP/anchor-unbound.out" err="$UM_TMP/anchor-unbound.err"
      _umemo_run "$UM_OLD" "$out" "$err" pr "$pr" || true
      grep -qF "[initiative $root to date" "$out" || { _umemo_fail "anchor unbound_session: pr $pr prints no [initiative $root line"; return 1; }
      ;;
    spare_root)
      ref="$(jq -r '.anchors.spare_root.ref' "$pj")" pr="$(jq -r '.anchors.spare_root.pr' "$pj")"
      got="$(_umemo_store_jq 'usage_rows($u) as $ur | usage_rows($l) as $links | usage_rows($c) as $cost
        | [$ur[] | select(.kind == "binding")] as $b
        | usage_resolve([$ur[] | select(.kind == "segment")]; $b; usage_intervals($b; $cost)) as $segs
        | usage_edges($links; $cost; $keys) as $e
        | usage_closure($e; $ref) as $cl
        | ([$segs[] | select(.rkey as $r | any($cl[]; . == $r)) | .by_model | to_entries[] | .value.fresh_input // 0] | add // 0) > 0' \
        --arg ref "$ref")" || got=error
      [ "$got" = true ] || { _umemo_fail "anchor spare_root: $ref owns no spend (got $got)"; return 1; }
      got="$(_umemo_store_jq 'usage_rows($l) as $links | usage_rows($c) as $cost | usage_edges($links; $cost; $keys) as $e
        | [$probes[0].probes[] | .key | strings | . as $k | usage_walk($e; $k; true).seen | any(.[]; . == $ref)] | any' \
        --arg ref "$ref" --slurpfile probes "$pj")" || got=error
      [ "$got" = false ] || { _umemo_fail "anchor spare_root: a probe key reaches $ref (got $got)"; return 1; }
      [ "$(jq -r --argjson p "$pr" '[.probes[] | select(.pr == $p)] | length' "$pj")" = 1 ] || { _umemo_fail "anchor spare_root: no probe has pr $pr"; return 1; }
      ;;
    new_branch)
      raw="$(jq -r '.anchors.new_branch.raw' "$pj")" key="$(jq -r '.anchors.new_branch.key' "$pj")"
      parent="$(jq -r '.anchors.new_branch.parent' "$pj")"
      case "$raw" in */*) ;; *) _umemo_fail "anchor new_branch: raw $raw has no slash"; return 1 ;; esac
      for got in usage links cost; do
        if [ -f "$UM_TD/$got.jsonl" ] && { grep -qF -- "$raw" "$UM_TD/$got.jsonl" || grep -qF -- "$key" "$UM_TD/$got.jsonl"; }; then
          _umemo_fail "anchor new_branch: $raw or $key already occurs in $got.jsonl"
          return 1
        fi
      done
      got="$(bash -c '. "$1/.gaia/scripts/usage-lib.sh" && . "$1/.gaia/scripts/usage-resolve-lib.sh" &&
        gaia_usage_branch_map "$2" | jq -r --arg r "$2" ".[\$r].key"' _ "$UM_OLD" "$raw")" || got=error
      [ "$got" = "$key" ] || { _umemo_fail "anchor new_branch: gaia_usage_branch_map keys $raw as '$got', not $key"; return 1; }
      got="$(bash -c '. "$1/.gaia/scripts/usage-lib.sh" && . "$1/.gaia/scripts/usage-resolve-lib.sh" &&
        gaia_usage_derive_map "$2" | jq -r --arg k "$2" --arg p "$3" "(.[\$k] // []) | any(. == \$p)"' _ "$UM_OLD" "$key" "$parent")" || got=error
      [ "$got" = true ] || { _umemo_fail "anchor new_branch: $key does not derive parent $parent (got $got)"; return 1; }
      got="$(_umemo_store_jq 'usage_rows($u) as $ur | usage_rows($l) as $links | usage_rows($c) as $cost
        | [$ur[] | select(.kind == "binding")] as $b
        | usage_resolve([$ur[] | select(.kind == "segment")]; $b; usage_intervals($b; $cost)) as $segs
        | usage_closure(usage_edges($links; $cost; $keys); $p) as $cl
        | ([$segs[] | select(.rkey as $r | any($cl[]; . == $r)) | .by_model | to_entries[] | .value.fresh_input // 0] | add // 0) > 0' \
        --arg p "$parent")" || got=error
      [ "$got" = true ] || { _umemo_fail "anchor new_branch: parent $parent owns no spend (got $got)"; return 1; }
      ;;
    cycle)
      child="$(jq -r '.anchors.cycle.child' "$pj")" parent="$(jq -r '.anchors.cycle.parent' "$pj")"
      before="$UM_TMP/links.before"
      if [ -f "$UM_TD/links.jsonl" ]; then cp "$UM_TD/links.jsonl" "$before"; else : >"$before"; fi
      out="$UM_TMP/anchor-cycle.out" err="$UM_TMP/anchor-cycle.err"
      got=0
      _umemo_run "$UM_OLD" "$out" "$err" link "$child" "$parent" || got=$?
      [ "$got" = 1 ] || { _umemo_fail "anchor cycle: link $child $parent exited $got, expect 1 (refused)"; return 1; }
      grep -qF 'would close a cycle' "$err" || { _umemo_fail "anchor cycle: link $child $parent was refused without the cycle message"; return 1; }
      if [ -f "$UM_TD/links.jsonl" ]; then cmp -s "$before" "$UM_TD/links.jsonl" || { _umemo_fail "anchor cycle: a refused link changed links.jsonl"; return 1; }; fi
      ;;
    *) _umemo_fail "unknown anchor $a"; return 1 ;;
  esac
  return 0
}
