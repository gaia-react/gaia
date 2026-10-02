#!/usr/bin/env bats
#
# The per-PR view resolves only the sessions that can reach a segment under
# the PR's key or its roots' closures (usage_pr_scope), and every `_of` view
# reads rows and keys only through its parameters. Both are checked against
# the shipped jq defs, never a re-implementation:
#   - the differential compares the full resolver's per-ref sums with the
#     pruned sums, and goes red for each committed mutant of the prune def;
#   - the globals-blank equivalence runs each `_of` view with $usage_store, $links_store, $cost_store bound
#     to "" and $keys to {}, and goes red for each committed sed mutant.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/usage-prune.bats

# shellcheck disable=SC2016  # jq programs and sed patterns are single-quoted on purpose

bats_require_minimum_version 1.5.0

setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FIXTURES_DIRECTORY="$BATS_TEST_DIRNAME/fixtures/usage/prune"
  RATES_FILE="$BATS_TEST_DIRNAME/fixtures/usage/resolve/rates-a.json"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  MAIN="$TEMPORARY_DIRECTORY/main"
  git -C "$TEMPORARY_DIRECTORY" init -q -b main main
  git -C "$MAIN" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false commit -q --allow-empty -m init
  # shellcheck source=.gaia/scripts/usage-lib.sh
  . "$SCRIPTS/usage-lib.sh"
  # shellcheck source=.gaia/scripts/usage-resolve-lib.sh
  . "$SCRIPTS/usage-resolve-lib.sh"
  # shellcheck source=.gaia/scripts/usage-render-lib.sh
  . "$SCRIPTS/usage-render-lib.sh"
  # shellcheck source=.gaia/scripts/token-pricing-lib.sh
  . "$SCRIPTS/token-pricing-lib.sh"
  KEYS="$(gaia_usage_keys_json "$MAIN" "$FIXTURES_DIRECTORY/usage.jsonl" "$FIXTURES_DIRECTORY/links.jsonl" "$FIXTURES_DIRECTORY/cost.jsonl")"
  RATES="$(gaia_load_rate_table "$RATES_FILE")"
  export KEYS RATES
  printf '%s' "$KEYS" >"$TEMPORARY_DIRECTORY/keys.json"
}

# diff_prog <view-jq>: the differential over every key, root, and resolved ref.
# Each case is a usage_set N; per ref in N, the full resolver's sum is compared
# with the sum over only the sessions usage_pr_scope keeps.
diff_prog() {
  # shellcheck disable=SC2016  # jq source
  printf '%s%s%s%s%s' "$GAIA_USAGE_JQ_DEFS" "$GAIA_PRICING_JQ_DEFS" "$GAIA_USAGE_RESOLVE_JQ" "$GAIA_USAGE_MODEL_JQ" "$1"'
usage_rows($usage_store) as $usage_records | usage_rows($links_store) as $links | usage_rows($cost_store) as $cost
| usage_model_base_of($usage_records; $links; $cost; $keys) as $readout_model
| $readout_model.edges as $edges
| ([$usage_records[] | select(.kind == "segment") | .key | strings | select(startswith("branch:"))]
   + [$links[] | (.child, .parent, .key) | strings | select(startswith("branch:"))]
   + [$keys.bmap[] | .key | strings] | unique) as $branch_keys
| ([$branch_keys[] | usage_roots($edges; .)[]] | unique) as $roots
| ([$readout_model.segs[].rkey | strings] | unique) as $resolved_keys
| ([$branch_keys[] | . as $branch_key | {name: ("key " + $branch_key),
      reference_set: usage_set([$branch_key] + [usage_roots($edges; $branch_key)[] | select(. != $branch_key) | usage_closure($edges; .)[]])}]
  + [$roots[] | . as $root | {name: ("root " + $root), reference_set: usage_set(usage_closure($edges; $root))}]
  + [$resolved_keys[] | . as $resolved_key | {name: ("rkey " + $resolved_key), reference_set: {($resolved_key): true}}]) as $cases
| def sums($segments; $reference_set):
    [$reference_set | to_entries[] | .key as $reference | {ref: $reference, sum: usage_sum([$segments[] | select(.rkey == $reference) | usage_priced])}];
  {keys: ($branch_keys | length), roots: ($roots | length), resolved_keys: ($resolved_keys | length), cases: ($cases | length),
   full: [$cases[] | {name, sums: sums($readout_model.segs; .reference_set)}],
   pruned: [$cases[] | usage_pr_scope($usage_records; $cost; .reference_set) as $scope
     | usage_resolve_t($scope.segs; $scope.bindings; usage_intervals($scope.bindings; $scope.cost)) as $segments
     | {name, sums: sums($segments; .reference_set)}]}'
}

