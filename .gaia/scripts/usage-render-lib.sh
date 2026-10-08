# shellcheck shell=bash
# GAIA usage-ledger readouts: the jq views over usage_model and the bash
# printers for the per-PR block, the initiative readout, and the reconcile.
#
# The merge hook prints the per-PR block verbatim, so its line shapes and
# marker literals are a contract with that hook and with the usage-ledger
# wiki page, not free text. Refs appear only inside labeled data lines.
#
# Sourced by usage.sh after usage-lib.sh and usage-resolve-lib.sh. Defines
# GAIA_USAGE_VIEW_JQ and functions only; no side effects at source time.

# Copied from token-rollup.sh, which runs on source and so cannot be sourced
# for one function. Display only: stored values and arithmetic stay raw.
commify() {
  local digits="$1" grouped=""
  case "$digits" in '' | *[!0-9]*) printf '%s' "$digits"; return 0 ;; esac
  while [ "${#digits}" -gt 3 ]; do
    grouped=",${digits:${#digits}-3}${grouped}"
    digits="${digits:0:${#digits}-3}"
  done
  printf '%s%s' "$digits" "$grouped"
}

# _usage_safe <text>: a value read from a transcript, the ledger, or gh, with
# every character outside a plain-name set replaced, so a hook readout carries
# no shell syntax, control sequence, or line break from an untrusted source.
_usage_safe() { printf '%s' "${1//[^A-Za-z0-9._:%@+\/ ,-]/?}"; }

_usage_money() {
  if [ -z "$1" ] || [ "$1" = null ]; then printf 'unavailable (rate table unreadable)'; return 0; fi
  LC_ALL=C printf '$%.2f' "$1" 2>/dev/null || printf 'unavailable'
}

# usage_pr_scope: the sessions the per-PR view must resolve to know every
# segment that can land in $reference_set (a usage_set of the branch key and each root's
# closure). A segment's resolution reads only its own session's bindings, cost
# rows, and non-inherit segments, so a candidate session is passed whole and in
# file order: usage_intervals lets each start claim the earliest unclaimed cost
# row and the usd sums add in order, so filtering a candidate's rows to those
# keyed in $reference_set, or keeping only the matching segments, would change a figure.
# A session is a candidate through a research or declare binding whose ref is
# in $reference_set, a cost row keyed in $reference_set, or a segment whose raw key is in $reference_set. The id is
# grouped as `tojson` so a non-string id compares as usage_by_session_id treats it.
# shellcheck disable=SC2034,SC2016  # consumed by usage.sh; jq source, no shell expansion
GAIA_USAGE_PRUNE_JQ='
def usage_pr_scope($usage_records; $cost; $reference_set):
  (reduce ((($usage_records[] | select(.kind == "binding" and (.type == "research" or .type == "declare")
                and (.ref | type) == "string" and $reference_set[.ref] == true)),
            ($usage_records[] | select(.kind == "segment" and (.key | type) == "string" and $reference_set[.key] == true)),
            ($cost[] | select(usage_row_key(.) as $row_key | $row_key != null and $reference_set[$row_key] == true)))
           | .session_id | tojson) as $session ({}; .[$session] = true)) as $session_set
  | {segs: [$usage_records[] | select(.kind == "segment" and $session_set[.session_id | tojson] == true)],
     bindings: [$usage_records[] | select(.kind == "binding" and $session_set[.session_id | tojson] == true)],
     cost: [$cost[] | select($session_set[.session_id | tojson] == true)]};
'

# shellcheck disable=SC2034,SC2016  # consumed by usage.sh; jq source, no shell expansion
GAIA_USAGE_VIEW_BODY_JQ='
def usage_unattributed: (.rkey | type) != "string" or (.rkey | startswith("session:"));
# $closure_set is usage_set of a closure: a lookup per segment, not a scan of the closure.
def usage_set($references): reduce $references[] as $reference ({}; .[$reference] = true);
def usage_in($closure_set): (.rkey | type) == "string" and $closure_set[.rkey] == true;

