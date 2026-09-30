# shellcheck shell=bash
# GAIA usage-ledger shared library: paths, default branch, repo membership, the
# ref grammar, key derivation, the locked append, and component-presence checks.
# Sourced by the flusher, the resolver, usage.sh, and the hooks. Defines
# functions and the GAIA_USAGE_JQ_DEFS variable only; sourcing runs no external
# command, so it succeeds under `set -u` with PATH empty.
#
# Siblings (main-root-lib.sh, branch-name-lib.sh, with-ledger-lock.sh) are
# sourced lazily by the first function that needs one, located from
# BASH_SOURCE[0]. A dependent function returns 1 when its sibling is missing.
# Under zsh BASH_SOURCE is empty, so a zsh caller can source this file and call
# the pure functions (valid_ref, encode_path, inactive_reason, in_ci), while
# every function that needs a sibling returns 1. A relative source path must
# stay valid from the caller's working directory at call time.
#
# GAIA_USAGE_JQ_DEFS carries the jq defs the readers share. There is no jq copy
# of gaia_branch_normalize: a caller collects the distinct raw gitBranch values,
# builds the map with gaia_usage_branch_map, and passes it with
# `--argjson bmap`. usage_key($branch; $sid; $default; $bmap) returns
# {key, inherit}: a raw `worktree-agent-` branch keys `session:<sid>` with
# inherit true; otherwise $bmap[$branch].norm empty, `HEAD`, or equal to
# $default keys `session:<sid>`, and any other norm takes $bmap[$branch].key.
# usage_research_slug returns the slug string, or null when nothing binds.

# Loads <rel> (relative to this file's directory) when <fn> is not yet defined.
# Errexit is suspended across the source and restored, because a sibling that
# fails to parse would otherwise abandon a caller that runs with `set -e`.
_gaia_usage_load() {
  local fn="$1" rel="$2" src dir errexit_was=0
  if declare -f "$fn" >/dev/null 2>&1; then return 0; fi
  src="${BASH_SOURCE[0]:-}"
  [ -n "$src" ] || return 1
  case "$src" in */*) dir="${src%/*}" ;; *) dir=. ;; esac
  [ -f "$dir/$rel" ] || return 1
  case $- in *e*) errexit_was=1 ;; esac
  set +e
  # shellcheck disable=SC1090
  source "$dir/$rel" 2>/dev/null
  if [ "$errexit_was" = 1 ]; then set -e; fi
  declare -f "$fn" >/dev/null 2>&1
}

gaia_usage_main_root() {
  _gaia_usage_load gaia_resolve_main_root main-root-lib.sh || return 1
  gaia_resolve_main_root "${1:-}" 2>/dev/null || return 1
}

gaia_usage_telemetry_dir() { printf '%s\n' "${1%/}/.gaia/local/telemetry"; }

# Falls back to `main` when nothing names a default, so a fresh repo with no
# remote and no commits still keys its trunk work as session spend.
gaia_usage_default_branch() {
  local root="$1" ref
  ref="$(git -C "$root" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)" || ref=""
  ref="${ref#refs/remotes/origin/}"
  if [ -n "$ref" ]; then printf '%s\n' "$ref"; return 0; fi
  if git -C "$root" show-ref --verify --quiet refs/heads/main 2>/dev/null ||
    git -C "$root" show-ref --verify --quiet refs/remotes/origin/main 2>/dev/null; then
    printf 'main\n'; return 0
  fi
  if git -C "$root" show-ref --verify --quiet refs/heads/master 2>/dev/null ||
    git -C "$root" show-ref --verify --quiet refs/remotes/origin/master 2>/dev/null; then
    printf 'master\n'; return 0
  fi
  printf 'main\n'
}

# A worktree git lists but whose directory is gone keeps its listed spelling:
# its old transcripts still belong to the repo.
gaia_usage_tree_roots() {
  local root="$1" line path phys seen=$'\n'
  _gaia_usage_load _gaia_physical_dir main-root-lib.sh || return 1
  phys="$(_gaia_physical_dir "$root")" || phys="$root"
  printf '%s\n' "$phys"
  seen="$seen$phys"$'\n'
  while IFS= read -r line; do
    case "$line" in "worktree "*) ;; *) continue ;; esac
    path="${line#worktree }"
    [ -n "$path" ] || continue
    phys="$(_gaia_physical_dir "$path")" || phys="$path"
    case "$seen" in *$'\n'"$phys"$'\n'*) continue ;; esac
    seen="$seen$phys"$'\n'
    printf '%s\n' "$phys"
  done < <(git -C "$root" worktree list --porcelain 2>/dev/null)
}

# transcript_path wins; GAIA_TALLY_PROJECTS_ROOT applies only without one.
gaia_usage_projects_root() {
  local tp="${1:-}" d
  case "$tp" in
    */*/*)
      d="${tp%/*}"; d="${d%/*}"
      if [ -n "$d" ]; then printf '%s\n' "$d"; return 0; fi
      ;;
  esac
  if [ -n "${GAIA_TALLY_PROJECTS_ROOT:-}" ]; then
    printf '%s\n' "$GAIA_TALLY_PROJECTS_ROOT"
    return 0
  fi
  printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
}

# Every byte outside [A-Za-z0-9] becomes `-`. Wider than the Cost Data
# Contract's session_cwd note, which names only `/` and `.`: `_`, `+`, and
# space also map to `-` in Claude Code's projects-directory names.
gaia_usage_encode_path() { printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'; }

# Only a filter: a directory that passes still has each line checked against
# the tree roots by cwd.
gaia_usage_candidate_dirs() {
  local projects_root="${1%/}" main_root="$2" root d name
  local names=$'\n' pfx
  while IFS= read -r root; do
    names="$names$(gaia_usage_encode_path "$root")"$'\n'
  done < <(gaia_usage_tree_roots "$main_root")
  pfx="$(gaia_usage_encode_path "$main_root")--claude-worktrees-"
  for d in "$projects_root"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    name="${d##*/}"
    case "$name" in "$pfx"*) printf '%s\n' "$d"; continue ;; esac
    case "$names" in *$'\n'"$name"$'\n'*) printf '%s\n' "$d" ;; esac
  done
}

