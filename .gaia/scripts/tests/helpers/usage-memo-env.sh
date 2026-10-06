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
  local digest_line
  if digest_line="$(shasum -a 256 "$1" 2>/dev/null)" && [ -n "$digest_line" ]; then :
  elif digest_line="$(sha256sum "$1" 2>/dev/null)" && [ -n "$digest_line" ]; then :
  else return 1; fi
  printf '%s' "${digest_line%% *}"
}

# umemo_verify_baseline [baseline_directory]: rc 0 when every pinned file is present and
# matches SHA256SUMS; otherwise names the file and the reason on stderr.
umemo_verify_baseline() {
  local baseline_directory="${1:-$UM_BASELINE_DIRECTORY}" pinned_name want got
  [ -f "$baseline_directory/SHA256SUMS" ] || { _umemo_fail "baseline SHA256SUMS missing in $baseline_directory"; return 1; }
  for pinned_name in $UMEMO_PINNED; do
    [ -f "$baseline_directory/$pinned_name" ] || { _umemo_fail "baseline file missing: $pinned_name (expected in $baseline_directory)"; return 1; }
    want="$(awk -v pinned_name="$pinned_name" '$2 == pinned_name { print $1 }' "$baseline_directory/SHA256SUMS")"
    [ -n "$want" ] || { _umemo_fail "baseline SHA256SUMS has no line for $pinned_name"; return 1; }
    got="$(_umemo_sha256 "$baseline_directory/$pinned_name")" || { _umemo_fail "no sha256 tool (shasum or sha256sum) to verify the baseline"; return 1; }
    [ "$got" = "$want" ] || { _umemo_fail "baseline sha256 mismatch for $pinned_name: want $want, got $got"; return 1; }
  done
  return 0
}

# _umemo_build_tree <root>: the scripts a usage readout loads, copied from the
# working tree, laid out as in a real checkout so the lock lib resolves.
_umemo_build_tree() {
  local root="$1" script_file
  mkdir -p "$root/.gaia/scripts" "$root/.gaia/scripts/spec"
  for script_file in "$UM_SOURCE_ROOT"/.gaia/scripts/usage*.sh "$UM_SOURCE_ROOT"/.gaia/scripts/token-pricing-lib.sh \
    "$UM_SOURCE_ROOT"/.gaia/scripts/token-rates-local-lib.sh "$UM_SOURCE_ROOT"/.gaia/scripts/token-rates-feed-lib.sh \
    "$UM_SOURCE_ROOT"/.gaia/scripts/ledger-path-lib.sh "$UM_SOURCE_ROOT"/.gaia/scripts/main-root-lib.sh \
    "$UM_SOURCE_ROOT"/.gaia/scripts/branch-name-lib.sh "$UM_SOURCE_ROOT"/.gaia/scripts/token-rollup.sh; do
    cp "$script_file" "$root/.gaia/scripts/" || return 1
  done
  cp "$UM_SOURCE_ROOT/.gaia/scripts/spec/with-ledger-lock.sh" "$root/.gaia/scripts/spec/" || return 1
  cat >"$root/.gaia/scripts/token-rates.json" <<'EOF'
{
  "cache_multipliers": { "read": 0.1, "write_5m": 1.25, "write_1h": 2.0 },
  "models": { "claude-opus-5-5": [ { "input": 2, "output": 10 } ] }
}
EOF
}

