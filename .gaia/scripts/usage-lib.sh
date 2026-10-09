# shellcheck shell=bash
# GAIA usage-ledger shared library: paths, default branch, repo membership, the
# ref grammar, key derivation, the locked append, and component-presence checks.
# Sourced by the flusher, the resolver, usage.sh, and the hooks. Defines
# functions and the GAIA_USAGE_JQ_DEFS and GAIA_USAGE_START_SET variables only;
# sourcing runs no external command, so it succeeds under `set -u` with PATH
# empty.
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
# `--argjson branch_map`. usage_key($branch; $session_id; $default; $branch_map) returns
# {key, inherit}: a raw `worktree-agent-` branch keys `session:<sid>` with
# inherit true; otherwise $branch_map[$branch].norm empty, `HEAD`, or equal to
# $default keys `session:<sid>`, and any other norm takes $branch_map[$branch].key.
# usage_research_slug returns the slug string, or null when nothing binds.

# Loads <relative_path> (relative to this file's directory) when <function_name> is not yet defined.
# Errexit is suspended across the source and restored, because a sibling that
# fails to parse would otherwise abandon a caller that runs with `set -e`.
_gaia_usage_load() {
  local function_name="$1" relative_path="$2" source_path library_directory errexit_was=0
  if declare -f "$function_name" >/dev/null 2>&1; then return 0; fi
  source_path="${BASH_SOURCE[0]:-}"
  [ -n "$source_path" ] || return 1
  case "$source_path" in */*) library_directory="${source_path%/*}" ;; *) library_directory=. ;; esac
  [ -f "$library_directory/$relative_path" ] || return 1
  case $- in *e*) errexit_was=1 ;; esac
  set +e
  # shellcheck disable=SC1090
  source "$library_directory/$relative_path" 2>/dev/null
  if [ "$errexit_was" = 1 ]; then set -e; fi
  declare -f "$function_name" >/dev/null 2>&1
}

gaia_usage_main_root() {
  _gaia_usage_load gaia_resolve_main_root main-root-lib.sh || return 1
  gaia_resolve_main_root "${1:-}" 2>/dev/null || return 1
}

gaia_usage_telemetry_directory() { printf '%s\n' "${1%/}/.gaia/local/telemetry"; }

# Falls back to `main` when nothing names a default, so a fresh repo with no
# remote and no commits still keys its trunk work as session spend.
gaia_usage_default_branch() {
  local root="$1" remote_head
  remote_head="$(git -C "$root" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)" || remote_head=""
  remote_head="${remote_head#refs/remotes/origin/}"
  if [ -n "$remote_head" ]; then printf '%s\n' "$remote_head"; return 0; fi
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
  local root="$1" line path physical_root seen=$'\n'
  _gaia_usage_load _gaia_physical_directory main-root-lib.sh || return 1
  physical_root="$(_gaia_physical_directory "$root")" || physical_root="$root"
  printf '%s\n' "$physical_root"
  seen="$seen$physical_root"$'\n'
  while IFS= read -r line; do
    case "$line" in "worktree "*) ;; *) continue ;; esac
    path="${line#worktree }"
    [ -n "$path" ] || continue
    physical_root="$(_gaia_physical_directory "$path")" || physical_root="$path"
    case "$seen" in *$'\n'"$physical_root"$'\n'*) continue ;; esac
    seen="$seen$physical_root"$'\n'
    printf '%s\n' "$physical_root"
  done < <(git -C "$root" worktree list --porcelain 2>/dev/null)
}

# transcript_path wins; GAIA_TALLY_PROJECTS_ROOT applies only without one.
gaia_usage_projects_root() {
  local transcript_path="${1:-}" projects_directory
  case "$transcript_path" in
    */*/*)
      projects_directory="${transcript_path%/*}"; projects_directory="${projects_directory%/*}"
      if [ -n "$projects_directory" ]; then printf '%s\n' "$projects_directory"; return 0; fi
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
gaia_usage_candidate_directories() {
  local projects_root="${1%/}" main_root="$2" root project_directory name
  local names=$'\n' worktree_prefix
  while IFS= read -r root; do
    names="$names$(gaia_usage_encode_path "$root")"$'\n'
  done < <(gaia_usage_tree_roots "$main_root")
  worktree_prefix="$(gaia_usage_encode_path "$main_root")--claude-worktrees-"
  for project_directory in "$projects_root"/*/; do
    [ -d "$project_directory" ] || continue
    project_directory="${project_directory%/}"
    name="${project_directory##*/}"
    case "$name" in "$worktree_prefix"*) printf '%s\n' "$project_directory"; continue ;; esac
    case "$names" in *$'\n'"$name"$'\n'*) printf '%s\n' "$project_directory" ;; esac
  done
}

