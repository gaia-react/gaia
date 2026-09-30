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
  local n="$1" out=""
  case "$n" in '' | *[!0-9]*) printf '%s' "$n"; return 0 ;; esac
  while [ "${#n}" -gt 3 ]; do
    out=",${n:${#n}-3}${out}"
    n="${n:0:${#n}-3}"
  done
  printf '%s%s' "$n" "$out"
}

_usage_money() {
  if [ -z "$1" ] || [ "$1" = null ]; then printf 'unavailable (rate table unreadable)'; return 0; fi
  LC_ALL=C printf '$%.2f' "$1" 2>/dev/null || printf 'unavailable'
}

# shellcheck disable=SC2034,SC2016  # consumed by usage.sh; jq source, no shell expansion
GAIA_USAGE_VIEW_JQ='
def usage_unattributed: (.rkey | type) != "string" or (.rkey | startswith("session:"));
# $cs is usage_set of a closure: a lookup per segment, not a scan of the closure.
def usage_set($refs): reduce $refs[] as $r ({}; .[$r] = true);
def usage_in($cs): (.rkey | type) == "string" and $cs[.rkey] == true;

def usage_view_pr($pr; $key):
  usage_model_base as $m
  | ($key // (if $pr == null then null
       else usage_pr_branch($m.links; $m.edges; $pr)
         // ([$m.links[] | select(.kind == "merge" and .pr == $pr) | .key | strings] | last) end)) as $k
  | if $k == null then {pr: $pr, key: null, coverage: $m.coverage}
    else usage_window($m.links; $k; $pr) as $w
      | [$m.segs[] | select(.rkey == $k)] as $mine
      | [$mine[] | ._t as $t
          | select($t != null and ($w.from == null or $w.from < $t) and ($w.to == null or $t <= $w.to))] as $in
      | ([$mine[] | ._t | select(. != null)] | min) as $earliest
      | {pr: $pr, key: $k, window: $w, sum: usage_sum($in | map(usage_priced)), coverage: $m.coverage,
         lower_bound: ($earliest != null and $m.coverage_t != null and ($earliest - $m.coverage_t) < 86400),
         roots: [usage_roots($m.edges; $k)[] | select(. != $k) | . as $r
           | usage_set(usage_closure($m.edges; $r)) as $cs
           | {root: $r, sum: usage_sum([$m.segs[] | select(usage_in($cs)) | usage_priced])}]}
    end;

# A node is listed when it owns resolved spend, or when an explicit edge from
# inside the closure reaches it; only the second kind is marked.
def usage_view_initiative($ref):
  usage_model as $m
  | {coverage: $m.coverage,
     roots: [usage_roots($m.edges; $ref)[] | . as $r
       | usage_closure($m.edges; $r) as $cl | usage_set($cl) as $cs
       | [$m.segs[] | select(usage_in($cs))] as $ss
       | {root: $r, sum: usage_sum($ss),
          nodes: ([$cl[] | . as $n
            | [$ss[] | select(.rkey == $n)] as $own
            | ($n != $r and any($m.edges[]; .explicit and .child == $n and (.parent as $p | any($cl[]; . == $p))))
              as $ex
            | select(($own | length) > 0 or $ex)
            | {ref: $n, sum: usage_sum($own), explicit: $ex}] | sort_by(.ref))}]};

# "No initiative link" counts attributed spend whose key is a branch, command,
# or PR with no live parent: the lineage kinds are initiatives themselves.
def usage_view_reconcile:
  usage_model as $m
  | [$m.segs[] | select(usage_unattributed)] as $un
  | [$m.segs[] | select(usage_unattributed | not)] as $at
  | {coverage: $m.coverage, attributed: usage_sum($at), unattributed: usage_sum($un), all: usage_sum($m.segs),
     nolink: usage_sum([$at[] | select(.rkey | test("^(branch|command|pr):")) | .rkey as $k
       | select(any($m.edges[]; .child == $k) | not)])};
'

# usage_rates_load <override> <main_root> <models_json>: sets USAGE_RATES to the
# rate table JSON, or null when none loads. Call it in the caller's own shell,
# never in $(...): gaia_rates_prepare keeps per-process state a subshell
# discards. An override skips seed, sync, and heal, as in token-rollup.sh.
# shellcheck disable=SC2034  # USAGE_RATES is read by the caller
usage_rates_load() {
  local table=""
  USAGE_RATES=null
  if declare -F gaia_rates_prepare >/dev/null 2>&1; then
    if gaia_rates_prepare "$1" "$2"; then table="$GAIA_RATES_TABLE"; fi
  elif declare -F gaia_resolve_rate_table >/dev/null 2>&1; then
    table="$(gaia_resolve_rate_table "$1")" || table=""
  fi
  [ -n "$table" ] || return 0
  USAGE_RATES="$(gaia_load_rate_table "$table")" || { USAGE_RATES=null; return 0; }
  if declare -F gaia_rates_heal >/dev/null 2>&1 && gaia_rates_heal "$3"; then
    USAGE_RATES="$(gaia_load_rate_table "$GAIA_RATES_TABLE")" || USAGE_RATES=null
  fi
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
    awk -F '\t' '{ d = $1 - $2; if (d < 0) d = $1; n++; b += d } END { if (n) printf "%d\t%d\n", n, b }'
}

# _usage_markers <view-json> <hooks_ok> <unflushed "n<TAB>bytes" or ""> [extra marker...]
_usage_markers() {
  local v="$1" hooks="$2" unf="$3" m unp tab=$'\t'
  shift 3
  [ "$hooks" = 1 ] || printf '  ! capture hooks not registered\n'
  if [ -n "$unf" ]; then printf '  ! unflushed: %s file(s), %s bytes not yet recorded\n' "${unf%%"$tab"*}" "${unf#*"$tab"}"; fi
  for m in "$@"; do printf '  ! %s\n' "$m"; done
  unp="$(jq -r '[.sum // empty, .all // empty, (.roots // [])[].sum] | map(.unpriced[]) | unique | join(", ")' <<<"$v")"
  if [ -n "$unp" ]; then printf '  ! lower bound: unpriced model(s) %s\n' "$unp"; fi
}

# usage_render_pr <view-json> <hooks_ok> <unflushed> <partial 0|1> <unconfirmed 0|1> <raw branch or "">
# Tab is IFS whitespace, so `read` collapses an empty field; every field the
# view can leave empty is emitted as `-` and mapped back here.
usage_render_pr() {
  local v="$1" hooks="$2" unf="$3" partial="$4" unconf="$5" rawb="$6" f
  local pr key cov tot fr cw cr out usd sess sf st wf wt lb
  IFS=$'\t' read -r pr key cov tot fr cw cr out usd sess sf st wf wt lb < <(jq -r '[(.pr // "?"), (.key // "-"),
      (.coverage // "none"), (.sum.total // 0), (.sum.fresh // 0), (.sum.cw // 0), (.sum.cr // 0), (.sum.out // 0),
      (.sum.usd // "null"), (.sum.sessions // 0), (.sum.span_from // "-"), (.sum.span_to // "-"),
      (.window.from_iso // "start of record"), (.window.to_iso // "now"), (.lower_bound // false)] | @tsv' <<<"$v")
  [ "$key" = - ] && key=""
  local -a extra=()
  [ "$partial" = 1 ] && extra[${#extra[@]}]="partial: flush incomplete"
  if [ "$unconf" = 1 ]; then
    if [ -n "$rawb" ]; then f="--branch $rawb"; elif [ -n "$key" ]; then f="--key $key"; else f="--branch <branch>"; fi
    extra[${#extra[@]}]="merge not confirmed; boundary not recorded (record it: bash .gaia/scripts/usage.sh link --merge ${pr/\?/<N>} $f)"
  fi
  if [ -z "$key" ]; then
    printf '[PR cost] pr:%s (branch unresolved)\n' "$pr"
    printf '  coverage start: %s\n' "$cov"
    _usage_markers "$v" "$hooks" "$unf" ${extra[@]+"${extra[@]}"}
    return 0
  fi
  [ "$lb" = true ] && extra[${#extra[@]}]="lower bound: branch spend may predate coverage start"
  printf '[PR cost] pr:%s %s\n' "$pr" "$key"
  if [ "$hooks" = 1 ]; then
    printf '  tokens: %s (fresh %s, cache write %s, cache read %s, output %s)\n' "$(commify "$tot")" \
      "$(commify "$fr")" "$(commify "$cw")" "$(commify "$cr")" "$(commify "$out")"
    printf '  est. cost (USD): %s\n' "$(_usage_money "$usd")"
  fi
  if [ "$sf" != - ]; then st="$sf..$st"; else st=none; fi
  printf '  sessions: %s  span: %s  coverage start: %s\n' "$sess" "$st" "$cov"
  printf '  window: after %s through %s\n' "$wf" "$wt"
  _usage_markers "$v" "$hooks" "$unf" ${extra[@]+"${extra[@]}"}
  [ "$hooks" = 1 ] || return 0
  while IFS=$'\t' read -r key tot usd; do
    printf '[initiative %s to date; initiative totals overlap, never sum them across roots]\n' "$key"
    printf '  tokens: %s  est. cost (USD): %s\n' "$(commify "$tot")" "$(_usage_money "$usd")"
  done < <(jq -r '.roots[] | [.root, .sum.total, (.sum.usd // "null")] | @tsv' <<<"$v")
}

usage_render_initiative() {
  local v="$1" hooks="$2" unf="$3" cov root i n ref tot usd ex
  cov="$(jq -r '.coverage // "none"' <<<"$v")"
  n="$(jq -r '.roots | length' <<<"$v")"
  i=0
  while [ "$i" -lt "$n" ]; do
    root="$(jq -r --argjson i "$i" '.roots[$i].root' <<<"$v")"
    printf '[initiative %s]  coverage start: %s\n' "$root" "$cov"
    if [ "$hooks" = 1 ]; then
      while IFS=$'\t' read -r ref tot usd ex; do
        [ "$ex" = true ] && ex='  (explicit link)' || ex=''
        printf '  %s  tokens %s  est. %s%s\n' "$ref" "$(commify "$tot")" "$(_usage_money "$usd")" "$ex"
      done < <(jq -r --argjson i "$i" '.roots[$i].nodes[] | [.ref, .sum.total, (.sum.usd // "null"), .explicit] | @tsv' <<<"$v")
      IFS=$'\t' read -r tot usd < <(jq -r --argjson i "$i" '.roots[$i].sum | [.total, (.usd // "null")] | @tsv' <<<"$v")
      printf '  total (distinct segments): tokens %s  est. %s\n' "$(commify "$tot")" "$(_usage_money "$usd")"
    fi
    printf '  note: initiative totals overlap; never sum them across roots\n'
    _usage_markers "$(jq -c --argjson i "$i" '{sum: .roots[$i].sum}' <<<"$v")" "$hooks" "$unf"
    i=$((i + 1))
  done
}

usage_render_reconcile() {
  local v="$1" hooks="$2" unf="$3" at atu un unu al alu nl
  printf '[usage reconcile]  coverage start: %s\n' "$(jq -r '.coverage // "none"' <<<"$v")"
  if [ "$hooks" = 1 ]; then
    IFS=$'\t' read -r at atu un unu al alu nl < <(jq -r '[.attributed.total, (.attributed.usd // "null"),
        .unattributed.total, (.unattributed.usd // "null"), .all.total, (.all.usd // "null"), .nolink.total] | @tsv' <<<"$v")
    printf '  attributed:   tokens %s  est. %s\n' "$(commify "$at")" "$(_usage_money "$atu")"
    printf '  unattributed: tokens %s  est. %s\n' "$(commify "$un")" "$(_usage_money "$unu")"
    printf '  all segments: tokens %s  est. %s\n' "$(commify "$al")" "$(_usage_money "$alu")"
    printf '  attributed with no initiative link: tokens %s\n' "$(commify "$nl")"
  fi
  _usage_markers "$v" "$hooks" "$unf"
}