# One line per due file, oldest mtime first: "<size>\t<offset>\t<path>". A
# truncated file reports its cached offset so the caller can reset. A file with
# no cursor and no bytes is not due, so an empty transcript never pins the
# unflushed marker.
gaia_usage_due_files() {
  local projects_root="${1%/}" main_root="$2" telemetry_dir="$3"
  local cache="$telemetry_dir/usage-cursors.json" dir
  local statflag=-f statfmt='%z %m %N'
  local -a dirs=()
  while IFS= read -r dir; do dirs[${#dirs[@]}]="$dir/"; done < <(gaia_usage_candidate_dirs "$projects_root" "$main_root")
  [ "${#dirs[@]}" -gt 0 ] || return 0
  [ -f "$cache" ] || cache=/dev/null
  # GNU stat takes -c and rejects -f as a format; BSD stat is the reverse.
  if stat -c '%s' . >/dev/null 2>&1; then statflag=-c statfmt='%s %Y %n'; fi
  find ${dirs[@]+"${dirs[@]}"} -maxdepth 5 -type f -name '*.jsonl' -print0 2>/dev/null |
    xargs -0 stat "$statflag" "$statfmt" 2>/dev/null |
    jq -rRn --arg root "$projects_root/" --rawfile c "$cache" '
      (($c | try fromjson catch null) | if type == "object" then .files else null end
        | if type == "object" then . else {} end) as $files
      | [inputs
        | capture("^(?<s>[0-9]+) (?<m>[0-9]+) (?<p>.*)$")?
        | {size: (.s | tonumber), m: (.m | tonumber), path: .p, rel: (.p | ltrimstr($root))}
        | select(.rel | test("\\A[^/]+/([^/]+\\.jsonl|[^/]+/subagents/(workflows/[^/]+/)?agent-[^/]*\\.jsonl)\\z"))
        | . as $f
        | ($files[$f.path] | if . == null then null else (try (.offset | tonumber) catch 0) end) as $off
        | select(($off == null and $f.size > 0) or ($off != null and $f.size != $off))
        | {size, m, path, off: ($off // 0)}]
      | sort_by(.m) | .[] | "\(.size)\t\(.off)\t\(.path)"' 2>/dev/null
}

gaia_usage_valid_ref() {
  local ref="${1-}" kind re
  kind="${ref%%:*}"
  case "$kind" in
    research | init) re='^(research|init):[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' ;;
    issue | pr) re='^(issue|pr):[1-9][0-9]{0,9}$' ;;
    spec) re='^spec:SPEC-[0-9]{3,}$' ;;
    plan) re='^plan:PLAN-[0-9]{3,}$' ;;
    branch)
      re='^branch:[A-Za-z0-9._/-]{1,128}$'
      if [[ "$ref" =~ $re ]]; then return 0; fi
      re='^branch:%[0-9a-f]{16}$'
      ;;
    session) re='^session:[A-Za-z0-9_-]{1,64}$' ;;
    command) re='^command:[A-Za-z0-9._-]{1,128}$' ;;
    *) return 1 ;;
  esac
  if [[ "$ref" =~ $re ]]; then return 0; fi
  return 1
}