# One line per due file, oldest mtime first: "<size>\t<offset>\t<path>". A
# truncated file reports its cached offset so the caller can reset. A file with
# no cursor and no bytes is not due, so an empty transcript never pins the
# unflushed marker.
gaia_usage_due_files() {
  local projects_root="${1%/}" main_root="$2" telemetry_directory="$3"
  local cache="$telemetry_directory/usage-cursors.json" project_directory
  local stat_flag=-f stat_format='%z %m %N'
  local -a project_directories=()
  while IFS= read -r project_directory; do project_directories[${#project_directories[@]}]="$project_directory/"; done < <(gaia_usage_candidate_directories "$projects_root" "$main_root")
  [ "${#project_directories[@]}" -gt 0 ] || return 0
  [ -f "$cache" ] || cache=/dev/null
  # GNU stat takes -c and rejects -f as a format; BSD stat is the reverse.
  if stat -c '%s' . >/dev/null 2>&1; then stat_flag=-c stat_format='%s %Y %n'; fi
  find ${project_directories[@]+"${project_directories[@]}"} -maxdepth 5 -type f -name '*.jsonl' -print0 2>/dev/null |
    xargs -0 stat "$stat_flag" "$stat_format" 2>/dev/null |
    jq -rRn --arg root "$projects_root/" --rawfile cursor_cache "$cache" '
      (($cursor_cache | try fromjson catch null) | if type == "object" then .files else null end
        | if type == "object" then . else {} end) as $files
      | [inputs
        | capture("^(?<size_text>[0-9]+) (?<modified_text>[0-9]+) (?<path_text>.*)$")?
        | {size: (.size_text | tonumber), modified_time: (.modified_text | tonumber), path: .path_text, relative_path: (.path_text | ltrimstr($root))}
        | select(.relative_path | test("\\A[^/]+/([^/]+\\.jsonl|[^/]+/subagents/(workflows/[^/]+/)?agent-[^/]*\\.jsonl)\\z"))
        | . as $file_entry
        | ($files[$file_entry.path] | if . == null then null else (try (.offset | tonumber) catch 0) end) as $cursor_offset
        | select(($cursor_offset == null and $file_entry.size > 0) or ($cursor_offset != null and $file_entry.size != $cursor_offset))
        | {size, modified_time, path, offset: ($cursor_offset // 0)}]
      | sort_by(.modified_time) | .[] | "\(.size)\t\(.offset)\t\(.path)"' 2>/dev/null
}

gaia_usage_valid_reference() {
  local reference="${1-}" kind pattern
  kind="${reference%%:*}"
  case "$kind" in
    research | init) pattern='^(research|init):[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' ;;
    issue | pr) pattern='^(issue|pr):[1-9][0-9]{0,9}$' ;;
    spec) pattern='^spec:SPEC-[0-9]{3,}$' ;;
    plan) pattern='^plan:PLAN-[0-9]{3,}$' ;;
    branch)
      pattern='^branch:[A-Za-z0-9._/-]{1,128}$'
      if [[ "$reference" =~ $pattern ]]; then return 0; fi
      pattern='^branch:%[0-9a-f]{16}$'
      ;;
    session) pattern='^session:[A-Za-z0-9_-]{1,64}$' ;;
    command) pattern='^command:[A-Za-z0-9._-]{1,128}$' ;;
    *) return 1 ;;
  esac
  if [[ "$reference" =~ $pattern ]]; then return 0; fi
  return 1
}

# The first 16 hex characters of the input's sha256.
_gaia_usage_hash16() {
  local hash_output
  if hash_output="$(printf '%s' "$1" | shasum -a 256 2>/dev/null)" && [ -n "$hash_output" ]; then :
  elif hash_output="$(printf '%s' "$1" | sha256sum 2>/dev/null)" && [ -n "$hash_output" ]; then :
  else return 1; fi
  hash_output="${hash_output%% *}"
  printf '%s' "${hash_output:0:16}"
}

gaia_usage_branch_key() {
  _gaia_usage_set_branch_key "${1-}" || return 1
  printf '%s\n' "$_gaia_usage_key"
}

# Sets _gaia_usage_key; forks only to hash a name that fails the grammar.
_gaia_usage_set_branch_key() {
  local branch_name="${1-}" hash_value
  if gaia_usage_valid_reference "branch:$branch_name"; then _gaia_usage_key="branch:$branch_name"; return 0; fi
  hash_value="$(_gaia_usage_hash16 "$branch_name")" || return 1
  _gaia_usage_key="branch:%$hash_value"
}

# _gaia_usage_capture <file> <function_name> [args...]: sets _gaia_usage_text to what
# <function_name> printed, trailing newlines dropped exactly as $(...) drops them. The
# function runs in this shell with its output sent to <file>, so a reader
# walking thousands of branch names pays no subshell per name.
_gaia_usage_capture() {
  local capture_file="$1"
  shift
  _gaia_usage_text=""
  "$@" >"$capture_file" || return
  # read -d '' stops only at NUL or end of file, and says 1 at end of file.
  IFS= read -r -d '' _gaia_usage_text <"$capture_file" || true
  while :; do
    case "$_gaia_usage_text" in *$'\n') _gaia_usage_text="${_gaia_usage_text%$'\n'}" ;; *) break ;; esac
  done
  return 0
}