# umemo_setup: builds $UM_NEW and $UM_OLD (script trees), $UM_MAIN (scratch main
# root, capture hooks registered), $UM_TELEMETRY_DIRECTORY (its telemetry dir), $UM_PROJECTS_DIRECTORY (empty
# projects root), $UM_RATES (the committed rate table), and the hermetic env.
# Idempotent: a second call rebuilds over the first.
umemo_setup() {
  local pinned_file
  UM_SOURCE_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)" || return 1
  UM_FIXTURES="$BATS_TEST_DIRNAME/fixtures/usage"
  UM_BASELINE_DIRECTORY="${UM_BASELINE_DIRECTORY:-$UM_FIXTURES/baseline-e4b57e23}"
  umemo_verify_baseline "$UM_BASELINE_DIRECTORY" || return 1
  UM_TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)" || return 1
  UM_NEW="$UM_TEMPORARY_DIRECTORY/tree-new"
  UM_OLD="$UM_TEMPORARY_DIRECTORY/tree-old"
  _umemo_build_tree "$UM_NEW" || return 1
  _umemo_build_tree "$UM_OLD" || return 1
  for pinned_file in $UMEMO_PINNED; do
    cp "$UM_BASELINE_DIRECTORY/$pinned_file" "$UM_OLD/.gaia/scripts/$pinned_file" || return 1
  done
  # The frozen baseline loads the ledger lock only from its old relative path.
  mkdir -p "$UM_OLD/.specify/extensions/gaia/lib" || return 1
  cp "$UM_SOURCE_ROOT/.gaia/scripts/spec/with-ledger-lock.sh" "$UM_OLD/.specify/extensions/gaia/lib/" || return 1
  UM_MAIN="$UM_TEMPORARY_DIRECTORY/main"
  UM_TELEMETRY_DIRECTORY="$UM_MAIN/.gaia/local/telemetry"
  UM_PROJECTS_DIRECTORY="$UM_TEMPORARY_DIRECTORY/projects"
  UM_RATES="$UM_FIXTURES/identity/rates.json"
  mkdir -p "$UM_MAIN/.claude" "$UM_TELEMETRY_DIRECTORY" "$UM_PROJECTS_DIRECTORY" || return 1
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
  UM_OUTPUT_FILE="$UM_TEMPORARY_DIRECTORY/u.out"
  UM_ERROR_FILE="$UM_TEMPORARY_DIRECTORY/u.err"
  export GAIA_RATES_FEED_DISABLE=1 GAIA_RATES_STATE_DIRECTORY="$UM_TEMPORARY_DIRECTORY/rates-state"
  unset CLAUDE_CODE_SESSION_ID GAIA_TALLY_PROJECTS_ROOT GITHUB_ACTIONS GAIA_USAGE_MEMO_TRACE GAIA_USAGE_MEMO_SEAM
  return 0
}

# _umemo_run <tree> <output_file> <error_file> <args...>: one usage.sh run, stdout and stderr
# captured separately; returns the script's exit status.
_umemo_run() {
  local tree="$1" output_file="$2" error_file="$3" exit_status=0
  shift 3
  bash "$tree/.gaia/scripts/usage.sh" "$@" --main-root "$UM_MAIN" --telemetry-dir "$UM_TELEMETRY_DIRECTORY" \
    --rate-table "$UM_RATES" --projects-root "$UM_PROJECTS_DIRECTORY" >"$output_file" 2>"$error_file" || exit_status=$?
  return "$exit_status"
}

# Output lands in $UM_OUTPUT_FILE and $UM_ERROR_FILE (reassign either before a call to keep an
# earlier run's capture); under bats' `run` the function is a subshell, so read
# the files, not $output.
u_new() { _umemo_run "$UM_NEW" "$UM_OUTPUT_FILE" "$UM_ERROR_FILE" "$@"; }
u_old() { _umemo_run "$UM_OLD" "$UM_OUTPUT_FILE" "$UM_ERROR_FILE" "$@"; }

# umemo_load_store <name>: copies fixtures/usage/<name>/{usage,links,cost}.jsonl
# into $UM_TELEMETRY_DIRECTORY (replacing whatever was there).
umemo_load_store() {
  local store_file store_directory="$UM_FIXTURES/$1"
  [ -d "$store_directory" ] || { _umemo_fail "no fixture store named '$1' under $UM_FIXTURES"; return 1; }
  mkdir -p "$UM_TELEMETRY_DIRECTORY" || return 1
  for store_file in usage.jsonl links.jsonl cost.jsonl; do
    if [ -f "$store_directory/$store_file" ]; then cp "$store_directory/$store_file" "$UM_TELEMETRY_DIRECTORY/$store_file" || return 1; else rm -f "$UM_TELEMETRY_DIRECTORY/$store_file"; fi
  done
}