# Must equal gaia_hash16 in token-pricing-lib.sh for the same input. Computed
# here rather than sourced so this library never loads the pricing lib.
_gaia_usage_hash16() {
  local out
  if out="$(printf '%s' "$1" | shasum -a 256 2>/dev/null)" && [ -n "$out" ]; then :
  elif out="$(printf '%s' "$1" | sha256sum 2>/dev/null)" && [ -n "$out" ]; then :
  else return 1; fi
  out="${out%% *}"
  printf '%s' "${out:0:16}"
}

gaia_usage_branch_key() {
  _gaia_usage_set_branch_key "${1-}" || return 1
  printf '%s\n' "$_gaia_usage_key"
}

# Sets _gaia_usage_key; forks only to hash a name that fails the grammar.
_gaia_usage_set_branch_key() {
  local b="${1-}" h
  if gaia_usage_valid_ref "branch:$b"; then _gaia_usage_key="branch:$b"; return 0; fi
  h="$(_gaia_usage_hash16 "$b")" || return 1
  _gaia_usage_key="branch:%$h"
}

# _gaia_usage_capture <file> <fn> [args...]: sets _gaia_usage_text to what
# <fn> printed, trailing newlines dropped exactly as $(...) drops them. The
# function runs in this shell with its output sent to <file>, so a reader
# walking thousands of branch names pays no subshell per name.
_gaia_usage_capture() {
  local f="$1"
  shift
  _gaia_usage_text=""
  "$@" >"$f" || return
  # read -d '' stops only at NUL or end of file, and says 1 at end of file.
  IFS= read -r -d '' _gaia_usage_text <"$f" || true
  while :; do
    case "$_gaia_usage_text" in *$'\n') _gaia_usage_text="${_gaia_usage_text%$'\n'}" ;; *) break ;; esac
  done
  return 0
}

