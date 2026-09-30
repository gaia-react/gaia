# shellcheck shell=bash
# GAIA machine-local rate table: resolve, seed, and sync.
#
# Owns the table the cost readout prices from: <main>/.gaia/local/telemetry/
# token-rates.json, seeded from the main checkout's distributed
# .gaia/scripts/token-rates.json and kept current by a per-model three-way merge
# that never replaces a row the adopter edited. The distributed source is always
# the main checkout's file, never a linked worktree's copy.
#
# Calling rule: call gaia_rates_prepare in the caller's own shell, never inside
# $(...). It sets GAIA_RATES_TABLE / GAIA_RATES_MODE / GAIA_RATES_DIR and keeps
# per-process state, and a subshell would discard both. Nothing here writes to
# stdout or changes shell options; the sourcing script's own options stand.
# No side effects at source time beyond defining constants and functions.
#
# Portability: macOS bash 3.2 and BSD tools as well as Linux GNU, so cmp -s,
# $(date +%s), and mktemp in the target's own directory; no stat flags,
# date -d/-v, realpath, or bash 4 features.

GAIA_RATES_DIST_REL='.gaia/scripts/token-rates.json'
GAIA_RATES_STATE_REL='.gaia/local/telemetry'
GAIA_RATES_LOCAL_NAME='token-rates.json'
GAIA_RATES_BASE_NAME='token-rates.base.json'
GAIA_RATES_DISTCOPY_NAME='token-rates.dist.json'
GAIA_RATES_CORRUPT_KEEP=5

_GAIA_RATES_PREPARED=0
_GAIA_RATES_PREPARED_RC=1

# 0 when <path> is a non-empty JSON object with an object-valued `models`.
_gaia_rates_table_readable() {
  local path="${1:-}"
  [[ -n "$path" && -s "$path" ]] || return 1
  jq -e 'type == "object" and (.models | type) == "object"' "$path" >/dev/null 2>&1
}

