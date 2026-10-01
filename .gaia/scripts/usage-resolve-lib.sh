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
# $keys is the one object bash hands jq for everything jq must not compute:
# {"derive": {<branch key>: [<parent ref>...]}, "bmap": <gaia_usage_branch_map
# of every cost-row git_branch>, "default": <default branch>}. Branch-name
# parsing stays in bash (branch-name-lib.sh) so jq never reimplements it.

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
  local b="$1" k="$2" f="$3" cls unit m pad
  local -a ps=()
  _gaia_usage_capture "$f" gaia_branch_classify "$b"
  # shellcheck disable=SC2154  # set by _gaia_usage_capture (usage-lib.sh)
  cls="$_gaia_usage_text"
  unit="${cls#* }"
  # gaia_branch_members prints only for a branch that classifies as a drain.
  if [ "${cls%% *}" = drain ]; then
    gaia_branch_members "$b" >"$f"
    while IFS= read -r m; do
      [ -n "$m" ] && ps[${#ps[@]}]="issue:$m"
    done <"$f"
  fi
  case "$cls" in
    "plan SPEC-"*) _gaia_usage_pad3 "${unit#SPEC-}"; ps[${#ps[@]}]="spec:SPEC-$pad" ;;
    "plan plan-"*) _gaia_usage_pad3 "${unit#plan-}"; ps[${#ps[@]}]="plan:PLAN-$pad" ;;
  esac
  if [[ "$b" =~ ^spec-([0-9]+)(-|$) ]]; then
    _gaia_usage_pad3 "${BASH_REMATCH[1]}"
    ps[${#ps[@]}]="spec:SPEC-$pad"
  fi
  if [[ "$b" =~ ^(fix|feat|chore|docs|refactor)/([0-9]+)- ]]; then
    ps[${#ps[@]}]="issue:${BASH_REMATCH[2]}"
  fi
  for m in ${ps[@]+"${ps[@]}"}; do
    gaia_usage_valid_ref "$m" || continue
    flat[${#flat[@]}]="$k"
    flat[${#flat[@]}]="$m"
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
  local k f
  local -a flat=()
  _gaia_usage_load gaia_branch_classify branch-name-lib.sh || return 1
  f="$(mktemp "${TMPDIR:-/tmp}/gaia-usage-derive.XXXXXX")" || return 1
  for k in "$@"; do
    case "$k" in branch:%*) continue ;; branch:?*) ;; *) continue ;; esac
    _gaia_usage_branch_parents "${k#branch:}" "$k" "$f"
  done
  rm -f "$f"
  # The pairs reach jq NUL-separated on stdin, not as --args: argv has a total
  # cap (about 2 MiB on Linux, 1 MiB on macOS) that the branch history grows
  # toward. NUL is the one byte a shell string cannot hold, so no ref can split.
  # Each value is led by a NUL and an `x` jq strips, so the input never ends in
  # NUL: jq 1.6 drops a trailing NUL from raw input, and with it an empty last
  # value. With no pairs nothing is printed, since printf would still print one.
  { [ "${#flat[@]}" -eq 0 ] || printf '\0x%s' "${flat[@]}"; } |
    jq -Rsc 'split("\u0000")[1:] | map(.[1:]) as $p
    | reduce range(0; $p | length; 2) as $i ({}; .[$p[$i]] += [$p[$i + 1]])
    | map_values(unique)'
}

# gaia_usage_keys_json <main_root> <usage> <links> <cost> [extra-ref...]: the
# $keys object for the three stores (missing files read as empty). Extra refs
# join the derivation set, so a write can check a cycle through the edges its
# own refs imply. It also carries `models`, the distinct segment models (null
# when they cannot be listed), so a readout prices from the same one pass over
# the ledger rather than parsing it again.
gaia_usage_keys_json() {
  local main="$1" u="$2" l="$3" c="$4" scan def bmap derive line
  shift 4
  local -a raws=() bkeys=()
  [ -f "$u" ] || u=/dev/null
  [ -f "$l" ] || l=/dev/null
  [ -f "$c" ] || c=/dev/null
  scan="$(jq -n --rawfile u "$u" --rawfile l "$l" --rawfile c "$c" "$GAIA_USAGE_JQ_DEFS$GAIA_USAGE_RESOLVE_JQ"'
    [usage_rows($u)[] | select(.kind == "segment")] as $segs
    | {raws: ([usage_rows($c)[] | select(.kind == "plan" or .kind == "execute") | .git_branch | strings] | unique),
       bkeys: ([($segs[] | .key), (usage_rows($l)[] | .child, .parent, .key)]
         | map(strings | select(startswith("branch:"))) | unique),
       models: (try ([$segs[] | (.by_model // {}) | keys[]] | unique) catch null)}')" ||
    return 1
  while IFS= read -r line; do raws[${#raws[@]}]="$line"; done < <(jq -r '.raws[]' <<<"$scan")
  while IFS= read -r line; do bkeys[${#bkeys[@]}]="$line"; done < <(jq -r '.bkeys[]' <<<"$scan")
  def="$(gaia_usage_default_branch "$main")"
  bmap="$(gaia_usage_branch_map ${raws[@]+"${raws[@]}"})" || return 1
  while IFS= read -r line; do bkeys[${#bkeys[@]}]="$line"; done < <(jq -r '.[].key | strings' <<<"$bmap")
  derive="$(gaia_usage_derive_map ${bkeys[@]+"${bkeys[@]}"} "$@")" || return 1
  # The maps reach jq as a JSON stream on stdin, not --argjson: Linux refuses
  # any one argument over 128 KiB, a size a long branch history passes, and the
  # legacy readout would then run on empty keys and print wrong figures.
  jq -nc --arg def "$def" 'input as $s | input as $d | input as $b
    | {derive: $d, bmap: $b, default: $def, models: $s.models}' <<<"$scan
$derive
$bmap"
}

# gaia_usage_spec_lineage <SPEC.md>: the frontmatter spec_id on the first line,
# then each lineage: entry (flow or block list) trimmed of spaces and quotes.
# The same two list forms the SPEC lint accepts; nothing is validated here.
gaia_usage_spec_lineage() {
  local fm id inline entries e
  fm="$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$1")"
  id="$(printf '%s\n' "$fm" | sed -n 's/^spec_id:[[:space:]]*//p' | head -n 1)"
  inline="$(printf '%s\n' "$fm" | sed -n 's/^lineage:[[:space:]]*//p' | head -n 1)"
  inline="${inline%"${inline##*[![:space:]]}"}"
  if [ -n "$inline" ]; then
    entries="${inline#\[}"
    entries="$(printf '%s' "${entries%\]}" | tr ',' '\n')"
  else
    entries="$(printf '%s\n' "$fm" | awk '/^lineage:/ { c = 1; next } c && /^[A-Za-z_][A-Za-z0-9_]*:/ { c = 0 }
      c && /^[[:space:]]*-[[:space:]]/ { sub(/^[[:space:]]*-[[:space:]]+/, ""); print }')"
  fi
  while IFS= read -r e; do
    e="${e#"${e%%[![:space:]]*}"}"
    e="${e%"${e##*[![:space:]]}"}"
    e="${e#[\"\']}" e="${e%[\"\']}"
    printf '%s\n' "$e"
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
  else [capture("^(?<b>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?<f>\\.[0-9]+)?(Z|[+]00:?00)$")?
      | ((.b + "Z") | fromdateiso8601) + (if .f == null then 0 else ("0" + .f | tonumber) end)] | first
  end;

def usage_epoch:
  if type == "string"
     and test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z\\z")
  then ((.[0:19] + "Z") | fromdateiso8601) + (if length > 20 then ("0" + .[19:-1] | tonumber) else 0 end)
  else usage_epoch_slow end;

def usage_row_key($r):
  (if ($r.spec_id | type) == "string" and $r.spec_id != "" then "spec:" + ($r.spec_id | ascii_upcase)
   elif ($r.plan_id | type) == "string" and $r.plan_id != "" then "plan:" + ($r.plan_id | ascii_upcase)
   elif $r.kind == "command" and ($r.run_id | type) == "string" then "command:" + $r.run_id
   else null end)
  | if . != null and usage_valid_ref(.) then . else null end;

def usage_closes($w):
  if $w == "gaia-spec" then .kind == "spec"
  elif $w == "gaia-plan" then .kind == "plan"
  else .kind == "command" and .command == $w end;

# The rows of an array grouped by session_id, input order kept, so a per-row
# lookup of the rows of one session is one index rather than a scan of every
# row (a scan per segment made the readout quadratic in ledger size). A string
# id keys "s<id>"; any other id shares bucket "o", which usage_of_sid filters
# by ==, so the grouping never changes which rows compare equal.
def usage_by_sid:
  reduce .[] as $x ({}; (if ($x.session_id | type) == "string" then "s" + $x.session_id else "o" end) as $k
    | .[$k] += [$x]);
def usage_of_sid($idx; $sid):
  if ($sid | type) == "string" then $idx["s" + $sid] // []
  else [($idx.o // [])[] | select(.session_id == $sid)] end;

# Starts are taken in time order and each claims the earliest unclaimed
# matching row, so two runs of one workflow in a session never share a row.
def usage_intervals($bindings; $costrows):
  ($costrows | to_entries | map(.value + {_i: .key, _t: (.value.ts | usage_epoch)}) | map(select(._t != null))
    | usage_by_sid) as $rows
  | [$bindings[] | select(.kind == "binding" and .type == "start") | . + {_t: (.ts | usage_epoch)} | select(._t != null)]
  | sort_by(._t)
  | reduce .[] as $b ({claimed: {}, out: []};
      . as $st
      | ([usage_of_sid($rows; $b.session_id)[] | select(._t >= $b._t
            and ($st.claimed[._i | tostring] | not) and usage_closes($b.workflow))] | sort_by(._t, ._i) | first) as $r
      | if $r == null then .
        else .claimed[$r._i | tostring] = true
          | usage_row_key($r) as $k
          | if $k == null then . else .out += [{session_id: $b.session_id, t0: $b._t, t1: $r._t, key: $k}] end
        end)
  | .out;

# usage_resolve with the epoch of each segment kept as `_t`, for callers that
# order or window by it.
def usage_resolve_t($segments; $bindings; $intervals):
  ([$bindings[] | select(.kind == "binding" and (.type == "research" or .type == "declare") and usage_valid_ref(.ref))
    | . + {_t: (.ts | usage_epoch), _d: (if .type == "declare" then 1 else 0 end)} | select(._t != null)]
    | sort_by(._t, ._d) | usage_by_sid) as $rbi
  | ($intervals | usage_by_sid) as $ivi
  | def within($s): select($s._t != null and .t0 <= $s._t and $s._t <= .t1);
    def session_key($s):
      ([usage_of_sid($ivi; $s.session_id)[] | within($s)] | sort_by(.t0) | last) as $iv
      | if $iv != null then $iv.key
        else usage_of_sid($rbi; $s.session_id) as $mine
          | if ($mine | length) == 0 then "session:" + ($s.session_id // "")
            else ([$mine[] | select($s._t != null and ._t <= $s._t)] | last) as $b
              | if $b != null then $b.ref else ($mine | map(select(._t == $mine[0]._t)) | last | .ref) end
            end
        end;
    def base_key($s):
      if ($s.key | type) == "string" and ($s.key | startswith("branch:")) then
        ([usage_of_sid($ivi; $s.session_id)[] | within($s) | select(.key | startswith("command:"))] | sort_by(.t0) | last) as $iv
        | if $iv != null then $iv.key else $s.key end
      elif ($s.key | type) == "string" and ($s.key | startswith("session:")) then session_key($s)
      else $s.key end;
  ($segments | map(. + {_t: (.first_ts | usage_epoch)})
    | map(if .inherit == true then . else . + {rkey: base_key(.)} end)) as $p1
  | ([$p1[] | select(.inherit != true)] | usage_by_sid) as $mains
  | $p1 | map(if .inherit == true then
      . as $s
      | ([usage_of_sid($mains; $s.session_id)[] | select(._t != null and $s._t != null and ._t <= $s._t)]
          | sort_by(._t) | last) as $m
      | . + {rkey: (if $m != null then $m.rkey else session_key($s) end)}
    else . end);

def usage_resolve($segments; $bindings; $intervals):
  usage_resolve_t($segments; $bindings; $intervals) | map(del(._t));

# Live edges: explicit rows plus derived ones. A pair whose latest explicit
# row (file order: the ledger is append-only) is an unlink is dead, derived or
# not; an explicit edge row after that unlink revives it.
def usage_edges($links; $costrows; $keys):
  ($keys.bmap // {}) as $bm | ($keys.default // "main") as $def
  | ([($keys.derive // {}) | to_entries[] | .key as $ch | .value[] | {child: $ch, parent: ., explicit: false}]
    + [$costrows[] | select(.kind == "plan" or .kind == "execute")
        | usage_row_key(.) as $p | select($p != null and ($p | startswith("command:") | not))
        | ($bm[.git_branch // ""] // {}) as $m | ($m.norm // "") as $n
        | select($n != "" and $n != "HEAD" and $n != $def and $m.key != null)
        | {child: $m.key, parent: $p, explicit: false}]
    + [$costrows[] | select(.kind == "command" and (.github | type) == "object" and .github.type == "pr" and (.run_id | type) == "string")
        | {child: ("pr:" + (.github.number | tostring)), parent: ("command:" + .run_id), explicit: false}]
    | map(select(usage_valid_ref(.child) and usage_valid_ref(.parent) and .child != .parent))) as $derived
  | [$links[] | select((.kind == "edge" or .kind == "unlink") and usage_valid_ref(.child) and usage_valid_ref(.parent))] as $ex
  | ($ex | reduce .[] as $r ({}; .[$r.child + " " + $r.parent] = $r.kind)) as $last
  | ([$ex[] | select($last[.child + " " + .parent] == "edge") | {child, parent, explicit: true}]
    + [$derived[] | select($last[.child + " " + .parent] == null)])
  | unique_by([.child, .parent]);

# Breadth-first from $start; the queue is the suffix of `seen` from `i`, and
# adjacency is indexed once, so a walk is linear in the edges it crosses.
def usage_walk($edges; $start; $up):
  (reduce $edges[] as $e ({}; if $up then .[$e.child] += [$e.parent] else .[$e.parent] += [$e.child] end)) as $adj
  | {seen: [$start], set: {($start | tojson): true}, i: 0, ends: []}
  | until(.i >= (.seen | length);
      .seen[.i] as $n | .i += 1
      | (if ($n | type) == "string" then $adj[$n] // [] else [] end) as $next
      | (if ($next | length) == 0 then .ends += [$n] else . end)
      | reduce $next[] as $x (.; ($x | tojson) as $j | if .set[$j] then . else .seen += [$x] | .set[$j] = true end));

def usage_roots($edges; $ref): usage_walk($edges; $ref; true) | if (.ends | length) == 0 then [$ref] else .ends | unique end;
def usage_closure($edges; $root): usage_walk($edges; $root; false) | .seen;

# The chain from $from up to $to following child-to-parent edges, or null.
def usage_path($edges; $from; $to):
  {q: [[$from]], seen: [$from], found: null}
  | until((.q | length) == 0 or .found != null;
      .q[0] as $p | .q |= .[1:] | ($p | last) as $n
      | if $n == $to then .found = $p
        else reduce ([$edges[] | select(.child == $n) | .parent][]) as $x (.;
          if any(.seen[]; . == $x) then . else .seen += [$x] | .q += [$p + [$x]] end) end)
  | .found;

def usage_window($links; $key; $pr):
  [$links[] | select(.kind == "merge") | . + {_t: (.merged_at | usage_epoch)} | select(._t != null)] as $m
  | (if $pr == null then null else ([$m[] | select(.pr == $pr)] | last) end) as $mine
  | (if $mine == null then null else $mine._t end) as $to
  | ([$m[] | select(.key == $key and ($to == null or ._t < $to))] | max_by(._t)) as $prev
  | {from: (if $prev == null then null else $prev._t end), to: $to,
     from_iso: (if $prev == null then null else $prev.merged_at end),
     to_iso: (if $mine == null then null else $mine.merged_at end)};

# The branch parent of the latest live pr:<N> edge row, or null.
def usage_pr_branch($links; $edges; $pr):
  ("pr:" + ($pr | tostring)) as $c
  | [$links[] | select(.kind == "edge" and .child == $c and (.parent | type) == "string" and (.parent | startswith("branch:")))
      | .parent as $p | select(any($edges[]; .child == $c and .parent == $p)) | $p] | last;

'

# Needs the globals $u, $l, $c (raw store text), $keys, and $rates (null when
# no rate table loaded), plus GAIA_PRICING_JQ_DEFS ahead of it.
# shellcheck disable=SC2034,SC2016  # consumed by sourcing scripts; jq source, no shell expansion
GAIA_USAGE_MODEL_JQ='
def usage_tok:
  [(.by_model // {}) | to_entries[] | .value | select(type == "object")] as $v
  | {fresh: ([$v[] | .fresh_input // 0] | add // 0),
     cw: ([$v[] | (.cache_write_5m // 0) + (.cache_write_1h // 0)] | add // 0),
     cr: ([$v[] | .cache_read // 0] | add // 0),
     out: ([$v[] | .output // 0] | add // 0)}
  | .total = .fresh + .cw + .cr + .out;

def usage_sum($ss):
  {fresh: ([$ss[].tok.fresh] | add // 0), cw: ([$ss[].tok.cw] | add // 0),
   cr: ([$ss[].tok.cr] | add // 0), out: ([$ss[].tok.out] | add // 0),
   total: ([$ss[].tok.total] | add // 0),
   usd: (if $rates == null then null else ([$ss[].usd] | add // 0) end),
   unpriced: ([$ss[].unpriced[]] | unique),
   sessions: ([$ss[].session_id] | unique | length),
   span_from: ([$ss[].first_ts | strings] | min | if . == null then null else .[0:10] end),
   span_to: ([$ss[] | (.last_ts // .first_ts) | strings] | max | if . == null then null else .[0:10] end)};

def usage_priced:
  . + {tok: usage_tok}
  + (if $rates == null then {usd: null, unpriced: []}
     else priced_row({ts: .first_ts, by_model: (.by_model // {})}) | {usd: .dollars, unpriced} end);

# Everything a readout needs: resolved segments (each with its epoch as `_t`),
# the live edges, the links, and the coverage start (earliest first_ts over
# every segment). The `_of` forms read rows and keys only through their
# parameters: jq binds a $name in a def body where the def is written, so a
# def that names the global $keys can never be handed another object.
# usage_model_base_of leaves the segments unpriced so a view that sums a few of
# them prices only those; usage_model_of prices every one.
def usage_model_base_of($urows; $links; $cost; $keys):
  [$urows[] | select(.kind == "binding")] as $bindings
  | usage_resolve_t([$urows[] | select(.kind == "segment")]; $bindings; usage_intervals($bindings; $cost)) as $segs
  | ([$segs[] | {t: ._t, iso: .first_ts} | select(.t != null)] | min_by(.t)) as $cov
  | {segs: $segs, links: $links, edges: usage_edges($links; $cost; $keys),
     coverage: (if $cov == null then null else $cov.iso[0:10] end),
     coverage_t: (if $cov == null then null else $cov.t end)};

def usage_model_of($urows; $links; $cost; $keys):
  usage_model_base_of($urows; $links; $cost; $keys) | .segs |= map(usage_priced);

def usage_model_base: usage_model_base_of(usage_rows($u); usage_rows($l); usage_rows($c); $keys);

def usage_model: usage_model_of(usage_rows($u); usage_rows($l); usage_rows($c); $keys);
'