# Every positional carries a leading `x` that jq strips, so a raw spelling that
# starts with `-` is never read as a jq option. A repeated raw maps to the same
# entry, so repeats cost only time.
gaia_usage_branch_map() {
  local raw norm key tmp
  local -a flat=()
  _gaia_usage_load gaia_branch_normalize branch-name-lib.sh || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/gaia-usage-bmap.XXXXXX")" || return 1
  for raw in "$@"; do
    _gaia_usage_capture "$tmp" gaia_branch_normalize "$raw"
    norm="$_gaia_usage_text"
    key=""
    if [ -n "$norm" ] && _gaia_usage_set_branch_key "$norm"; then key="$_gaia_usage_key"; fi
    flat[${#flat[@]}]="x$raw"
    flat[${#flat[@]}]="x$norm"
    flat[${#flat[@]}]="x$key"
  done
  rm -f "$tmp"
  jq -nc '$ARGS.positional | map(.[1:]) as $p
    | [range(0; $p | length; 3) | {key: $p[.], value: {norm: $p[. + 1], key: (if $p[. + 2] == "" then null else $p[. + 2] end)}}]
    | from_entries' --args ${flat[@]+"${flat[@]}"}
}

# Named so with_ledger_lock can run it as a command. It never returns 75, so a
# 75 from the lock always means the acquisition timed out.
_gaia_usage_append_write() {
  cat "$1" >>"$2" || return 1
}

# Appends <rows_file> to a ledger under the shared cost mutex. Never appends
# unlocked: rc 75 means nothing was written, rc 1 means no mutex was available.
gaia_usage_append() {
  local dir="$1" target="$2" rows="$3" rc=0
  case "$target" in usage.jsonl | links.jsonl) ;; *) return 2 ;; esac
  [ -f "$rows" ] || return 2
  _gaia_usage_load with_ledger_lock ../../.specify/extensions/gaia/lib/with-ledger-lock.sh || return 1
  mkdir -p "$dir" || return 1
  with_ledger_lock "$dir" _gaia_usage_append_write "$rows" "$dir/$target" || rc=$?
  return "$rc"
}

gaia_usage_inactive_reason() {
  command -v jq >/dev/null 2>&1 || printf 'jq not found\n'
  return 0
}

gaia_usage_hooks_registered() {
  local settings="${1%/}/.claude/settings.json"
  [ -f "$settings" ] || return 1
  jq -e 'def reg($ev): [((.hooks // {})[$ev] // [])[]? | (.hooks // [])[]? | .command? | strings
        | select(contains("/.claude/hooks/usage-capture.sh"))] | length > 0;
      reg("Stop") and reg("SessionStart")' "$settings" >/dev/null 2>&1
}

gaia_usage_in_ci() { [ -n "${GITHUB_ACTIONS:-}" ]; }

# \A and \z, not ^ and $: Oniguruma's $ also matches before a trailing newline,
# which would let `research:x\n` through the grammar.
# shellcheck disable=SC2034,SC2016  # consumed by sourcing scripts; jq source, no shell expansion
GAIA_USAGE_JQ_DEFS='
def usage_valid_ref($r):
  ($r | type == "string") and ($r | test("\\A((research|init):[A-Za-z0-9][A-Za-z0-9._-]{0,127}|(issue|pr):[1-9][0-9]{0,9}|spec:SPEC-[0-9]{3,}|plan:PLAN-[0-9]{3,}|branch:([A-Za-z0-9._/-]{1,128}|%[0-9a-f]{16})|session:[A-Za-z0-9_-]{1,64}|command:[A-Za-z0-9._-]{1,128})\\z"));
def usage_key($branch; $sid; $default; $bmap):
  if ($branch | type) == "string" and ($branch | startswith("worktree-agent-"))
  then {key: ("session:" + $sid), inherit: true}
  else ($bmap[$branch // ""] // {}) as $m
    | ($m.norm // "") as $n
    | if $n == "" or $n == "HEAD" or $n == $default or $m.key == null
      then {key: ("session:" + $sid), inherit: false}
      else {key: $m.key, inherit: false} end
  end;
def usage_member($cwd; $roots):
  ($cwd | type == "string") and $cwd != ""
  and any($roots[]; (rtrimstr("/")) as $r | $r != "" and ($cwd == $r or ($cwd | startswith($r + "/"))));
def usage_research_slug($path; $research_roots):
  if ($path | type) != "string" or ($path | startswith("/") | not) then null
  elif ($path | split("/") | .[1:] | any(. == "" or . == "." or . == "..")) then null
  else
    ([$research_roots[] | (rtrimstr("/") + "/") as $r | select($path | startswith($r)) | $r] | first // null) as $r
    | if $r == null then null
      else ($path[($r | length):] | split("/")) as $s
        | (if ($s | length) > 1 then $s[0]
           elif ($s[0] | endswith(".md")) then ($s[0] | .[: (length - 3)])
           else null end) as $slug
        | if $slug != null and ($slug | test("\\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\\z")) then $slug else null end
      end
  end;
'