# assert_priced <file> [--roots]: the file carries token and dollar figures
# (and an initiative line with --roots). A degenerate output (a header-only
# block, a rate table that did not load) would let a byte comparison pass
# vacuously, so every compared pr output goes through this first.
assert_priced() {
  local output_file="$1" roots="${2:-}"
  grep -q '^  tokens: ' "$output_file" || { printf 'assert_priced: no "  tokens: " line in %s:\n%s\n' "$output_file" "$(cat "$output_file")" >&2; return 1; }
  grep -qF 'est. cost (USD): $' "$output_file" || { printf 'assert_priced: no "est. cost (USD): $" figure in %s:\n%s\n' "$output_file" "$(cat "$output_file")" >&2; return 1; }
  if [ "$roots" = --roots ]; then
    grep -q '^\[initiative ' "$output_file" || { printf 'assert_priced: no "[initiative " line in %s:\n%s\n' "$output_file" "$(cat "$output_file")" >&2; return 1; }
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
  local violations
  violations="$(jq -r --arg category_names "$UMEMO_CATEGORIES" --arg expect_key_names "$UMEMO_EXPECT_KEYS" '
    . as $document | ($category_names | split(" ")) as $known_categories | ($expect_key_names | split(" ")) as $known_expect_keys
    | def keys_are($object; $want; $what): if ($object | type) != "object" then "\($what): not an object"
        elif ($object | keys) != ($want | sort) then "\($what): keys are \($object | keys | join(",")), want \($want | sort | join(","))"
        else empty end;
      def is_integer: type == "number" and . == floor;
      def need($category_name): {first_merge: "merges", repeat_merge: "merges", multi_root: "roots_min", wide_root: "roots_min",
        inherit: "inherit", interval: "interval", no_spend: "no_spend", unresolvable: "unresolvable",
        lower_bound: "lower_bound", cursor_adversarial: "nonzero"}[$category_name];
      keys_are($document; ["probes", "initiative_roots", "anchors"]; "top level"),
      (if ($document.probes | type) != "array" then "probes: not an array"
       elif ($document.probes | length) < 20 then "probes: \($document.probes | length) entries, want at least 20"
       else empty end),
      (($document.probes // [])[]? | . as $probe
        | (keys_are($probe; ["pr", "key", "raw", "category", "expect"]; "probe \($probe.pr)"),
           (if ($probe.pr | is_integer | not) then "probe \($probe.pr): pr is not an integer" else empty end),
           (if ($probe.key != null and (($probe.key | type) != "string" or ($probe.key | startswith("branch:") | not))) then "probe \($probe.pr): key is neither null nor a branch ref" else empty end),
           (if ($probe.raw != null and ($probe.raw | type) != "string") then "probe \($probe.pr): raw is neither null nor a string" else empty end),
           (if ($known_categories | index($probe.category)) == null then "probe \($probe.pr): unknown category \($probe.category)"
            else
              (if ($probe.expect | type) != "object" then "probe \($probe.pr): expect is not an object"
               else
                 ($probe.expect | keys[] | select(. as $expect_key | ($known_expect_keys | index($expect_key)) == null) | "probe \($probe.pr): unknown expect key \(.)"),
                 (need($probe.category) as $needed_key | if $needed_key == null then empty
                  elif ($probe.expect | has($needed_key) | not) then "probe \($probe.pr): category \($probe.category) needs expect.\($needed_key)"
                  else empty end),
                 ($probe.expect | to_entries[] | select(.key == "roots_min" or .key == "merges") | select(.value | is_integer | not) | "probe \($probe.pr): expect.\(.key) is not an integer"),
                 ($probe.expect | to_entries[] | select(.key != "roots_min" and .key != "merges") | select(.value | type != "boolean") | "probe \($probe.pr): expect.\(.key) is not a boolean"),
                 (if $probe.category == "first_merge" and ($probe.expect.merges != 1) then "probe \($probe.pr): first_merge wants merges 1" else empty end),
                 (if $probe.category == "repeat_merge" and (($probe.expect.merges // 0) < 2) then "probe \($probe.pr): repeat_merge wants merges of 2 or more" else empty end),
                 (if $probe.category == "multi_root" and (($probe.expect.roots_min // 0) < 2) then "probe \($probe.pr): multi_root wants roots_min of 2 or more" else empty end),
                 (if $probe.category == "wide_root" and (($probe.expect.roots_min // 0) < 1) then "probe \($probe.pr): wide_root wants roots_min of 1 or more" else empty end)
               end)
            end),
           (if $probe.category == "unresolvable" and $probe.key != null then "probe \($probe.pr): an unresolvable probe has a null key" else empty end),
           (if $probe.category != "unresolvable" and $probe.key == null then "probe \($probe.pr): only an unresolvable probe has a null key" else empty end))),
      ([$known_categories[] | select(. != "cursor_adversarial" and . != "wide_root")] as $required_categories
        | $required_categories[] | . as $category | select([($document.probes // [])[]? | select(.category == $category)] | length == 0) | "no probe has category \($category)"),
      keys_are($document.initiative_roots; ["research", "issue", "spec"]; "initiative_roots"),
      keys_are($document.anchors; ["open_start", "unbound_session", "spare_root", "new_branch", "cycle"]; "anchors"),
      keys_are($document.anchors.open_start; ["session_id", "key", "pr"]; "anchors.open_start"),
      keys_are($document.anchors.unbound_session; ["session_id", "root", "pr"]; "anchors.unbound_session"),
      keys_are($document.anchors.spare_root; ["ref", "pr"]; "anchors.spare_root"),
      keys_are($document.anchors.new_branch; ["raw", "key", "parent"]; "anchors.new_branch"),
      keys_are($document.anchors.cycle; ["child", "parent"]; "anchors.cycle")
  ' "$1" 2>&1)" || { printf 'probes.json is not valid JSON or the validator failed:\n%s\n' "$violations"; return 1; }
  [ -z "$violations" ] && return 0
  printf '%s\n' "$violations"
  return 1
}

# umemo_probe_count <probes.json>: how many probes the file holds.
umemo_probe_count() { jq -r '.probes | length' "$1"; }

# _umemo_store_jq <filter> [jq args...]: the stores in $UM_TELEMETRY_DIRECTORY as $u, $l, $c and
# the pinned lib's $keys object, with the pinned usage and resolve defs ahead of
# the filter. Pinned so a sibling task editing the working tree's jq cannot
# move what a fixture is checked against.
_umemo_store_jq() {
  local filter="$1" usage_store="$UM_TELEMETRY_DIRECTORY/usage.jsonl" links_store="$UM_TELEMETRY_DIRECTORY/links.jsonl" cost_store="$UM_TELEMETRY_DIRECTORY/cost.jsonl"
  shift
  [ -f "$usage_store" ] || usage_store=/dev/null
  [ -f "$links_store" ] || links_store=/dev/null
  [ -f "$cost_store" ] || cost_store=/dev/null
  (
    # shellcheck source=/dev/null
    . "$UM_OLD/.gaia/scripts/usage-lib.sh" && . "$UM_OLD/.gaia/scripts/usage-resolve-lib.sh" || exit 1
    keys="$(gaia_usage_keys_json "$UM_MAIN" "$usage_store" "$links_store" "$cost_store")" || exit 1
    jq -n --rawfile u "$usage_store" --rawfile l "$links_store" --rawfile c "$cost_store" --argjson keys "$keys" "$@" \
      "$GAIA_USAGE_JQ_DEFS$GAIA_USAGE_RESOLVE_JQ$filter"
  )
}

# umemo_check_probe <probes.json> <index>: the probe at <index> exhibits every
# expect key it carries, as C8's table defines it. Output checks read
# `u_old pr <N>`; store checks run the pinned jq defs over the stores in $UM_TELEMETRY_DIRECTORY.
# Prints each failure on stderr; rc 1 on any.
umemo_check_probe() {
  local probes_file="$1" probe_position="$2" pr key output_file error_file expect_key expect_value exit_status=0 got initiative_count
  pr="$(jq -r --argjson probe_position "$probe_position" '.probes[$probe_position].pr' "$probes_file")" || return 1
  key="$(jq -r --argjson probe_position "$probe_position" '.probes[$probe_position].key // ""' "$probes_file")"
  output_file="$UM_TEMPORARY_DIRECTORY/probe-$pr.out" error_file="$UM_TEMPORARY_DIRECTORY/probe-$pr.err"
  _umemo_run "$UM_OLD" "$output_file" "$error_file" pr "$pr" || { _umemo_fail "probe $pr: u_old pr exited non-zero"; return 1; }
  while IFS=$'\t' read -r expect_key expect_value; do
    case "$expect_key" in
      lower_bound)
        got=false
        grep -qxF '  ! lower bound: branch spend may predate coverage start' "$output_file" && got=true
        [ "$got" = "$expect_value" ] || { _umemo_fail "probe $pr: lower_bound is $got, expect $expect_value"; exit_status=1; }
        ;;
      roots_min)
        initiative_count="$(grep -c '^\[initiative ' "$output_file")" || initiative_count=0
        [ "$initiative_count" -ge "$expect_value" ] || { _umemo_fail "probe $pr: $initiative_count initiative line(s), expect at least $expect_value"; exit_status=1; }
        ;;
      no_spend)
        # A PR that owns no spend still renders a dollar figure ($0.00), so
        # "no spend" is a zero token count with a zero dollar figure.
        got=false
        if grep -qF '  tokens: 0 (' "$output_file" && grep -qxF '  est. cost (USD): $0.00' "$output_file"; then got=true; fi
        [ "$got" = "$expect_value" ] || { _umemo_fail "probe $pr: no_spend is $got, expect $expect_value"; exit_status=1; }
        ;;
      unresolvable)
        got=false
        grep -qF '(branch unresolved)' "$output_file" && got=true
        [ "$got" = "$expect_value" ] || { _umemo_fail "probe $pr: unresolvable is $got, expect $expect_value"; exit_status=1; }
        ;;
      nonzero)
        got=false
        if grep -q '^  tokens: ' "$output_file" && ! grep -qF '  tokens: 0 (' "$output_file"; then got=true; fi
        [ "$got" = "$expect_value" ] || { _umemo_fail "probe $pr: nonzero is $got, expect $expect_value"; exit_status=1; }
        ;;
      merges)
        got="$(_umemo_store_jq 'usage_rows($l) | [.[] | select(.kind == "merge" and .key == $key)] | length' --arg key "$key")" || got=error
        [ "$got" = "$expect_value" ] || { _umemo_fail "probe $pr: $got merge row(s) for $key, expect $expect_value"; exit_status=1; }
        ;;
      inherit)
        got="$(_umemo_store_jq 'usage_rows($u) as $usage_records | [$usage_records[] | select(.kind == "binding")] as $bindings
          | usage_resolve([$usage_records[] | select(.kind == "segment")]; $bindings; usage_intervals($bindings; usage_rows($c)))
          | any(.[]; .inherit == true and .rkey == $key)' --arg key "$key")" || got=error
        [ "$got" = "$expect_value" ] || { _umemo_fail "probe $pr: inherit is $got for $key, expect $expect_value"; exit_status=1; }
        ;;
      interval)
        # An interval resolves a session's segments to a spec: or plan: key, so
        # the segment is found at the probe key or at one of its ancestors (the
        # spec or plan its branch name implies), inside a closed interval.
        got="$(_umemo_store_jq 'usage_rows($u) as $usage_records | usage_rows($l) as $links | usage_rows($c) as $cost
          | [$usage_records[] | select(.kind == "binding")] as $bindings
          | usage_intervals($bindings; $cost) as $intervals
          | usage_resolve_t([$usage_records[] | select(.kind == "segment")]; $bindings; $intervals) as $segments
          | usage_walk(usage_edges($links; $cost; $keys); $key; true).seen as $ancestors
          | any($segments[]; . as $segment | ($segment.rkey | type) == "string" and ($segment.rkey | test("^(spec|plan):"))
              and any($ancestors[]; . == $segment.rkey)
              and any($intervals[]; .session_id == $segment.session_id and .key == $segment.rkey
                and $segment._t != null and .t0 <= $segment._t and $segment._t <= .t1))' --arg key "$key")" || got=error
        [ "$got" = "$expect_value" ] || { _umemo_fail "probe $pr: interval is $got for $key, expect $expect_value"; exit_status=1; }
        ;;
      *) _umemo_fail "probe $pr: unknown expect key $expect_key"; exit_status=1 ;;
    esac
  done < <(jq -r --argjson probe_position "$probe_position" '.probes[$probe_position].expect | to_entries[] | "\(.key)\t\(.value | tojson)"' "$probes_file")
  return "$exit_status"
}

# umemo_check_anchor <probes.json> <name>: the named anchor's precondition holds
# over the stores in $UM_TELEMETRY_DIRECTORY (and, for cycle, over a refused `link`). Prints the
# failure on stderr; rc 1 on failure.
umemo_check_anchor() {
  local probes_file="$1" anchor_name="$2" session_id key pr root reference raw parent child got output_file error_file before
  case "$anchor_name" in
    open_start)
      session_id="$(jq -r '.anchors.open_start.session_id' "$probes_file")" key="$(jq -r '.anchors.open_start.key' "$probes_file")"
      pr="$(jq -r '.anchors.open_start.pr' "$probes_file")"
      got="$(_umemo_store_jq 'usage_rows($u) as $usage_records | usage_rows($l) as $links | usage_rows($c) as $cost
        | [$usage_records[] | select(.kind == "binding")] as $bindings
        | usage_resolve([$usage_records[] | select(.kind == "segment")]; $bindings; usage_intervals($bindings; $cost)) as $segments
        | usage_edges($links; $cost; $keys) as $edges
        | any($bindings[]; .type == "start" and .session_id == $session_id)
          and ([$cost[] | select(.session_id == $session_id)] | length == 0)
          and ([$segments[] | select(.session_id == $session_id)] | length > 0)
          and all($segments[] | select(.session_id == $session_id); .rkey == "session:" + $session_id)
          and any($edges[]; .child == $key and (.parent | test("^(spec|plan):")))' --arg session_id "$session_id" --arg key "$key")" || got=error
      [ "$got" = true ] || { _umemo_fail "anchor open_start: $session_id is not an open-start session whose key $key would claim (got $got)"; return 1; }
      [ "$(jq -r --argjson pr_number "$pr" --arg key "$key" '[.probes[] | select(.pr == $pr_number and .key == $key)] | length' "$probes_file")" = 1 ] ||
        { _umemo_fail "anchor open_start: no probe has pr $pr and key $key"; return 1; }
      ;;
    unbound_session)
      session_id="$(jq -r '.anchors.unbound_session.session_id' "$probes_file")" root="$(jq -r '.anchors.unbound_session.root' "$probes_file")"
      pr="$(jq -r '.anchors.unbound_session.pr' "$probes_file")"
      got="$(_umemo_store_jq 'usage_rows($u) as $usage_records | [$usage_records[] | select(.kind == "binding")] as $bindings
        | usage_resolve([$usage_records[] | select(.kind == "segment")]; $bindings; usage_intervals($bindings; usage_rows($c))) as $segments
        | ([$segments[] | select(.session_id == $session_id)] | length > 0)
          and all($segments[] | select(.session_id == $session_id); .rkey == "session:" + $session_id)' --arg session_id "$session_id")" || got=error
      [ "$got" = true ] || { _umemo_fail "anchor unbound_session: segments of $session_id do not all resolve to session:$session_id (got $got)"; return 1; }
      output_file="$UM_TEMPORARY_DIRECTORY/anchor-unbound.out" error_file="$UM_TEMPORARY_DIRECTORY/anchor-unbound.err"
      _umemo_run "$UM_OLD" "$output_file" "$error_file" pr "$pr" || true
      grep -qF "[initiative $root to date" "$output_file" || { _umemo_fail "anchor unbound_session: pr $pr prints no [initiative $root line"; return 1; }
      ;;
    spare_root)
      reference="$(jq -r '.anchors.spare_root.ref' "$probes_file")" pr="$(jq -r '.anchors.spare_root.pr' "$probes_file")"
      got="$(_umemo_store_jq 'usage_rows($u) as $usage_records | usage_rows($l) as $links | usage_rows($c) as $cost
        | [$usage_records[] | select(.kind == "binding")] as $bindings
        | usage_resolve([$usage_records[] | select(.kind == "segment")]; $bindings; usage_intervals($bindings; $cost)) as $segments
        | usage_edges($links; $cost; $keys) as $edges
        | usage_closure($edges; $reference) as $closure
        | ([$segments[] | select(.rkey as $root_key | any($closure[]; . == $root_key)) | .by_model | to_entries[] | .value.fresh_input // 0] | add // 0) > 0' \
        --arg reference "$reference")" || got=error
      [ "$got" = true ] || { _umemo_fail "anchor spare_root: $reference owns no spend (got $got)"; return 1; }
      got="$(_umemo_store_jq 'usage_rows($l) as $links | usage_rows($c) as $cost | usage_edges($links; $cost; $keys) as $edges
        | [$probes[0].probes[] | .key | strings | . as $key | usage_walk($edges; $key; true).seen | any(.[]; . == $reference)] | any' \
        --arg reference "$reference" --slurpfile probes "$probes_file")" || got=error
      [ "$got" = false ] || { _umemo_fail "anchor spare_root: a probe key reaches $reference (got $got)"; return 1; }
      [ "$(jq -r --argjson pr_number "$pr" '[.probes[] | select(.pr == $pr_number)] | length' "$probes_file")" = 1 ] || { _umemo_fail "anchor spare_root: no probe has pr $pr"; return 1; }
      ;;
    new_branch)
      raw="$(jq -r '.anchors.new_branch.raw' "$probes_file")" key="$(jq -r '.anchors.new_branch.key' "$probes_file")"
      parent="$(jq -r '.anchors.new_branch.parent' "$probes_file")"
      case "$raw" in */*) ;; *) _umemo_fail "anchor new_branch: raw $raw has no slash"; return 1 ;; esac
      for got in usage links cost; do
        if [ -f "$UM_TELEMETRY_DIRECTORY/$got.jsonl" ] && { grep -qF -- "$raw" "$UM_TELEMETRY_DIRECTORY/$got.jsonl" || grep -qF -- "$key" "$UM_TELEMETRY_DIRECTORY/$got.jsonl"; }; then
          _umemo_fail "anchor new_branch: $raw or $key already occurs in $got.jsonl"
          return 1
        fi
      done
      got="$(bash -c '. "$1/.gaia/scripts/usage-lib.sh" && . "$1/.gaia/scripts/usage-resolve-lib.sh" &&
        gaia_usage_branch_map "$2" | jq -r --arg raw "$2" ".[\$raw].key"' _ "$UM_OLD" "$raw")" || got=error
      [ "$got" = "$key" ] || { _umemo_fail "anchor new_branch: gaia_usage_branch_map keys $raw as '$got', not $key"; return 1; }
      got="$(bash -c '. "$1/.gaia/scripts/usage-lib.sh" && . "$1/.gaia/scripts/usage-resolve-lib.sh" &&
        gaia_usage_derive_map "$2" | jq -r --arg key "$2" --arg parent "$3" "(.[\$key] // []) | any(. == \$parent)"' _ "$UM_OLD" "$key" "$parent")" || got=error
      [ "$got" = true ] || { _umemo_fail "anchor new_branch: $key does not derive parent $parent (got $got)"; return 1; }
      got="$(_umemo_store_jq 'usage_rows($u) as $usage_records | usage_rows($l) as $links | usage_rows($c) as $cost
        | [$usage_records[] | select(.kind == "binding")] as $bindings
        | usage_resolve([$usage_records[] | select(.kind == "segment")]; $bindings; usage_intervals($bindings; $cost)) as $segments
        | usage_closure(usage_edges($links; $cost; $keys); $parent) as $closure
        | ([$segments[] | select(.rkey as $root_key | any($closure[]; . == $root_key)) | .by_model | to_entries[] | .value.fresh_input // 0] | add // 0) > 0' \
        --arg parent "$parent")" || got=error
      [ "$got" = true ] || { _umemo_fail "anchor new_branch: parent $parent owns no spend (got $got)"; return 1; }
      ;;
    cycle)
      child="$(jq -r '.anchors.cycle.child' "$probes_file")" parent="$(jq -r '.anchors.cycle.parent' "$probes_file")"
      before="$UM_TEMPORARY_DIRECTORY/links.before"
      if [ -f "$UM_TELEMETRY_DIRECTORY/links.jsonl" ]; then cp "$UM_TELEMETRY_DIRECTORY/links.jsonl" "$before"; else : >"$before"; fi
      output_file="$UM_TEMPORARY_DIRECTORY/anchor-cycle.out" error_file="$UM_TEMPORARY_DIRECTORY/anchor-cycle.err"
      got=0
      _umemo_run "$UM_OLD" "$output_file" "$error_file" link "$child" "$parent" || got=$?
      [ "$got" = 1 ] || { _umemo_fail "anchor cycle: link $child $parent exited $got, expect 1 (refused)"; return 1; }
      grep -qF 'would close a cycle' "$error_file" || { _umemo_fail "anchor cycle: link $child $parent was refused without the cycle message"; return 1; }
      if [ -f "$UM_TELEMETRY_DIRECTORY/links.jsonl" ]; then cmp -s "$before" "$UM_TELEMETRY_DIRECTORY/links.jsonl" || { _umemo_fail "anchor cycle: a refused link changed links.jsonl"; return 1; }; fi
      ;;
    *) _umemo_fail "unknown anchor $anchor_name"; return 1 ;;
  esac
  return 0
}