# Every positional carries a leading `x` that jq strips, so a raw spelling that
# starts with `-` is never read as a jq option. A repeated raw maps to the same
# entry, so repeats cost only time.
gaia_usage_branch_map() {
  local raw normalized_branch key capture_file
  local -a flat=()
  _gaia_usage_load gaia_branch_normalize branch-name-lib.sh || return 1
  capture_file="$(mktemp "${TMPDIR:-/tmp}/gaia-usage-bmap.XXXXXX")" || return 1
  for raw in "$@"; do
    _gaia_usage_capture "$capture_file" gaia_branch_normalize "$raw"
    normalized_branch="$_gaia_usage_text"
    key=""
    if [ -n "$normalized_branch" ] && _gaia_usage_set_branch_key "$normalized_branch"; then key="$_gaia_usage_key"; fi
    flat[${#flat[@]}]="x$raw"
    flat[${#flat[@]}]="x$normalized_branch"
    flat[${#flat[@]}]="x$key"
  done
  rm -f "$capture_file"
  jq -nc '$ARGS.positional | map(.[1:]) as $positionals
    | [range(0; $positionals | length; 3) | {key: $positionals[.], value: {norm: $positionals[. + 1], key: (if $positionals[. + 2] == "" then null else $positionals[. + 2] end)}}]
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
  local telemetry_directory="$1" target="$2" rows="$3" exit_status=0
  case "$target" in usage.jsonl | links.jsonl) ;; *) return 2 ;; esac
  [ -f "$rows" ] || return 2
  _gaia_usage_load with_ledger_lock spec/with-ledger-lock.sh || return 1
  mkdir -p "$telemetry_directory" || return 1
  with_ledger_lock "$telemetry_directory" _gaia_usage_append_write "$rows" "$telemetry_directory/$target" || exit_status=$?
  return "$exit_status"
}

gaia_usage_inactive_reason() {
  command -v jq >/dev/null 2>&1 || printf 'jq not found\n'
  return 0
}

gaia_usage_hooks_registered() {
  local settings="${1%/}/.claude/settings.json"
  [ -f "$settings" ] || return 1
  jq -e 'def reg($event): [((.hooks // {})[$event] // [])[]? | (.hooks // [])[]? | .command? | strings
        | select(contains("/.claude/hooks/usage-capture.sh"))] | length > 0;
      reg("Stop") and reg("SessionStart")' "$settings" >/dev/null 2>&1
}

gaia_usage_in_ci() { [ -n "${GITHUB_ACTIONS:-}" ]; }

# The workflows whose start opens an attribution interval and whose run
# `usage.sh record` closes, as a JSON array string. The flusher's start
# detection and record's workflow validation both read it.
# shellcheck disable=SC2034  # consumed by sourcing scripts
GAIA_USAGE_START_SET='["gaia-spec","gaia-plan","gaia-audit","gaia-debt","gaia-fitness","gaia-forensics","gaia-harden","gaia-residue","gaia-wiki"]'

# \A and \z, not ^ and $: Oniguruma's $ also matches before a trailing newline,
# which would let `research:x\n` through the grammar.
# shellcheck disable=SC2034,SC2016  # consumed by sourcing scripts; jq source, no shell expansion
GAIA_USAGE_JQ_DEFS='
def usage_valid_reference($reference):
  ($reference | type == "string") and ($reference | test("\\A((research|init):[A-Za-z0-9][A-Za-z0-9._-]{0,127}|(issue|pr):[1-9][0-9]{0,9}|spec:SPEC-[0-9]{3,}|plan:PLAN-[0-9]{3,}|branch:([A-Za-z0-9._/-]{1,128}|%[0-9a-f]{16})|session:[A-Za-z0-9_-]{1,64}|command:[A-Za-z0-9._-]{1,128})\\z"));
def usage_key($branch; $session_id; $default; $branch_map):
  if ($branch | type) == "string" and ($branch | startswith("worktree-agent-"))
  then {key: ("session:" + $session_id), inherit: true}
  else ($branch_map[$branch // ""] // {}) as $branch_entry
    | ($branch_entry.norm // "") as $normalized_branch
    | if $normalized_branch == "" or $normalized_branch == "HEAD" or $normalized_branch == $default or $branch_entry.key == null
      then {key: ("session:" + $session_id), inherit: false}
      else {key: $branch_entry.key, inherit: false} end
  end;
def usage_member($cwd; $roots):
  ($cwd | type == "string") and $cwd != ""
  and any($roots[]; (rtrimstr("/")) as $root | $root != "" and ($cwd == $root or ($cwd | startswith($root + "/"))));
def usage_research_slug($path; $research_roots):
  if ($path | type) != "string" or ($path | startswith("/") | not) then null
  elif ($path | split("/") | .[1:] | any(. == "" or . == "." or . == "..")) then null
  else
    ([$research_roots[] | (rtrimstr("/") + "/") as $research_root | select($path | startswith($research_root)) | $research_root] | first // null) as $research_root
    | if $research_root == null then null
      else ($path[($research_root | length):] | split("/")) as $segments
        | (if ($segments | length) > 1 then $segments[0]
           elif ($segments[0] | endswith(".md")) then ($segments[0] | .[: (length - 3)])
           else null end) as $slug
        | if $slug != null and ($slug | test("\\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\\z")) then $slug else null end
      end
  end;
'
