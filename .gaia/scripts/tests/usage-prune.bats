#!/usr/bin/env bats
#
# The per-PR view resolves only the sessions that can reach a segment under
# the PR's key or its roots' closures (usage_pr_scope), and every `_of` view
# reads rows and keys only through its parameters. Both are checked against
# the shipped jq defs, never a re-implementation:
#   - the differential compares the full resolver's per-ref sums with the
#     pruned sums, and goes red for each committed mutant of the prune def;
#   - the globals-blank equivalence runs each `_of` view with $u, $l, $c bound
#     to "" and $keys to {}, and goes red for each committed sed mutant.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/usage-prune.bats

# shellcheck disable=SC2016  # jq programs and sed patterns are single-quoted on purpose

bats_require_minimum_version 1.5.0

setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FX="$BATS_TEST_DIRNAME/fixtures/usage/prune"
  RATES_FILE="$BATS_TEST_DIRNAME/fixtures/usage/resolve/rates-a.json"
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  MAIN="$TMP/main"
  git -C "$TMP" init -q -b main main
  git -C "$MAIN" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false commit -q --allow-empty -m init
  # shellcheck source=.gaia/scripts/usage-lib.sh
  . "$SCRIPTS/usage-lib.sh"
  # shellcheck source=.gaia/scripts/usage-resolve-lib.sh
  . "$SCRIPTS/usage-resolve-lib.sh"
  # shellcheck source=.gaia/scripts/usage-render-lib.sh
  . "$SCRIPTS/usage-render-lib.sh"
  # shellcheck source=.gaia/scripts/token-pricing-lib.sh
  . "$SCRIPTS/token-pricing-lib.sh"
  KEYS="$(gaia_usage_keys_json "$MAIN" "$FX/usage.jsonl" "$FX/links.jsonl" "$FX/cost.jsonl")"
  RATES="$(gaia_load_rate_table "$RATES_FILE")"
  export KEYS RATES
  printf '%s' "$KEYS" >"$TMP/keys.json"
}

# diff_prog <view-jq>: the differential over every key, root, and resolved ref.
# Each case is a usage_set N; per ref in N, the full resolver's sum is compared
# with the sum over only the sessions usage_pr_scope keeps.
diff_prog() {
  # shellcheck disable=SC2016  # jq source
  printf '%s%s%s%s%s' "$GAIA_USAGE_JQ_DEFS" "$GAIA_PRICING_JQ_DEFS" "$GAIA_USAGE_RESOLVE_JQ" "$GAIA_USAGE_MODEL_JQ" "$1"'
usage_rows($u) as $urows | usage_rows($l) as $links | usage_rows($c) as $cost
| usage_model_base_of($urows; $links; $cost; $keys) as $m
| $m.edges as $edges
| ([$urows[] | select(.kind == "segment") | .key | strings | select(startswith("branch:"))]
   + [$links[] | (.child, .parent, .key) | strings | select(startswith("branch:"))]
   + [$keys.bmap[] | .key | strings] | unique) as $bkeys
| ([$bkeys[] | usage_roots($edges; .)[]] | unique) as $roots
| ([$m.segs[].rkey | strings] | unique) as $rkeys
| ([$bkeys[] | . as $k | {name: ("key " + $k),
      n: usage_set([$k] + [usage_roots($edges; $k)[] | select(. != $k) | usage_closure($edges; .)[]])}]
  + [$roots[] | . as $r | {name: ("root " + $r), n: usage_set(usage_closure($edges; $r))}]
  + [$rkeys[] | . as $r | {name: ("rkey " + $r), n: {($r): true}}]) as $cases
| def sums($segs; $n):
    [$n | to_entries[] | .key as $ref | {ref: $ref, sum: usage_sum([$segs[] | select(.rkey == $ref) | usage_priced])}];
  {keys: ($bkeys | length), roots: ($roots | length), rkeys: ($rkeys | length), cases: ($cases | length),
   full: [$cases[] | {name, sums: sums($m.segs; .n)}],
   pruned: [$cases[] | usage_pr_scope($urows; $cost; .n) as $sc
     | usage_resolve_t($sc.segs; $sc.bindings; usage_intervals($sc.bindings; $sc.cost)) as $segs
     | {name, sums: sums($segs; .n)}]}'
}

# run_diff <view-jq>: writes the differential to $TMP/diff.json.
run_diff() {
  jq -n --rawfile u "$FX/usage.jsonl" --rawfile l "$FX/links.jsonl" --rawfile c "$FX/cost.jsonl" \
    --argjson keys "$KEYS" --argjson rates "$RATES" "$(diff_prog "$1")" >"$TMP/diff.json"
}

# The differential must go red for a mutant of the prune def: the pruned sums
# differ from the full resolver's, and the mutant is not the shipped text.
assert_mutant_red() {
  local m="$FX/mutants/$1.jq"
  [ -s "$m" ]
  printf '%s' "$GAIA_USAGE_PRUNE_JQ" >"$TMP/shipped.jq"
  if cmp -s "$m" "$TMP/shipped.jq"; then return 1; fi
  run_diff "$(cat "$m")$GAIA_USAGE_VIEW_BODY_JQ"
  jq -e '.full != .pruned' "$TMP/diff.json" >/dev/null
}