# run_diff <view-jq>: writes the differential to $TEMPORARY_DIRECTORY/diff.json.
run_diff() {
  jq -n --rawfile usage_store "$FIXTURES_DIRECTORY/usage.jsonl" --rawfile links_store "$FIXTURES_DIRECTORY/links.jsonl" --rawfile cost_store "$FIXTURES_DIRECTORY/cost.jsonl" \
    --argjson keys "$KEYS" --argjson rates "$RATES" "$(diff_prog "$1")" >"$TEMPORARY_DIRECTORY/diff.json"
}

# The differential must go red for a mutant of the prune def: the pruned sums
# differ from the full resolver's, and the mutant is not the shipped text.
assert_mutant_red() {
  local mutant_filter="$FIXTURES_DIRECTORY/mutants/$1.jq"
  [ -s "$mutant_filter" ]
  printf '%s' "$GAIA_USAGE_PRUNE_JQ" >"$TEMPORARY_DIRECTORY/shipped.jq"
  if cmp -s "$mutant_filter" "$TEMPORARY_DIRECTORY/shipped.jq"; then return 1; fi
  run_diff "$(cat "$mutant_filter")$GAIA_USAGE_VIEW_BODY_JQ"
  jq -e '.full != .pruned' "$TEMPORARY_DIRECTORY/diff.json" >/dev/null
}

@test "differential: pruned per-ref sums equal the full resolver's for every key, root, and resolved ref" {
  run_diff "$GAIA_USAGE_VIEW_JQ"
  [ "$(jq -r '.keys' "$TEMPORARY_DIRECTORY/diff.json")" -eq 9 ]
  [ "$(jq -r '.roots' "$TEMPORARY_DIRECTORY/diff.json")" -eq 6 ]
  [ "$(jq -r '.resolved_keys' "$TEMPORARY_DIRECTORY/diff.json")" -eq 18 ]
  [ "$(jq -r '.cases' "$TEMPORARY_DIRECTORY/diff.json")" -eq 33 ]
  [ "$(jq -r '.full | length' "$TEMPORARY_DIRECTORY/diff.json")" -eq 33 ]
  # Not vacuous: the cases carry spend, and the usd side is priced.
  [ "$(jq -r '[.full[].sums[].sum.total] | add' "$TEMPORARY_DIRECTORY/diff.json")" -gt 0 ]
  jq -e '[.full[].sums[].sum.usd | select(. != null and . > 0)] | length > 0' "$TEMPORARY_DIRECTORY/diff.json" >/dev/null
  jq -e '.full == .pruned' "$TEMPORARY_DIRECTORY/diff.json" >/dev/null
}