# Copy <src_file>'s bytes to <target> through a same-directory temp file and mv,
# so a reader never sees a partial table. Non-zero (temp removed) on failure.
_gaia_rates_write_file() {
  local target="$1" src="$2" dir base tmp
  dir="$(dirname "$target")"
  base="$(basename "$target")"
  tmp="$(mktemp "$dir/.$base.tmp.XXXXXX" 2>/dev/null)" || return 1
  if cp "$src" "$tmp" 2>/dev/null && mv -f "$tmp" "$target" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# Write `jq .` of <json_string> to <target> the same way. Non-zero on a write
# failure or invalid JSON.
_gaia_rates_write_json() {
  local target="$1" json="$2" dir base tmp
  dir="$(dirname "$target")"
  base="$(basename "$target")"
  tmp="$(mktemp "$dir/.$base.tmp.XXXXXX" 2>/dev/null)" || return 1
  if printf '%s' "$json" | jq . >"$tmp" 2>/dev/null && [[ -s "$tmp" ]] \
    && mv -f "$tmp" "$target" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# Preserve an unreadable local table as token-rates.json.corrupt.<epoch>.XXXXXX
# and keep only the newest GAIA_RATES_CORRUPT_KEEP copies (lexical name order is
# time order). Names the preserved path on one stderr line.
_gaia_rates_preserve_corrupt() {
  local state="$1" local_table="$2" dest old n=0
  dest="$(mktemp "$state/$GAIA_RATES_LOCAL_NAME.corrupt.$(date +%s).XXXXXX" 2>/dev/null)" || return 1
  mv -f "$local_table" "$dest" 2>/dev/null || { rm -f "$dest"; return 1; }
  printf 'token-pricing: local rate table unreadable; preserved as %s; re-seeded\n' "$dest" >&2
  # The new copy is exempt from pruning even if its random suffix sorts old
  # inside the same second.
  while IFS= read -r old; do
    [[ -e "$old" ]] || continue
    n=$((n + 1))
    if [[ $n -gt $GAIA_RATES_CORRUPT_KEEP && "$old" != "$dest" ]]; then
      rm -f "$old" 2>/dev/null
    fi
  done < <(printf '%s\n' "$state/$GAIA_RATES_LOCAL_NAME".corrupt.* | LC_ALL=C sort -r)
  return 0
}

# Seed the local table, then its base, then the distributed byte copy, in that
# order so an interruption leaves at worst a stale base (treated as "edited").
_gaia_rates_seed() {
  local state="$1" dist="$2" base_json
  _gaia_rates_write_file "$state/$GAIA_RATES_LOCAL_NAME" "$dist" || return 1
  base_json="$(jq -c . "$dist" 2>/dev/null)" || base_json=""
  [[ -n "$base_json" ]] && _gaia_rates_write_json "$state/$GAIA_RATES_BASE_NAME" "$base_json"
  _gaia_rates_write_file "$state/$GAIA_RATES_DISTCOPY_NAME" "$dist"
  return 0
}

# Per-model three-way merge of local (L), base (B), and new distributed (D).
# A null base means every local row counts as edited. Prints one JSON object:
# {local, base, same} where `same` is true when the merged local equals D.
_gaia_rates_merge() {
  local local_table="$1" base_table="$2" dist="$3"
  local -a base_args=(--argjson b '[]')
  if _gaia_rates_table_readable "$base_table"; then
    base_args=(--slurpfile b "$base_table")
  fi
  jq -n -c --slurpfile l "$local_table" --slurpfile d "$dist" "${base_args[@]}" '
    def pick($lv; $bv; $dv):
      if $lv != null then
        if $bv != null and $lv == $bv then
          (if $dv != null then {l: $dv, b: $dv} else {l: $lv, b: $bv} end)
        else
          {l: $lv, b: (if $dv != null then $dv elif $bv != null then $bv else null end)}
        end
      elif $dv != null then {l: $dv, b: $dv}
      else {l: null, b: null} end;
    $l[0] as $L | $d[0] as $D | $b[0] as $B
    | ($L.models // {}) as $LM | ($D.models // {}) as $DM | ($B.models // {}) as $BM
    | ((($LM | keys) + ($DM | keys)) | unique) as $ks
    | (reduce $ks[] as $k ({l: {}, b: {}};
        pick($LM[$k]; $BM[$k]; $DM[$k]) as $p
        | (if $p.l != null then .l[$k] = $p.l else . end)
        | (if $p.b != null then .b[$k] = $p.b else . end))) as $m
    | pick($L.cache_multipliers; $B.cache_multipliers; $D.cache_multipliers) as $c
    | ($D | del(.models, .cache_multipliers)) as $ex
    | ($ex + (if $c.l != null then {cache_multipliers: $c.l} else {} end) + {models: $m.l}) as $nl
    | ($ex + (if $c.b != null then {cache_multipliers: $c.b} else {} end) + {models: $m.b}) as $nb
    | {local: $nl, base: $nb, same: ($nl == $D)}
  ' 2>/dev/null
}

# Sync the local table to a changed distributed table. Order: local, base, byte
# copy. No lock; last rename wins.
_gaia_rates_sync() {
  local state="$1" dist="$2" local_table merged same
  local_table="$state/$GAIA_RATES_LOCAL_NAME"
  merged="$(_gaia_rates_merge "$local_table" "$state/$GAIA_RATES_BASE_NAME" "$dist")" || return 1
  [[ -n "$merged" ]] || return 1
  same="$(jq -r '.same' <<<"$merged" 2>/dev/null)"
  if [[ "$same" == "true" ]]; then
    # The distributed bytes verbatim, so rate_table_id equals the committed id.
    _gaia_rates_write_file "$local_table" "$dist" || return 1
  else
    _gaia_rates_write_json "$local_table" "$(jq -c '.local' <<<"$merged")" || return 1
  fi
  _gaia_rates_write_json "$state/$GAIA_RATES_BASE_NAME" "$(jq -c '.base' <<<"$merged")" || return 0
  _gaia_rates_write_file "$state/$GAIA_RATES_DISTCOPY_NAME" "$dist" || return 0
  return 0
}

# Readonly fallback: price the distributed table in place, no seed/sync/heal.
_gaia_rates_readonly() {
  local path="$1"
  GAIA_RATES_MODE="readonly"
  GAIA_RATES_DIR=""
  if [[ -n "$path" && -r "$path" && -s "$path" ]]; then
    GAIA_RATES_TABLE="$path"
    return 0
  fi
  GAIA_RATES_MODE=""
  GAIA_RATES_TABLE=""
  return 1
}

# shellcheck disable=SC2034 # the GAIA_RATES_* outputs are read by sourcing scripts
_gaia_rates_prepare_inner() {
  local override="${1:-}" main_root="${2:-}"
  GAIA_RATES_TABLE=""
  GAIA_RATES_MODE=""
  GAIA_RATES_DIR=""

  if [[ -n "$override" ]]; then
    GAIA_RATES_MODE="override"
    GAIA_RATES_TABLE="$override"
    return 0
  fi

  if [[ -z "$main_root" ]]; then
    local script_dir errexit_was
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # Same errexit-preserving bracket as ledger-path-lib.sh: an unparseable
    # main-root-lib.sh must degrade to readonly, not abandon the caller.
    errexit_was=0
    case $- in *e*) errexit_was=1 ;; esac
    set +e
    # shellcheck disable=SC1091
    source "$script_dir/main-root-lib.sh" 2>/dev/null
    if [ "$errexit_was" = 1 ]; then set -e; fi
    if declare -F gaia_resolve_main_root >/dev/null 2>&1; then
      main_root="$(gaia_resolve_main_root 2>/dev/null)" || main_root=""
    fi
  fi

  if [[ -z "$main_root" ]]; then
    # Only when no main checkout resolves: the cwd's own tree is the best table.
    local toplevel
    toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" || toplevel=""
    [[ -n "$toplevel" ]] || return 1
    _gaia_rates_readonly "$toplevel/$GAIA_RATES_DIST_REL"
    return $?
  fi

  local dist state local_table
  dist="$main_root/$GAIA_RATES_DIST_REL"
  state="${GAIA_RATES_STATE_DIR:-$main_root/$GAIA_RATES_STATE_REL}"
  local_table="$state/$GAIA_RATES_LOCAL_NAME"

  if ! { [[ -d "$state" ]] || mkdir -p "$state" 2>/dev/null; } || [[ ! -w "$state" ]]; then
    _gaia_rates_readonly "$dist"
    return $?
  fi

  local dist_ok=0
  _gaia_rates_table_readable "$dist" && dist_ok=1

  if [[ -e "$local_table" ]] && ! _gaia_rates_table_readable "$local_table"; then
    if [[ $dist_ok -eq 0 ]]; then
      _gaia_rates_readonly "$dist"
      return $?
    fi
    _gaia_rates_preserve_corrupt "$state" "$local_table" || true
  fi

  if [[ ! -e "$local_table" ]]; then
    if [[ $dist_ok -eq 0 ]] || ! _gaia_rates_seed "$state" "$dist"; then
      _gaia_rates_readonly "$dist"
      return $?
    fi
  elif [[ $dist_ok -eq 1 ]] && ! cmp -s "$dist" "$state/$GAIA_RATES_DISTCOPY_NAME" 2>/dev/null; then
    _gaia_rates_sync "$state" "$dist" || true
  fi

  GAIA_RATES_MODE="local"
  GAIA_RATES_TABLE="$local_table"
  GAIA_RATES_DIR="$state"
  return 0
}

# gaia_rates_prepare <override> [main_root]: sets GAIA_RATES_TABLE,
# GAIA_RATES_MODE (override|local|readonly|""), GAIA_RATES_DIR; returns 0 when a
# table is set. Idempotent per process: a second call returns the cached result.
gaia_rates_prepare() {
  if [[ "$_GAIA_RATES_PREPARED" == "1" ]]; then
    return "$_GAIA_RATES_PREPARED_RC"
  fi
  _GAIA_RATES_PREPARED=1
  if _gaia_rates_prepare_inner "$@"; then
    _GAIA_RATES_PREPARED_RC=0
  else
    _GAIA_RATES_PREPARED_RC=1
  fi
  return "$_GAIA_RATES_PREPARED_RC"
}