# The views read rows and keys only through their parameters; the wrappers
# below bind the globals $usage_store, $links_store, $cost_store, and $keys for the filters that still use
# the old names. A $keys parameter also defines a filter named keys that
# shadows the builtin inside the def, so these bodies spell it to_entries.
def usage_view_pr_of($usage_records; $links; $cost; $pr; $key; $keys):
  usage_edges($links; $cost; $keys) as $edges
  | ([$usage_records[] | select(.kind == "segment") | {epoch: (.first_ts | usage_epoch), iso: .first_ts} | select(.epoch != null)]
      | min_by(.epoch)) as $coverage_start
  | (if $coverage_start == null then null else $coverage_start.iso[0:10] end) as $coverage
  | ($key // (if $pr == null then null
       else usage_pr_branch($links; $edges; $pr)
         // ([$links[] | select(.kind == "merge" and .pr == $pr) | .key | strings] | last) end)) as $pr_key
  | if $pr_key == null then {pr: $pr, key: null, coverage: $coverage}
    else usage_window($links; $pr_key; $pr) as $window
      | [usage_roots($edges; $pr_key)[] | select(. != $pr_key) | {root: ., closure_set: usage_set(usage_closure($edges; .))}] as $root_closures
      | usage_pr_scope($usage_records; $cost; usage_set([$pr_key] + [$root_closures[].closure_set | to_entries[] | .key])) as $scope
      | usage_resolve_t($scope.segs; $scope.bindings; usage_intervals($scope.bindings; $scope.cost)) as $segments
      | [$segments[] | select(.rkey == $pr_key)] as $mine
      | [$mine[] | ._t as $epoch
          | select($epoch != null and ($window.from == null or $window.from < $epoch) and ($window.to == null or $epoch <= $window.to))] as $in_window
      | ([$mine[] | ._t | select(. != null)] | min) as $earliest
      | {pr: $pr, key: $pr_key, window: $window, sum: usage_sum($in_window | map(usage_priced)), coverage: $coverage,
         lower_bound: ($earliest != null and $coverage_start != null and ($earliest - $coverage_start.epoch) < 86400),
         roots: [$root_closures[] | . as $root_closure
           | {root: $root_closure.root, sum: usage_sum([$segments[] | select(usage_in($root_closure.closure_set)) | usage_priced])}]}
    end;

def usage_view_pr($pr; $key):
  usage_view_pr_of(usage_rows($usage_store); usage_rows($links_store); usage_rows($cost_store); $pr; $key; $keys);

# A node is listed when it owns resolved spend, or when an explicit edge from
# inside the closure reaches it; only the second kind is marked.
def usage_view_initiative_of($usage_records; $links; $cost; $reference; $keys):
  usage_model_base_of($usage_records; $links; $cost; $keys) as $readout_model
  | {coverage: $readout_model.coverage,
     roots: [usage_roots($readout_model.edges; $reference)[] | . as $root
       | usage_closure($readout_model.edges; $root) as $closure | usage_set($closure) as $closure_set
       | [$readout_model.segs[] | select(usage_in($closure_set)) | usage_priced] as $root_segments
       | (reduce $root_segments[] as $segment ({}; .[$segment.rkey] += [$segment])) as $segments_by_reference
       | usage_set([$readout_model.edges[] | select(.explicit and $closure_set[.parent] == true) | .child]) as $explicit_children
       | {root: $root, sum: usage_sum($root_segments),
          nodes: ([$closure[] | . as $node
            | ($segments_by_reference[$node] // []) as $owned_segments
            | ($node != $root and $explicit_children[$node] == true) as $is_explicit
            | select(($owned_segments | length) > 0 or $is_explicit)
            | {ref: $node, sum: usage_sum($owned_segments), explicit: $is_explicit}] | sort_by(.ref))}]};

def usage_view_initiative($reference):
  usage_view_initiative_of(usage_rows($usage_store); usage_rows($links_store); usage_rows($cost_store); $reference; $keys);

# "No initiative link" counts attributed spend whose key is a branch, command,
# or PR with no live parent: the lineage kinds are initiatives themselves.
def usage_view_reconcile_of($usage_records; $links; $cost; $keys):
  usage_model_of($usage_records; $links; $cost; $keys) as $readout_model
  | usage_set([$readout_model.edges[].child | strings]) as $children
  | [$readout_model.segs[] | select(usage_unattributed)] as $unattributed_segments
  | [$readout_model.segs[] | select(usage_unattributed | not)] as $attributed_segments
  | {coverage: $readout_model.coverage, attributed: usage_sum($attributed_segments), unattributed: usage_sum($unattributed_segments), all: usage_sum($readout_model.segs),
     nolink: usage_sum([$attributed_segments[] | select(.rkey | test("^(branch|command|pr):")) | .rkey as $raw_key
       | select($children[$raw_key] != true)])};

def usage_view_reconcile:
  usage_view_reconcile_of(usage_rows($usage_store); usage_rows($links_store); usage_rows($cost_store); $keys);
'

# shellcheck disable=SC2034  # consumed by usage.sh
GAIA_USAGE_VIEW_JQ="$GAIA_USAGE_PRUNE_JQ$GAIA_USAGE_VIEW_BODY_JQ"

# usage_rates_load <table-override> <main_root> [models_json]: sets USAGE_RATES
# to the distributed rate table with the local override overlaid, or null when
# none loads. A non-empty <table-override> replaces the distributed table (the
# --rate-table seam). It never touches the network, so a model absent from both
# tables prices as unpriced. The models argument is accepted and unused.
# shellcheck disable=SC2034  # USAGE_RATES is read by the caller
usage_rates_load() {
  USAGE_RATES=null
  declare -F gaia_rates_load >/dev/null 2>&1 || return 0
  gaia_rates_load "$2" "$1"
  USAGE_RATES="$GAIA_RATES_JSON"
}

# usage_models_of <keys-json>: the models list a gaia_usage_keys_json object
# carries, printed compact (nothing when it could not be listed); rc 1 when the
# object has none, so the caller lists them itself.
usage_models_of() {
  jq -r 'if has("models") then (.models | if . == null then empty else tojson end) else error("no models") end' \
    <<<"$1" 2>/dev/null
}

# usage_unflushed <projects_root> <main_root> <telemetry_dir>: "<files>\t<bytes>"
# not yet recorded, or nothing. A truncated file counts whole, since the
# flusher re-reads it from the start.
usage_unflushed() {
  gaia_usage_due_files "$1" "$2" "$3" |
    awk -F '\t' '{ file_bytes = $1 - $2; if (file_bytes < 0) file_bytes = $1; file_count++; byte_total += file_bytes } END { if (file_count) printf "%d\t%d\n", file_count, byte_total }'
}

# _usage_markers <view-json> <hooks_ok> <unflushed "n<TAB>bytes" or ""> [extra marker...]
_usage_markers() {
  local view_json="$1" hooks="$2" unflushed="$3" marker unpriced_models tab=$'\t'
  shift 3
  # The memo path loads rates in a subshell, so the status is read again here
  # from the caller's MAIN_ROOT; the flag keeps a multi-root readout to one line.
  if [ -z "${_USAGE_OVERRIDE_MARKED:-}" ] && declare -F gaia_rates_override_status >/dev/null 2>&1 &&
    [ "$(gaia_rates_override_status "${MAIN_ROOT:-}")" = unparseable ]; then
    _USAGE_OVERRIDE_MARKED=1
    printf '  ! rate override ignored (unparseable): .gaia/local/telemetry/token-rates.override.json\n'
  fi
  [ "$hooks" = 1 ] || printf '  ! capture hooks not registered\n'
  if [ -n "$unflushed" ]; then printf '  ! unflushed: %s file(s), %s bytes not yet recorded\n' "${unflushed%%"$tab"*}" "${unflushed#*"$tab"}"; fi
  for marker in "$@"; do printf '  ! %s\n' "$marker"; done
  unpriced_models="$(jq -r '[.sum // empty, .all // empty, (.roots // [])[].sum] | map(.unpriced[]) | unique | join(", ")' <<<"$view_json")"
  if [ -n "$unpriced_models" ]; then printf '  ! lower bound: unpriced model(s) %s\n' "$(_usage_safe "$unpriced_models")"; fi
}

# usage_render_pr <view-json> <hooks_ok> <unflushed> <partial 0|1> <unconfirmed 0|1> <raw branch or "">
# Tab is IFS whitespace, so `read` collapses an empty field; every field the
# view can leave empty is emitted as `-` and mapped back here.
usage_render_pr() {
  local view_json="$1" hooks="$2" unflushed="$3" partial="$4" unconfirmed="$5" raw_branch="$6" rerun_flags
  local pr key coverage_start total_tokens fresh_tokens cache_write_tokens cache_read_tokens output_tokens usd session_count span_from span_to window_from window_to lower_bound
  IFS=$'\t' read -r pr key coverage_start total_tokens fresh_tokens cache_write_tokens cache_read_tokens output_tokens usd session_count span_from span_to window_from window_to lower_bound < <(jq -r '[(.pr // "?"), (.key // "-"),
      (.coverage // "none"), (.sum.total // 0), (.sum.fresh // 0), (.sum.cw // 0), (.sum.cr // 0), (.sum.out // 0),
      (.sum.usd // "null"), (.sum.sessions // 0), (.sum.span_from // "-"), (.sum.span_to // "-"),
      (.window.from_iso // "start of record"), (.window.to_iso // "now"), (.lower_bound // false)] | @tsv' <<<"$view_json")
  [ "$key" = - ] && key=""
  local -a extra=()
  [ "$partial" = 1 ] && extra[${#extra[@]}]="partial: flush incomplete"
  if [ "$unconfirmed" = 1 ]; then
    # The hint is a runnable command read by Claude and the branch name is
    # chosen by whoever opened the PR: only a grammar-checked key or a
    # shell-inert raw name is printed, else a placeholder.
    if [[ $key =~ ^branch:(%[0-9a-f]{16}|[A-Za-z0-9._/-]{1,128})$ ]]; then rerun_flags="--key $key"
    elif [[ $raw_branch =~ ^[A-Za-z0-9._/+-]+$ && $raw_branch != -* ]]; then rerun_flags="--branch $raw_branch"
    else rerun_flags="--branch <branch>"; fi
    extra[${#extra[@]}]="merge not confirmed; boundary not recorded (record it: bash .gaia/scripts/usage.sh link --merge ${pr/\?/<N>} $rerun_flags)"
  fi
  if [ -z "$key" ]; then
    printf '[PR cost] pr:%s (branch unresolved)\n' "$(_usage_safe "$pr")"
    printf '  coverage start: %s\n' "$(_usage_safe "$coverage_start")"
    _usage_markers "$view_json" "$hooks" "$unflushed" ${extra[@]+"${extra[@]}"}
    return 0
  fi
  [ "$lower_bound" = true ] && extra[${#extra[@]}]="lower bound: branch spend may predate coverage start"
  printf '[PR cost] pr:%s %s\n' "$(_usage_safe "$pr")" "$(_usage_safe "$key")"
  if [ "$hooks" = 1 ]; then
    printf '  tokens: %s (fresh %s, cache write %s, cache read %s, output %s)\n' "$(commify "$total_tokens")" \
      "$(commify "$fresh_tokens")" "$(commify "$cache_write_tokens")" "$(commify "$cache_read_tokens")" "$(commify "$output_tokens")"
    printf '  est. cost (USD): %s\n' "$(_usage_money "$usd")"
  fi
  if [ "$span_from" != - ]; then span_to="$span_from..$span_to"; else span_to=none; fi
  printf '  sessions: %s  span: %s  coverage start: %s\n' "$session_count" "$(_usage_safe "$span_to")" "$(_usage_safe "$coverage_start")"
  printf '  window: after %s through %s\n' "$(_usage_safe "$window_from")" "$(_usage_safe "$window_to")"
  _usage_markers "$view_json" "$hooks" "$unflushed" ${extra[@]+"${extra[@]}"}
  [ "$hooks" = 1 ] || return 0
  while IFS=$'\t' read -r key total_tokens usd; do
    printf '[initiative %s to date; initiative totals overlap, never sum them across roots]\n' "$(_usage_safe "$key")"
    printf '  tokens: %s  est. cost (USD): %s\n' "$(commify "$total_tokens")" "$(_usage_money "$usd")"
  done < <(jq -r '.roots[] | [.root, .sum.total, (.sum.usd // "null")] | @tsv' <<<"$view_json")
}

usage_render_initiative() {
  local view_json="$1" hooks="$2" unflushed="$3" coverage_start root i root_count node_reference total_tokens usd explicit_marker
  coverage_start="$(jq -r '.coverage // "none"' <<<"$view_json")"
  root_count="$(jq -r '.roots | length' <<<"$view_json")"
  i=0
  while [ "$i" -lt "$root_count" ]; do
    root="$(jq -r --argjson i "$i" '.roots[$i].root' <<<"$view_json")"
    printf '[initiative %s]  coverage start: %s\n' "$(_usage_safe "$root")" "$(_usage_safe "$coverage_start")"
    if [ "$hooks" = 1 ]; then
      while IFS=$'\t' read -r node_reference total_tokens usd explicit_marker; do
        [ "$explicit_marker" = true ] && explicit_marker='  (explicit link)' || explicit_marker=''
        printf '  %s  tokens %s  est. %s%s\n' "$(_usage_safe "$node_reference")" "$(commify "$total_tokens")" "$(_usage_money "$usd")" "$explicit_marker"
      done < <(jq -r --argjson i "$i" '.roots[$i].nodes[] | [.ref, .sum.total, (.sum.usd // "null"), .explicit] | @tsv' <<<"$view_json")
      IFS=$'\t' read -r total_tokens usd < <(jq -r --argjson i "$i" '.roots[$i].sum | [.total, (.usd // "null")] | @tsv' <<<"$view_json")
      printf '  total (distinct segments): tokens %s  est. %s\n' "$(commify "$total_tokens")" "$(_usage_money "$usd")"
    fi
    printf '  note: initiative totals overlap; never sum them across roots\n'
    _usage_markers "$(jq -c --argjson i "$i" '{sum: .roots[$i].sum}' <<<"$view_json")" "$hooks" "$unflushed"
    i=$((i + 1))
  done
}

usage_render_reconcile() {
  local view_json="$1" hooks="$2" unflushed="$3" attributed_tokens attributed_usd unattributed_tokens unattributed_usd all_tokens all_usd no_link_tokens
  printf '[usage reconcile]  coverage start: %s\n' "$(_usage_safe "$(jq -r '.coverage // "none"' <<<"$view_json")")"
  if [ "$hooks" = 1 ]; then
    IFS=$'\t' read -r attributed_tokens attributed_usd unattributed_tokens unattributed_usd all_tokens all_usd no_link_tokens < <(jq -r '[.attributed.total, (.attributed.usd // "null"),
        .unattributed.total, (.unattributed.usd // "null"), .all.total, (.all.usd // "null"), .nolink.total] | @tsv' <<<"$view_json")
    printf '  attributed:   tokens %s  est. %s\n' "$(commify "$attributed_tokens")" "$(_usage_money "$attributed_usd")"
    printf '  unattributed: tokens %s  est. %s\n' "$(commify "$unattributed_tokens")" "$(_usage_money "$unattributed_usd")"
    printf '  all segments: tokens %s  est. %s\n' "$(commify "$all_tokens")" "$(_usage_money "$all_usd")"
    printf '  attributed with no initiative link: tokens %s\n' "$(commify "$no_link_tokens")"
  fi
  _usage_markers "$view_json" "$hooks" "$unflushed"
}