@test "differential: pruned per-ref sums equal the full resolver's for every key, root, and resolved ref" {
  run_diff "$GAIA_USAGE_VIEW_JQ"
  [ "$(jq -r '.keys' "$TMP/diff.json")" -eq 9 ]
  [ "$(jq -r '.roots' "$TMP/diff.json")" -eq 6 ]
  [ "$(jq -r '.rkeys' "$TMP/diff.json")" -eq 18 ]
  [ "$(jq -r '.cases' "$TMP/diff.json")" -eq 33 ]
  [ "$(jq -r '.full | length' "$TMP/diff.json")" -eq 33 ]
  # Not vacuous: the cases carry spend, and the usd side is priced.
  [ "$(jq -r '[.full[].sums[].sum.total] | add' "$TMP/diff.json")" -gt 0 ]
  jq -e '[.full[].sums[].sum.usd | select(. != null and . > 0)] | length > 0' "$TMP/diff.json" >/dev/null
  jq -e '.full == .pruned' "$TMP/diff.json" >/dev/null
}

@test "differential: a segment before its first binding, a same-instant tie, and a command interval all resolve as in the full resolver" {
  run_diff "$GAIA_USAGE_VIEW_JQ"
  jq -e '[.full[] | select(.name == "rkey research:topic2") | .sums[].sum.total] | add > 0' "$TMP/diff.json" >/dev/null
  jq -e '[.full[] | select(.name == "rkey command:gaia-debt-r1") | .sums[].sum.total] | add > 0' "$TMP/diff.json" >/dev/null
  jq -e '[.full[] | select(.name == "rkey spec:SPEC-091") | .sums[].sum.total] | add > 0' "$TMP/diff.json" >/dev/null
  jq -e '.full == .pruned' "$TMP/diff.json" >/dev/null
}

@test "guard red: dropping the binding clause changes a pruned sum" {
  assert_mutant_red no-binding-clause
}

@test "guard red: dropping the cost-row clause changes a pruned sum" {
  assert_mutant_red no-cost-clause
}

@test "guard red: dropping the raw segment key clause changes a pruned sum" {
  assert_mutant_red no-rawkey-clause
}

@test "guard red: keeping only the matching segments of a candidate session changes a pruned sum" {
  assert_mutant_red segment-granular
}

@test "guard red: keeping only the cost rows keyed in N changes a pruned sum" {
  assert_mutant_red filter-cost-rows
}