@test "differential: a segment before its first binding, a same-instant tie, and a command interval all resolve as in the full resolver" {
  run_diff "$GAIA_USAGE_VIEW_JQ"
  jq -e '[.full[] | select(.name == "rkey research:topic2") | .sums[].sum.total] | add > 0' "$TEMPORARY_DIRECTORY/diff.json" >/dev/null
  jq -e '[.full[] | select(.name == "rkey command:gaia-debt-r1") | .sums[].sum.total] | add > 0' "$TEMPORARY_DIRECTORY/diff.json" >/dev/null
  jq -e '[.full[] | select(.name == "rkey spec:SPEC-091") | .sums[].sum.total] | add > 0' "$TEMPORARY_DIRECTORY/diff.json" >/dev/null
  jq -e '.full == .pruned' "$TEMPORARY_DIRECTORY/diff.json" >/dev/null
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

# equiv_run <library_directory> <mode>: runs the views over the prune fixture with the
# libs in <library_directory> (usage-resolve-lib.sh, usage-render-lib.sh) and prints one
# JSON document. Modes: `wrapper` binds $usage_store $links_store $cost_store $keys to the real stores and
# keys; `empty-keys` is the wrapper with $keys = {}; `of` binds $usage_store $links_store $cost_store to ""
# and $keys to {} and hands the real parsed rows and keys to the `_of` views.
EQUIV_SH='
library_directory="$1" mode="$2" scripts="$3" fixtures_directory="$4" keys="$5" rates="$6"
. "$scripts/usage-lib.sh"
. "$library_directory/usage-resolve-lib.sh"
. "$library_directory/usage-render-lib.sh"
. "$scripts/token-pricing-lib.sh"
program="$GAIA_USAGE_JQ_DEFS$GAIA_PRICING_JQ_DEFS$GAIA_USAGE_RESOLVE_JQ$GAIA_USAGE_MODEL_JQ$GAIA_USAGE_VIEW_JQ"
lists="$(jq -n --rawfile usage_store "$fixtures_directory/usage.jsonl" --rawfile links_store "$fixtures_directory/links.jsonl" --rawfile cost_store "$fixtures_directory/cost.jsonl" \
  --argjson keys "$(cat "$keys")" --argjson rates null \
  "$program"" usage_rows(\$usage_store) as \$usage_records | usage_rows(\$links_store) as \$links | usage_rows(\$cost_store) as \$cost
    | usage_edges(\$links; \$cost; \$keys) as \$edges
    | ([\$usage_records[] | select(.kind == \"segment\") | .key | strings | select(startswith(\"branch:\"))]
       + [\$links[] | (.child, .parent, .key) | strings | select(startswith(\"branch:\"))]
       + [\$keys.bmap[] | .key | strings] | unique) as \$branch_keys
    | {branch_keys: \$branch_keys, roots: ([\$branch_keys[] | usage_roots(\$edges; .)[]] | unique)}")" || exit 1
rates_text="$(cat "$rates")"
case "$mode" in
  wrapper | empty-keys)
    keys_text="$(cat "$keys")"
    [ "$mode" = empty-keys ] && keys_text="{}"
    jq -nc --rawfile usage_store "$fixtures_directory/usage.jsonl" --rawfile links_store "$fixtures_directory/links.jsonl" --rawfile cost_store "$fixtures_directory/cost.jsonl" \
      --argjson keys "$keys_text" --argjson rates "$rates_text" --argjson lists "$lists" \
      "$program"" {view_count: ((\$lists.branch_keys | length) + 2 + (\$lists.roots | length) + 1),
        pr: ([\$lists.branch_keys[] | usage_view_pr(11; .)] + [usage_view_pr(12; null), usage_view_pr(99; null)]),
        initiatives: [\$lists.roots[] | usage_view_initiative(.)], reconcile: usage_view_reconcile}" || exit 1 ;;
  of)
    jq -nc --rawfile real_usage_store "$fixtures_directory/usage.jsonl" --rawfile real_links_store "$fixtures_directory/links.jsonl" --rawfile real_cost_store "$fixtures_directory/cost.jsonl" \
      --arg usage_store "" --arg links_store "" --arg cost_store "" --argjson keys "{}" --argjson real_keys "$(cat "$keys")" \
      --argjson rates "$rates_text" --argjson lists "$lists" \
      "$program"" usage_rows(\$real_usage_store) as \$usage_records | usage_rows(\$real_links_store) as \$links | usage_rows(\$real_cost_store) as \$cost
        | {view_count: ((\$lists.branch_keys | length) + 2 + (\$lists.roots | length) + 1),
           pr: ([\$lists.branch_keys[] | usage_view_pr_of(\$usage_records; \$links; \$cost; 11; .; \$real_keys)]
                + [usage_view_pr_of(\$usage_records; \$links; \$cost; 12; null; \$real_keys), usage_view_pr_of(\$usage_records; \$links; \$cost; 99; null; \$real_keys)]),
           initiatives: [\$lists.roots[] | usage_view_initiative_of(\$usage_records; \$links; \$cost; .; \$real_keys)],
           reconcile: usage_view_reconcile_of(\$usage_records; \$links; \$cost; \$real_keys)}" || exit 1 ;;
esac
'

equiv_run() {
  bash -c "$EQUIV_SH" _ "$1" "$2" "$SCRIPTS" "$FIXTURES_DIRECTORY" "$TEMPORARY_DIRECTORY/keys.json" "$RATES_FILE"
}

@test "globals-blank: every _of view over the real rows and keys equals its wrapper over the real globals" {
  equiv_run "$SCRIPTS" wrapper >"$TEMPORARY_DIRECTORY/wrapper.json"
  equiv_run "$SCRIPTS" of >"$TEMPORARY_DIRECTORY/of.json"
  # 9 keys, 2 null-key pr calls, 6 roots, 1 reconcile
  [ "$(jq -r '.view_count' "$TEMPORARY_DIRECTORY/wrapper.json")" -eq 18 ]
  [ "$(jq -r '(.pr | length) + (.initiatives | length) + 1' "$TEMPORARY_DIRECTORY/wrapper.json")" -eq 18 ]
  cmp -s "$TEMPORARY_DIRECTORY/wrapper.json" "$TEMPORARY_DIRECTORY/of.json"
  # Not vacuous: the figures are non-zero and the fixture's derived edges reach
  # a compared view, so a view that read the global $keys = {} would change.
  [ "$(jq -r '[.initiatives[].roots[].sum.total] | add' "$TEMPORARY_DIRECTORY/wrapper.json")" -gt 0 ]
  [ "$(jq -r '.derive | length' "$TEMPORARY_DIRECTORY/keys.json")" -gt 0 ]
  equiv_run "$SCRIPTS" empty-keys >"$TEMPORARY_DIRECTORY/empty.json"
  if cmp -s "$TEMPORARY_DIRECTORY/wrapper.json" "$TEMPORARY_DIRECTORY/empty.json"; then return 1; fi
}

# apply_sed_mutant <lib file> <sed script> <pattern>: scratch copy of the
# shipped lib with the mutation applied; the substitution must have matched.
apply_sed_mutant() {
  local library_file="$1" sed_file="$FIXTURES_DIRECTORY/mutants/$2.sed" pattern="$3"
  mkdir -p "$TEMPORARY_DIRECTORY/mut"
  cp "$SCRIPTS/usage-resolve-lib.sh" "$SCRIPTS/usage-render-lib.sh" "$TEMPORARY_DIRECTORY/mut/"
  [ "$(grep -cF -- "$pattern" "$TEMPORARY_DIRECTORY/mut/$library_file")" -ge 1 ]
  sed -f "$sed_file" "$TEMPORARY_DIRECTORY/mut/$library_file" >"$TEMPORARY_DIRECTORY/mut/$library_file.new"
  mv "$TEMPORARY_DIRECTORY/mut/$library_file.new" "$TEMPORARY_DIRECTORY/mut/$library_file"
  [ "$(grep -cF -- "$pattern" "$TEMPORARY_DIRECTORY/mut/$library_file")" -eq 0 ]
}

@test "guard red: reconcile pricing through the no-arg usage_model reads the global rows" {
  apply_sed_mutant usage-render-lib.sh reads-global-rows 'usage_model_of($usage_records; $links; $cost; $keys) as $readout_model'
  equiv_run "$TEMPORARY_DIRECTORY/mut" wrapper >"$TEMPORARY_DIRECTORY/wrapper.json"
  equiv_run "$TEMPORARY_DIRECTORY/mut" of >"$TEMPORARY_DIRECTORY/of.json"
  [ -s "$TEMPORARY_DIRECTORY/wrapper.json" ]
  [ -s "$TEMPORARY_DIRECTORY/of.json" ]
  if cmp -s "$TEMPORARY_DIRECTORY/wrapper.json" "$TEMPORARY_DIRECTORY/of.json"; then return 1; fi
}

@test "guard red: a usage_model_base_of without its keys parameter reads the global keys" {
  apply_sed_mutant usage-resolve-lib.sh reads-global-keys 'def usage_model_base_of($usage_records; $links; $cost; $keys):'
  equiv_run "$TEMPORARY_DIRECTORY/mut" wrapper >"$TEMPORARY_DIRECTORY/wrapper.json"
  equiv_run "$TEMPORARY_DIRECTORY/mut" of >"$TEMPORARY_DIRECTORY/of.json"
  [ -s "$TEMPORARY_DIRECTORY/wrapper.json" ]
  [ -s "$TEMPORARY_DIRECTORY/of.json" ]
  if cmp -s "$TEMPORARY_DIRECTORY/wrapper.json" "$TEMPORARY_DIRECTORY/of.json"; then return 1; fi
}
