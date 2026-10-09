# shellcheck shell=bash
# GAIA usage-ledger read side: binding resolution, the lineage edge set, and
# the per-readout model the renderers print from.
#
# The ledger stores raw keys only (`branch:<b>` or `session:<sid>`). Every
# attribution is decided here at read time, so a binding or a link written
# later re-attributes earlier spend without rewriting a row.
#
# Defines GAIA_USAGE_RESOLVE_JQ (jq defs) and bash helpers; no side effects at
# source time. Both jq variables expect GAIA_USAGE_JQ_DEFS (usage-lib.sh)
# ahead of them; GAIA_USAGE_MODEL_JQ follows GAIA_USAGE_RESOLVE_JQ.
#
# Two stores feed every attribution: usage.jsonl (segments and bindings) and
# links.jsonl (edges, unlinks and merges).
#
# $keys is the one object bash hands jq for everything jq must not compute:
# {"derive": {<branch key>: [<parent ref>...]}, "default": <default branch>}.
# Branch-name parsing stays in bash (branch-name-lib.sh) so jq never
# reimplements it.

# _gaia_usage_branch_parents <normalized branch> <branch ref> <scratch file>:
# appends a (ref, parent) pair to the caller's `flat` array for each parent ref
# the name implies. Runs in the caller's shell (the branch-name readers write
# to the scratch file, not a subshell), so a readout over thousands of
# distinct branches forks nothing per branch.
# `spec-<nnn>-*` and `<type>/<n>-*` are matched here rather than in
# branch-name-lib.sh because that lib reads back only the names GAIA mints,
# and both of these classify there as `adhoc unknown`. gaia_branch_spec_number
# is not used: it strips leading zeros, and a two-digit SPEC ref fails the ref
# grammar and never joins the zero-padded ref the SPEC was minted under.
_gaia_usage_branch_parents() {
  local branch_name="$1" branch_key="$2" scratch_file="$3" classification unit member parent_reference pad issue_number
  local -a parent_references=()
  _gaia_usage_capture "$scratch_file" gaia_branch_classify "$branch_name"
  # shellcheck disable=SC2154  # set by _gaia_usage_capture (usage-lib.sh)
  classification="$_gaia_usage_text"
  unit="${classification#* }"
  # gaia_branch_members prints only for a branch that classifies as a drain.
  if [ "${classification%% *}" = drain ]; then
    gaia_branch_members "$branch_name" >"$scratch_file"
    while IFS= read -r member; do
      [ -n "$member" ] && parent_references[${#parent_references[@]}]="issue:$member"
    done <"$scratch_file"
  fi
  case "$classification" in
    "plan SPEC-"*) _gaia_usage_pad3 "${unit#SPEC-}"; parent_references[${#parent_references[@]}]="spec:SPEC-$pad" ;;
    "plan plan-"*) _gaia_usage_pad3 "${unit#plan-}"; parent_references[${#parent_references[@]}]="plan:PLAN-$pad" ;;
  esac
  if [[ "$branch_name" =~ ^spec-([0-9]+)(-|$) ]]; then
    _gaia_usage_pad3 "${BASH_REMATCH[1]}"
    parent_references[${#parent_references[@]}]="spec:SPEC-$pad"
  fi
  # The alternation is the `types` list of .gaia/conventional-commits.json
  # (pinned by usage-resolve.bats). A date-shaped unit, such as the hook's
  # `wiki/2026-10-03-14-30`, is a timestamp and never an issue number.
  if [[ "$branch_name" =~ ^(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test|wiki)/([0-9]+)- ]]; then
    issue_number="${BASH_REMATCH[2]}"
    if ! [[ "$branch_name" =~ ^[^/]+/[0-9]{4}-[0-9]{2}- ]]; then
      parent_references[${#parent_references[@]}]="issue:$issue_number"
    fi
  fi
  for parent_reference in ${parent_references[@]+"${parent_references[@]}"}; do
    gaia_usage_valid_reference "$parent_reference" || continue
    flat[${#flat[@]}]="$branch_key"
    flat[${#flat[@]}]="$parent_reference"
  done
}

# Sets the caller's `pad`. Minted digits are kept; only a number shorter than
# three digits is padded. 10# because printf reads a leading zero as octal and
# rejects `08`.
_gaia_usage_pad3() {
  if [ "${#1}" -ge 3 ]; then pad="$1"; else printf -v pad '%03d' "$((10#$1))"; fi
}

# gaia_usage_derive_map <branch-ref>...: JSON object of each branch ref to the
# parent refs its name implies. A hashed ref cannot be read back and maps to
# nothing; a derived ref failing the grammar is dropped.
gaia_usage_derive_map() {
  local branch_key scratch_file
  local -a flat=()
  _gaia_usage_load gaia_branch_classify branch-name-lib.sh || return 1
  scratch_file="$(mktemp "${TMPDIR:-/tmp}/gaia-usage-derive.XXXXXX")" || return 1
  for branch_key in "$@"; do
    case "$branch_key" in branch:%*) continue ;; branch:?*) ;; *) continue ;; esac
    _gaia_usage_branch_parents "${branch_key#branch:}" "$branch_key" "$scratch_file"
  done
  rm -f "$scratch_file"
  # The pairs reach jq NUL-separated on stdin, not as --args: argv has a total
  # cap (about 2 MiB on Linux, 1 MiB on macOS) that the branch history grows
  # toward. NUL is the one byte a shell string cannot hold, so no ref can split.
  # Each value is led by a NUL and an `x` jq strips, so the input never ends in
  # NUL: jq 1.6 drops a trailing NUL from raw input, and with it an empty last
  # value. With no pairs nothing is printed, since printf would still print one.
  { [ "${#flat[@]}" -eq 0 ] || printf '\0x%s' "${flat[@]}"; } |
    jq -Rsc 'split("\u0000")[1:] | map(.[1:]) as $flat_pairs
    | reduce range(0; $flat_pairs | length; 2) as $i ({}; .[$flat_pairs[$i]] += [$flat_pairs[$i + 1]])
    | map_values(unique)'
}

# gaia_usage_keys_json <main_root> <usage> <links> [extra-ref...]: the $keys
# object for the two stores (missing files read as empty). Extra refs
# join the derivation set, so a write can check a cycle through the edges its
# own refs imply. It also carries `models`, the distinct segment models (null
# when they cannot be listed), so a readout prices from the same one pass over
# the ledger rather than parsing it again.
gaia_usage_keys_json() {
  local main_root="$1" usage_file="$2" links_file="$3" scan_json default_branch derive line
  shift 3
  local -a branch_keys=()
  [ -f "$usage_file" ] || usage_file=/dev/null
  [ -f "$links_file" ] || links_file=/dev/null
  scan_json="$(jq -n --rawfile usage_store "$usage_file" --rawfile links_store "$links_file" "$GAIA_USAGE_JQ_DEFS$GAIA_USAGE_RESOLVE_JQ"'
    [usage_rows($usage_store)[] | select(.kind == "segment")] as $segments
    | {bkeys: ([($segments[] | .key), (usage_rows($links_store)[] | .child, .parent, .key)]
         | map(strings | select(startswith("branch:"))) | unique),
       models: (try ([$segments[] | (.by_model // {}) | keys[]] | unique) catch null)}')" ||
    return 1
  while IFS= read -r line; do branch_keys[${#branch_keys[@]}]="$line"; done < <(jq -r '.bkeys[]' <<<"$scan_json")
  default_branch="$(gaia_usage_default_branch "$main_root")"
  derive="$(gaia_usage_derive_map ${branch_keys[@]+"${branch_keys[@]}"} "$@")" || return 1
  # The map reaches jq as a JSON stream on stdin, not --argjson: Linux refuses
  # any one argument over 128 KiB, a size a long branch history passes, and the
  # legacy readout would then run on empty keys and print wrong figures.
  jq -nc --arg default_branch "$default_branch" 'input as $scan | input as $derive_map
    | {derive: $derive_map, default: $default_branch, models: $scan.models}' <<<"$scan_json
$derive"
}

# gaia_usage_spec_lineage <SPEC.md>: the frontmatter spec_id on the first line,
# then each lineage: entry (flow or block list) trimmed of spaces and quotes.
# The same two list forms the SPEC lint accepts; nothing is validated here.
gaia_usage_spec_lineage() {
  local frontmatter id inline entries entry
  frontmatter="$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$1")"
  id="$(printf '%s\n' "$frontmatter" | sed -n 's/^spec_id:[[:space:]]*//p' | head -n 1)"
  inline="$(printf '%s\n' "$frontmatter" | sed -n 's/^lineage:[[:space:]]*//p' | head -n 1)"
  inline="${inline%"${inline##*[![:space:]]}"}"
  if [ -n "$inline" ]; then
    entries="${inline#\[}"
    entries="$(printf '%s' "${entries%\]}" | tr ',' '\n')"
  else
    entries="$(printf '%s\n' "$frontmatter" | awk '/^lineage:/ { in_lineage = 1; next } in_lineage && /^[A-Za-z_][A-Za-z0-9_]*:/ { in_lineage = 0 }
      in_lineage && /^[[:space:]]*-[[:space:]]/ { sub(/^[[:space:]]*-[[:space:]]+/, ""); print }')"
  fi
  while IFS= read -r entry; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    entry="${entry#[\"\']}" entry="${entry%[\"\']}"
    printf '%s\n' "$entry"
  done <<EOF_LINEAGE
$id
$entries
EOF_LINEAGE
}

# shellcheck disable=SC2034,SC2016  # consumed by sourcing scripts; jq source, no shell expansion
GAIA_USAGE_RESOLVE_JQ='
# A torn line, a non-object, or an unknown schema_version is skipped, never fatal.
def usage_rows($raw):
  $raw | split("\n") | map(select(length > 0) | (try fromjson catch null)
    | select(type == "object" and .schema_version == 1));

# Seconds since the epoch with the fraction kept, so two turns in the same
# second still order; null for anything that is not a UTC ISO stamp.
# The slow path compiles a regex per call (jq 1.7.1) and also reads the
# +00:00 offset spellings. The fast path takes the stamps the capture hooks
# write (Z, optional fraction) through one strict test and the same arithmetic,
# so every value it returns equals the slow path value.
def usage_epoch_slow:
  if type != "string" then null
  elif test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\\z") then fromdateiso8601
  else [capture("^(?<date_time>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?<fraction>\\.[0-9]+)?(Z|[+]00:?00)$")?
      | ((.date_time + "Z") | fromdateiso8601) + (if .fraction == null then 0 else ("0" + .fraction | tonumber) end)] | first
  end;

def usage_epoch:
  if type == "string"
     and test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z\\z")
  then ((.[0:19] + "Z") | fromdateiso8601) + (if length > 20 then ("0" + .[19:-1] | tonumber) else 0 end)
  else usage_epoch_slow end;

# The rows of an array grouped by session_id, input order kept, so a per-row
# lookup of the rows of one session is one index rather than a scan of every
# row (a scan per segment made the readout quadratic in ledger size). A string
# id keys "s<id>"; any other id shares bucket "o", which usage_of_session_id filters
# by ==, so the grouping never changes which rows compare equal.
def usage_by_session_id:
  reduce .[] as $row ({}; (if ($row.session_id | type) == "string" then "s" + $row.session_id else "o" end) as $bucket_key
    | .[$bucket_key] += [$row]);
def usage_of_session_id($buckets; $session_id):
  if ($session_id | type) == "string" then $buckets["s" + $session_id] // []
  else [($buckets.o // [])[] | select(.session_id == $session_id)] end;

# The interval a claimed start and its close open, keyed by the close ref; a
# ref that fails the grammar still consumes the start but opens nothing.
def usage_interval_of($start; $close):
  if ($close.ref | type) == "string" and usage_valid_reference($close.ref)
  then [{session_id: $close.session_id, t0: $start._t, t1: $close._t, key: $close.ref}] else [] end;

# One session and workflow, latest start wins:
#   1. a close carrying start_ts (a recovery, written by `usage.sh record
#      --start` right after its own start row) claims the unclaimed start at
#      that instant. Both rows then leave the candidate set, so a recovery
#      neither claims nor supersedes the start of a live run. A recovery close
#      with no such start pairs with nothing;
#   2. every other close, in time order, claims the latest remaining start at
#      or before it when that start is unclaimed. A newer start supersedes an
#      older unclaimed one, which is never claimed, and a close whose latest
#      start is already claimed pairs with nothing.
def usage_pair_group:
  ([.[] | select(.type == "start")] | sort_by(._t) | to_entries | map(.value + {_i: .key})) as $starts
  | ([.[] | select(.type == "close")] | sort_by(._t)) as $closes
  | (reduce ($closes[] | select((.start_ts | type) == "string")) as $close ({claimed: {}, out: []};
      ($close.start_ts | usage_epoch) as $start_epoch
      | .claimed as $claimed
      | ([$starts[] | select(._t == $start_epoch and ($claimed[._i | tostring] | not))] | first) as $start
      | if $start == null then . else .claimed[$start._i | tostring] = true | .out += usage_interval_of($start; $close) end)) as $recovered
  | [$starts[] | select($recovered.claimed[._i | tostring] | not)] as $remaining
  | (reduce ($closes[] | select((.start_ts | type) != "string")) as $close ({claimed: {}, out: $recovered.out};
      .claimed as $claimed
      | ([$remaining[] | select(._t <= $close._t)] | last) as $start
      | if $start == null or $claimed[$start._i | tostring] == true then .
        else .claimed[$start._i | tostring] = true | .out += usage_interval_of($start; $close) end))
  | .out;

# Start and close bindings paired into attribution intervals
# {session_id, t0, t1, key}, per session and workflow. This is the only pairing
# implementation: `usage.sh record` decides whether its candidate close pairs
# by running it over the session bindings plus that close.
def usage_intervals($bindings):
  [$bindings[] | select(.kind == "binding" and (.type == "start" or .type == "close"))
    | . + {_t: (.ts | usage_epoch)} | select(._t != null)]
  | group_by([(.session_id | tojson), (.workflow | tojson)])
  | map(usage_pair_group) | add // [];

# usage_resolve with the epoch of each segment kept as `_t`, for callers that
# order or window by it.
def usage_resolve_t($segments; $bindings; $intervals):
  ([$bindings[] | select(.kind == "binding" and (.type == "research" or .type == "declare") and usage_valid_reference(.ref))
    | . + {_t: (.ts | usage_epoch), _d: (if .type == "declare" then 1 else 0 end)} | select(._t != null)]
    | sort_by(._t, ._d) | usage_by_session_id) as $research_by_session
  | ($intervals | usage_by_session_id) as $intervals_by_session
  | def within($segment): select($segment._t != null and .t0 <= $segment._t and $segment._t < .t1);
    def session_key($segment):
      ([usage_of_session_id($intervals_by_session; $segment.session_id)[] | within($segment)] | sort_by(.t0) | last) as $interval
      | if $interval != null then $interval.key
        else usage_of_session_id($research_by_session; $segment.session_id) as $mine
          | if ($mine | length) == 0 then "session:" + ($segment.session_id // "")
            else ([$mine[] | select($segment._t != null and ._t <= $segment._t)] | last) as $binding
              | if $binding != null then $binding.ref else ($mine | map(select(._t == $mine[0]._t)) | last | .ref) end
            end
        end;
    def base_key($segment):
      if ($segment.key | type) == "string" and ($segment.key | startswith("branch:")) then
        ([usage_of_session_id($intervals_by_session; $segment.session_id)[] | within($segment) | select(.key | startswith("command:"))] | sort_by(.t0) | last) as $interval
        | if $interval != null then $interval.key else $segment.key end
      elif ($segment.key | type) == "string" and ($segment.key | startswith("session:")) then session_key($segment)
      else $segment.key end;
  ($segments | map(. + {_t: (.first_ts | usage_epoch)})
    | map(if .inherit == true then . else . + {rkey: base_key(.)} end)) as $keyed_segments
  | ([$keyed_segments[] | select(.inherit != true)] | usage_by_session_id) as $mains
  | $keyed_segments | map(if .inherit == true then
      . as $segment
      | ([usage_of_session_id($mains; $segment.session_id)[] | select(._t != null and $segment._t != null and ._t <= $segment._t)]
          | sort_by(._t) | last) as $main_segment
      | . + {rkey: (if $main_segment != null then $main_segment.rkey else session_key($segment) end)}
    else . end);

def usage_resolve($segments; $bindings; $intervals):
  usage_resolve_t($segments; $bindings; $intervals) | map(del(._t));

# Live edges: explicit rows plus the edges a branch name implies. A pair whose
# latest explicit row (file order: the ledger is append-only) is an unlink is
# dead, derived or not; an explicit edge row after that unlink revives it.
def usage_edges($links; $keys):
  ([($keys.derive // {}) | to_entries[] | .key as $child_key | .value[] | {child: $child_key, parent: ., explicit: false}]
    | map(select(usage_valid_reference(.child) and usage_valid_reference(.parent) and .child != .parent))) as $derived
  | [$links[] | select((.kind == "edge" or .kind == "unlink") and usage_valid_reference(.child) and usage_valid_reference(.parent))] as $explicit_rows
  | ($explicit_rows | reduce .[] as $row ({}; .[$row.child + " " + $row.parent] = $row.kind)) as $last
  | ([$explicit_rows[] | select($last[.child + " " + .parent] == "edge") | {child, parent, explicit: true}]
    + [$derived[] | select($last[.child + " " + .parent] == null)])
  | unique_by([.child, .parent]);

# Breadth-first from $start; the queue is the suffix of `seen` from `i`, and
# adjacency is indexed once, so a walk is linear in the edges it crosses.
def usage_walk($edges; $start; $up):
  (reduce $edges[] as $edge ({}; if $up then .[$edge.child] += [$edge.parent] else .[$edge.parent] += [$edge.child] end)) as $adjacency
  | {seen: [$start], set: {($start | tojson): true}, i: 0, ends: []}
  | until(.i >= (.seen | length);
      .seen[.i] as $node | .i += 1
      | (if ($node | type) == "string" then $adjacency[$node] // [] else [] end) as $neighbors
      | (if ($neighbors | length) == 0 then .ends += [$node] else . end)
      | reduce $neighbors[] as $neighbor (.; ($neighbor | tojson) as $neighbor_key | if .set[$neighbor_key] then . else .seen += [$neighbor] | .set[$neighbor_key] = true end));

def usage_roots($edges; $reference): usage_walk($edges; $reference; true) | if (.ends | length) == 0 then [$reference] else .ends | unique end;
def usage_closure($edges; $root): usage_walk($edges; $root; false) | .seen;

# The chain from $from up to $to following child-to-parent edges, or null.
def usage_path($edges; $from; $to):
  {q: [[$from]], seen: [$from], found: null}
  | until((.q | length) == 0 or .found != null;
      .q[0] as $walk_path | .q |= .[1:] | ($walk_path | last) as $node
      | if $node == $to then .found = $walk_path
        else reduce ([$edges[] | select(.child == $node) | .parent][]) as $parent_node (.;
          if any(.seen[]; . == $parent_node) then . else .seen += [$parent_node] | .q += [$walk_path + [$parent_node]] end) end)
  | .found;

def usage_window($links; $key; $pr):
  [$links[] | select(.kind == "merge") | . + {_t: (.merged_at | usage_epoch)} | select(._t != null)] as $merges
  | (if $pr == null then null else ([$merges[] | select(.pr == $pr)] | last) end) as $mine
  | (if $mine == null then null else $mine._t end) as $to
  | ([$merges[] | select(.key == $key and ($to == null or ._t < $to))] | max_by(._t)) as $previous
  | {from: (if $previous == null then null else $previous._t end), to: $to,
     from_iso: (if $previous == null then null else $previous.merged_at end),
     to_iso: (if $mine == null then null else $mine.merged_at end)};

# The branch parent of the latest live pr:<N> edge row, or null.
def usage_pr_branch($links; $edges; $pr):
  ("pr:" + ($pr | tostring)) as $child
  | [$links[] | select(.kind == "edge" and .child == $child and (.parent | type) == "string" and (.parent | startswith("branch:")))
      | .parent as $parent | select(any($edges[]; .child == $child and .parent == $parent)) | $parent] | last;

'

# Needs the globals $usage_store, $links_store (raw store text), $keys, and $rates (null when
# no rate table loaded), plus GAIA_PRICING_JQ_DEFS ahead of it.
# shellcheck disable=SC2034,SC2016  # consumed by sourcing scripts; jq source, no shell expansion
GAIA_USAGE_MODEL_JQ='
def usage_tokens:
  [(.by_model // {}) | to_entries[] | .value | select(type == "object")] as $buckets
  | {fresh: ([$buckets[] | .fresh_input // 0] | add // 0),
     cw: ([$buckets[] | (.cache_write_5m // 0) + (.cache_write_1h // 0)] | add // 0),
     cr: ([$buckets[] | .cache_read // 0] | add // 0),
     out: ([$buckets[] | .output // 0] | add // 0)}
  | .total = .fresh + .cw + .cr + .out;

def usage_sum($segments):
  {fresh: ([$segments[].tok.fresh] | add // 0), cw: ([$segments[].tok.cw] | add // 0),
   cr: ([$segments[].tok.cr] | add // 0), out: ([$segments[].tok.out] | add // 0),
   total: ([$segments[].tok.total] | add // 0),
   usd: (if $rates == null then null else ([$segments[].usd] | add // 0) end),
   unpriced: ([$segments[].unpriced[]] | unique),
   sessions: ([$segments[].session_id] | unique | length),
   span_from: ([$segments[].first_ts | strings] | min | if . == null then null else .[0:10] end),
   span_to: ([$segments[] | (.last_ts // .first_ts) | strings] | max | if . == null then null else .[0:10] end)};

def usage_priced:
  . + {tok: usage_tokens}
  + (if $rates == null then {usd: null, unpriced: []}
     else priced_row({ts: .first_ts, by_model: (.by_model // {})}) | {usd: .dollars, unpriced} end);

# Everything a readout needs: resolved segments (each with its epoch as `_t`),
# the live edges, the links, and the coverage start (earliest first_ts over
# every segment). The `_of` forms read rows and keys only through their
# parameters: jq binds a $name in a def body where the def is written, so a
# def that names the global $keys can never be handed another object.
# usage_model_base_of leaves the segments unpriced so a view that sums a few of
# them prices only those; usage_model_of prices every one.
def usage_model_base_of($usage_records; $links; $keys):
  [$usage_records[] | select(.kind == "binding")] as $bindings
  | usage_resolve_t([$usage_records[] | select(.kind == "segment")]; $bindings; usage_intervals($bindings)) as $segments
  | ([$segments[] | {epoch: ._t, iso: .first_ts} | select(.epoch != null)] | min_by(.epoch)) as $coverage_start
  | {segs: $segments, links: $links, edges: usage_edges($links; $keys),
     coverage: (if $coverage_start == null then null else $coverage_start.iso[0:10] end),
     coverage_t: (if $coverage_start == null then null else $coverage_start.epoch end)};

def usage_model_of($usage_records; $links; $keys):
  usage_model_base_of($usage_records; $links; $keys) | .segs |= map(usage_priced);

def usage_model_base: usage_model_base_of(usage_rows($usage_store); usage_rows($links_store); $keys);

def usage_model: usage_model_of(usage_rows($usage_store); usage_rows($links_store); $keys);
'