# equiv_run <libdir> <mode>: runs the views over the prune fixture with the
# libs in <libdir> (usage-resolve-lib.sh, usage-render-lib.sh) and prints one
# JSON document. Modes: `wrapper` binds $u $l $c $keys to the real stores and
# keys; `empty-keys` is the wrapper with $keys = {}; `of` binds $u $l $c to ""
# and $keys to {} and hands the real parsed rows and keys to the `_of` views.
EQUIV_SH='
libdir="$1" mode="$2" scripts="$3" fx="$4" keys="$5" rates="$6"
. "$scripts/usage-lib.sh"
. "$libdir/usage-resolve-lib.sh"
. "$libdir/usage-render-lib.sh"
. "$scripts/token-pricing-lib.sh"
prog="$GAIA_USAGE_JQ_DEFS$GAIA_PRICING_JQ_DEFS$GAIA_USAGE_RESOLVE_JQ$GAIA_USAGE_MODEL_JQ$GAIA_USAGE_VIEW_JQ"
lists="$(jq -n --rawfile u "$fx/usage.jsonl" --rawfile l "$fx/links.jsonl" --rawfile c "$fx/cost.jsonl" \
  --argjson keys "$(cat "$keys")" --argjson rates null \
  "$prog"" usage_rows(\$u) as \$urows | usage_rows(\$l) as \$links | usage_rows(\$c) as \$cost
    | usage_edges(\$links; \$cost; \$keys) as \$edges
    | ([\$urows[] | select(.kind == \"segment\") | .key | strings | select(startswith(\"branch:\"))]
       + [\$links[] | (.child, .parent, .key) | strings | select(startswith(\"branch:\"))]
       + [\$keys.bmap[] | .key | strings] | unique) as \$bkeys
    | {bkeys: \$bkeys, roots: ([\$bkeys[] | usage_roots(\$edges; .)[]] | unique)}")" || exit 1
rt="$(cat "$rates")"
case "$mode" in
  wrapper | empty-keys)
    k="$(cat "$keys")"
    [ "$mode" = empty-keys ] && k="{}"
    jq -nc --rawfile u "$fx/usage.jsonl" --rawfile l "$fx/links.jsonl" --rawfile c "$fx/cost.jsonl" \
      --argjson keys "$k" --argjson rates "$rt" --argjson lists "$lists" \
      "$prog"" {n: ((\$lists.bkeys | length) + 2 + (\$lists.roots | length) + 1),
        pr: ([\$lists.bkeys[] | usage_view_pr(11; .)] + [usage_view_pr(12; null), usage_view_pr(99; null)]),
        ini: [\$lists.roots[] | usage_view_initiative(.)], rec: usage_view_reconcile}" || exit 1 ;;
  of)
    jq -nc --rawfile ru "$fx/usage.jsonl" --rawfile rl "$fx/links.jsonl" --rawfile rc "$fx/cost.jsonl" \
      --arg u "" --arg l "" --arg c "" --argjson keys "{}" --argjson rk "$(cat "$keys")" \
      --argjson rates "$rt" --argjson lists "$lists" \
      "$prog"" usage_rows(\$ru) as \$a | usage_rows(\$rl) as \$b | usage_rows(\$rc) as \$d
        | {n: ((\$lists.bkeys | length) + 2 + (\$lists.roots | length) + 1),
           pr: ([\$lists.bkeys[] | usage_view_pr_of(\$a; \$b; \$d; 11; .; \$rk)]
                + [usage_view_pr_of(\$a; \$b; \$d; 12; null; \$rk), usage_view_pr_of(\$a; \$b; \$d; 99; null; \$rk)]),
           ini: [\$lists.roots[] | usage_view_initiative_of(\$a; \$b; \$d; .; \$rk)],
           rec: usage_view_reconcile_of(\$a; \$b; \$d; \$rk)}" || exit 1 ;;
esac
'

equiv_run() {
  bash -c "$EQUIV_SH" _ "$1" "$2" "$SCRIPTS" "$FX" "$TMP/keys.json" "$RATES_FILE"
}

@test "globals-blank: every _of view over the real rows and keys equals its wrapper over the real globals" {
  equiv_run "$SCRIPTS" wrapper >"$TMP/wrapper.json"
  equiv_run "$SCRIPTS" of >"$TMP/of.json"
  # 9 keys, 2 null-key pr calls, 6 roots, 1 reconcile
  [ "$(jq -r '.n' "$TMP/wrapper.json")" -eq 18 ]
  [ "$(jq -r '(.pr | length) + (.ini | length) + 1' "$TMP/wrapper.json")" -eq 18 ]
  cmp -s "$TMP/wrapper.json" "$TMP/of.json"
  # Not vacuous: the figures are non-zero and the fixture's derived edges reach
  # a compared view, so a view that read the global $keys = {} would change.
  [ "$(jq -r '[.ini[].roots[].sum.total] | add' "$TMP/wrapper.json")" -gt 0 ]
  [ "$(jq -r '.derive | length' "$TMP/keys.json")" -gt 0 ]
  equiv_run "$SCRIPTS" empty-keys >"$TMP/empty.json"
  if cmp -s "$TMP/wrapper.json" "$TMP/empty.json"; then return 1; fi
}

# apply_sed_mutant <lib file> <sed script> <pattern>: scratch copy of the
# shipped lib with the mutation applied; the substitution must have matched.
apply_sed_mutant() {
  local lib="$1" sedf="$FX/mutants/$2.sed" pat="$3"
  mkdir -p "$TMP/mut"
  cp "$SCRIPTS/usage-resolve-lib.sh" "$SCRIPTS/usage-render-lib.sh" "$TMP/mut/"
  [ "$(grep -cF -- "$pat" "$TMP/mut/$lib")" -ge 1 ]
  sed -f "$sedf" "$TMP/mut/$lib" >"$TMP/mut/$lib.new"
  mv "$TMP/mut/$lib.new" "$TMP/mut/$lib"
  [ "$(grep -cF -- "$pat" "$TMP/mut/$lib")" -eq 0 ]
}

@test "guard red: reconcile pricing through the no-arg usage_model reads the global rows" {
  apply_sed_mutant usage-render-lib.sh reads-global-rows 'usage_model_of($urows; $links; $cost; $keys) as $m'
  equiv_run "$TMP/mut" wrapper >"$TMP/wrapper.json"
  equiv_run "$TMP/mut" of >"$TMP/of.json"
  [ -s "$TMP/wrapper.json" ]
  [ -s "$TMP/of.json" ]
  if cmp -s "$TMP/wrapper.json" "$TMP/of.json"; then return 1; fi
}

@test "guard red: a usage_model_base_of without its keys parameter reads the global keys" {
  apply_sed_mutant usage-resolve-lib.sh reads-global-keys 'def usage_model_base_of($urows; $links; $cost; $keys):'
  equiv_run "$TMP/mut" wrapper >"$TMP/wrapper.json"
  equiv_run "$TMP/mut" of >"$TMP/of.json"
  [ -s "$TMP/wrapper.json" ]
  [ -s "$TMP/of.json" ]
  if cmp -s "$TMP/wrapper.json" "$TMP/of.json"; then return 1; fi
}
