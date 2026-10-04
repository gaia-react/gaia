#!/usr/bin/env bash
# shellcheck shell=bash
#
# Per-worktree port ledger, port file, and the strings every consumer shares.
# Sourced by provisioning hooks and run through ports.sh. It never signals a
# process: stopping servers belongs to server-process-lib.sh.
#
# State lives under <main-root>/.gaia/local/ports/. Only slots.tsv is guarded
# by the lock, and the lock is never held across a wait or a signal, so a
# caller snapshots under the lock, releases it, and re-locks to rewrite.
#
# Bash 3.2 safe, no `set -e`: every caller reads the return codes.

_GAIA_PORTS_LIBRARY_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=main-root-lib.sh
source "$_GAIA_PORTS_LIBRARY_DIRECTORY/main-root-lib.sh"
# shellcheck source=../../.claude/hooks/lib/gaia-packages.sh
source "$_GAIA_PORTS_LIBRARY_DIRECTORY/../../.claude/hooks/lib/gaia-packages.sh"

GAIA_PORTS_ASK_FIRST_SENTENCE='Never stop a process on a port another live tree owns without asking the user first.'
GAIA_PORTS_HINT="Run bash .gaia/scripts/ports.sh to see this tree's ports."
GAIA_PORTS_FILE_NAME='.gaia-ports'
GAIA_PORTS_MAXIMUM_SLOT=99

_gaia_ports_git() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git "$@"
}

_gaia_ports_physical_directory() {
  ( cd "$1" 2>/dev/null && pwd -P )
}

gaia_ports_dev_base_port() {
  printf '%s\n' "${GAIA_PORTS_DEV_BASE_PORT:-5173}"
}

gaia_ports_storybook_base_port() {
  printf '%s\n' "${GAIA_PORTS_STORYBOOK_BASE_PORT:-6006}"
}

gaia_ports_state_directory() {
  local directory="${1:-}" main_root
  if [ -n "${GAIA_PORTS_STATE_DIRECTORY:-}" ]; then
    printf '%s\n' "$GAIA_PORTS_STATE_DIRECTORY"
    return 0
  fi
  main_root="$(gaia_resolve_main_root "$directory" 2>/dev/null)" || return 1
  [ -n "$main_root" ] || return 1
  printf '%s\n' "$main_root/.gaia/local/ports"
}

_gaia_ports_has_router_config() {
  local candidate
  for candidate in "$1"/react-router.config.*; do
    [ -e "$candidate" ] && return 0
  done
  return 1
}

gaia_ports_package_directory() {
  local tree_root="${1:-}" load_status=0 name package_path candidate entry
  [ -n "$tree_root" ] && [ -d "$tree_root" ] || return 3

  gaia_packages_load "$tree_root" >/dev/null 2>&1 || load_status=$?
  if [ "$load_status" -eq 0 ]; then
    while IFS=$'\t' read -r name package_path; do
      [ -n "$name" ] || continue
      if [ "$package_path" = . ]; then
        candidate="$tree_root"
      else
        candidate="$tree_root/$package_path"
      fi
      if _gaia_ports_has_router_config "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done <<<"$(gaia_packages_list)"
  fi

  # Without jq (or with an unreadable registry) the registry cannot be read;
  # the first top-level directory in byte order that holds a router config is
  # the same answer the stock layout gives.
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if _gaia_ports_has_router_config "$entry"; then
      printf '%s\n' "$entry"
      return 0
    fi
  done <<<"$(find "$tree_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort)"
  return 3
}

gaia_ports_file_path() {
  local package_directory
  package_directory="$(gaia_ports_package_directory "${1:-}")" || return 3
  printf '%s\n' "$package_directory/$GAIA_PORTS_FILE_NAME"
}

# GNU stat accepts --version and BSD stat does not. Probing for the flavor
# first matters because GNU's `stat -f` is a filesystem query that exits 0
# with unrelated output, so "try BSD, fall back on failure" would misread it.
gaia_ports_tree_marker() {
  local tree_root="${1:-}" git_path marker birth
  git_path="$tree_root/.git"
  [ -e "$git_path" ] || return 1
  if stat --version >/dev/null 2>&1; then
    marker="$(stat -c '%i:%W' "$git_path" 2>/dev/null)" || return 1
    birth="${marker#*:}"
    case "$birth" in
      0 | -) marker="$(stat -c '%i:%Z' "$git_path" 2>/dev/null)" || return 1 ;;
    esac
  else
    marker="$(stat -f '%i:%B' "$git_path" 2>/dev/null)" || return 1
  fi
  [ -n "$marker" ] || return 1
  printf '%s\n' "$marker"
}

gaia_ports_lock() {
  local state_directory="${1:-}" lock deadline broke=0 now allowed
  [ -n "$state_directory" ] || return 1
  allowed="${GAIA_PORTS_LOCK_DEADLINE_SECONDS:-3}"
  case "$allowed" in '' | *[!0-9]*) allowed=3 ;; esac
  mkdir -p "$state_directory" 2>/dev/null || return 1
  lock="$state_directory/slots.lock"
  deadline=$(( $(date +%s) + allowed ))
  while :; do
    mkdir "$lock" 2>/dev/null && return 0
    # A holder keeps the lock for a few file operations, far under a minute,
    # so an older lock belongs to a dead writer and is broken once.
    if [ "$broke" -eq 0 ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      rmdir "$lock" 2>/dev/null || rm -rf "$lock"
      broke=1
      continue
    fi
    now="$(date +%s)"
    [ "$now" -ge "$deadline" ] && return 1
    sleep 0.1
  done
}

gaia_ports_unlock() {
  local lock="${1:-}/slots.lock"
  rmdir "$lock" 2>/dev/null || rm -rf "$lock"
}

_gaia_ports_write_atomic() {
  local target="$1" content="$2" temporary
  temporary="$target.tmp.$$"
  printf '%s' "$content" 2>/dev/null >"$temporary" || { rm -f "$temporary"; return 1; }
  mv -f "$temporary" "$target" 2>/dev/null || { rm -f "$temporary"; return 1; }
}

_gaia_ports_write_tombstone() {
  local state_directory="$1" slot="$2" tree_root="$3" now
  now="$(date +%s)"
  mkdir -p "$state_directory/tombstones" 2>/dev/null || return 1
  _gaia_ports_write_atomic "$state_directory/tombstones/$slot.$now.tsv" "$slot"$'\t'"$tree_root"$'\t'"$now"$'\n'
}

gaia_ports_reclaim() {
  local state_directory="${1:-}" repository_directory="${2:-}"
  local ledger="$state_directory/slots.tsv"
  local porcelain registered line path physical slot tree_root marker kept='' removed=''
  [ -f "$ledger" ] || return 0

  porcelain="$(_gaia_ports_git -C "$repository_directory" worktree list --porcelain 2>/dev/null)" || return 1
  # An empty answer means git failed to list anything, not that no worktree
  # exists (the main checkout is always listed). Reclaiming on it would
  # discard every entry.
  [ -n "$porcelain" ] || return 1

  registered=$'\n'
  while IFS= read -r line; do
    case "$line" in
      'worktree '*)
        path="${line#worktree }"
        physical="$(_gaia_ports_physical_directory "$path")" || physical="$path"
        registered="${registered}${physical}"$'\n'
        ;;
    esac
  done <<<"$porcelain"

  while IFS=$'\t' read -r slot tree_root marker; do
    [ -n "$slot" ] || continue
    if [ -d "$tree_root" ]; then
      case "$registered" in
        *$'\n'"$tree_root"$'\n'*)
          kept="${kept}${slot}"$'\t'"${tree_root}"$'\t'"${marker}"$'\n'
          continue
          ;;
      esac
    fi
    if _gaia_ports_write_tombstone "$state_directory" "$slot" "$tree_root"; then
      removed="${removed}${slot}"$'\t'"${tree_root}"$'\n'
    else
      kept="${kept}${slot}"$'\t'"${tree_root}"$'\t'"${marker}"$'\n'
    fi
  done <"$ledger"

  [ -n "$removed" ] || return 0
  _gaia_ports_write_atomic "$ledger" "$kept" || return 1
  printf '%s' "$removed"
}

_gaia_ports_entry_for_tree() {
  local ledger="$1" wanted_tree="$2" slot tree_root marker
  [ -f "$ledger" ] || return 1
  while IFS=$'\t' read -r slot tree_root marker; do
    if [ "$tree_root" = "$wanted_tree" ]; then
      printf '%s\t%s\t%s\n' "$slot" "$tree_root" "$marker"
      return 0
    fi
  done <"$ledger"
  return 1
}

gaia_ports_retire_stale_entry() {
  local state_directory="${1:-}" tree_root="${2:-}"
  local ledger="$state_directory/slots.tsv"
  local entry slot recorded_root recorded_marker current_marker kept=''
  entry="$(_gaia_ports_entry_for_tree "$ledger" "$tree_root")" || return 1
  IFS=$'\t' read -r slot recorded_root recorded_marker <<<"$entry"
  current_marker="$(gaia_ports_tree_marker "$tree_root")" || return 1
  [ "$recorded_marker" != "$current_marker" ] || return 1

  _gaia_ports_write_tombstone "$state_directory" "$slot" "$tree_root" || return 1
  while IFS=$'\t' read -r slot recorded_root recorded_marker; do
    [ -n "$slot" ] || continue
    [ "$recorded_root" = "$tree_root" ] && continue
    kept="${kept}${slot}"$'\t'"${recorded_root}"$'\t'"${recorded_marker}"$'\n'
  done <"$ledger"
  _gaia_ports_write_atomic "$ledger" "$kept" || return 1
  return 0
}

_gaia_ports_slot_is_free() {
  local slot="$1" tree_root="$2" port answer
  type gaia_server_listener_owner >/dev/null 2>&1 || return 0
  for port in $(( $(gaia_ports_dev_base_port) + slot )) $(( $(gaia_ports_storybook_base_port) + slot )); do
    answer="$(gaia_server_listener_owner "$port" "$tree_root" 2>/dev/null)"
    case "$answer" in
      foreign*) return 1 ;;
    esac
  done
  return 0
}

gaia_ports_assign_slot() {
  local state_directory="${1:-}" tree_root="${2:-}"
  local ledger="$state_directory/slots.tsv"
  local entry slot recorded_root recorded_marker current_marker used=' ' candidate content

  mkdir -p "$state_directory" 2>/dev/null || return 1
  current_marker="$(gaia_ports_tree_marker "$tree_root")" || {
    printf 'GAIA: cannot read the .git marker of %s, so no port slot can be assigned.\n' "$tree_root" >&2
    return 1
  }

  # A stale entry for this very path belongs to a removed earlier incarnation
  # and would otherwise leave two entries naming one tree.
  gaia_ports_retire_stale_entry "$state_directory" "$tree_root" >/dev/null || true

  if entry="$(_gaia_ports_entry_for_tree "$ledger" "$tree_root")"; then
    IFS=$'\t' read -r slot recorded_root recorded_marker <<<"$entry"
    printf '%s\n' "$slot"
    return 0
  fi

  if [ -f "$ledger" ]; then
    while IFS=$'\t' read -r slot recorded_root recorded_marker; do
      [ -n "$slot" ] && used="${used}${slot} "
    done <"$ledger"
  fi

  candidate=1
  while [ "$candidate" -le "$GAIA_PORTS_MAXIMUM_SLOT" ]; do
    case "$used" in
      *" $candidate "*) ;;
      *)
        if _gaia_ports_slot_is_free "$candidate" "$tree_root"; then
          content=''
          [ -f "$ledger" ] && content="$(cat "$ledger")"$'\n'
          [ "$content" = $'\n' ] && content=''
          content="$(printf '%s%s\t%s\t%s\n' "$content" "$candidate" "$tree_root" "$current_marker" | LC_ALL=C sort -n -t $'\t' -k1,1)"$'\n'
          _gaia_ports_write_atomic "$ledger" "$content" || return 1
          printf '%s\n' "$candidate"
          return 0
        fi
        ;;
    esac
    candidate=$((candidate + 1))
  done
  return 1
}

_gaia_ports_strip_quotes() {
  local value="$1" quote rest
  case "$value" in
    \"* | \'*)
      quote="${value:0:1}"
      rest="${value:1}"
      case "$rest" in
        *"$quote"*) printf '%s' "${rest%%"$quote"*}"; return 0 ;;
      esac
      printf '%s' "$rest"
      return 0
      ;;
  esac
  printf '%s' "$value" | sed 's/[[:space:]][[:space:]]*#.*$//; s/[[:space:]]*$//'
}

gaia_ports_site_url() {
  local tree_root="${1:-}" dev_port="${2:-}" package_directory env_file raw value
  local scheme after authority rest userinfo hostport host default_url
  default_url="http://localhost:$dev_port"

  package_directory="$(gaia_ports_package_directory "$tree_root")" || { printf '%s\n' "$default_url"; return 0; }
  env_file="$package_directory/.env"
  [ -f "$env_file" ] || { printf '%s\n' "$default_url"; return 0; }

  # Read one line with sed. The file holds secrets and arbitrary shell, so it
  # is never sourced.
  raw="$(sed -n 's/^SITE_URL=\(.*\)$/\1/p' "$env_file" | tail -n 1 | tr -d '\r')"
  value="$(_gaia_ports_strip_quotes "$raw")"
  case "$value" in
    *://*) ;;
    *) printf '%s\n' "$default_url"; return 0 ;;
  esac

  scheme="${value%%://*}"
  after="${value#*://}"
  authority="${after%%[/?#]*}"
  rest="${after#"$authority"}"
  userinfo=''
  hostport="$authority"
  case "$authority" in
    *@*)
      userinfo="${authority%@*}@"
      hostport="${authority##*@}"
      ;;
  esac
  case "$hostport" in
    \[*\]*) host="${hostport%%\]*}]" ;;
    *) host="${hostport%%:*}" ;;
  esac
  [ -n "$scheme" ] && [ -n "$host" ] || { printf '%s\n' "$default_url"; return 0; }
  printf '%s://%s%s:%s%s\n' "$scheme" "$userinfo" "$host" "$dev_port" "$rest"
}

gaia_ports_write_file() {
  local tree_root="${1:-}" slot="${2:-}" file dev_port storybook_port site_url content
  case "$slot" in '' | *[!0-9]*) return 1 ;; esac
  file="$(gaia_ports_file_path "$tree_root")" || return 3
  dev_port=$(( $(gaia_ports_dev_base_port) + slot ))
  storybook_port=$(( $(gaia_ports_storybook_base_port) + slot ))
  site_url="$(gaia_ports_site_url "$tree_root" "$dev_port")"
  content="# GAIA per-worktree ports, written by worktree provisioning on every entry. Edits are overwritten."$'\n'
  content="${content}GAIA_PORT_SLOT=${slot}"$'\n'
  content="${content}DEV_PORT=${dev_port}"$'\n'
  content="${content}STORYBOOK_PORT=${storybook_port}"$'\n'
  content="${content}SITE_URL=${site_url}"$'\n'
  _gaia_ports_write_atomic "$file" "$content"
}

_gaia_ports_valid_port() {
  case "$1" in '' | *[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 5 ] || return 1
  [ "$((10#$1))" -ge 1 ] && [ "$((10#$1))" -le 65535 ]
}

gaia_ports_read_file() {
  local file="${1:-}" line key value
  local slot='' dev='' storybook='' site_url=''
  local slot_count=0 dev_count=0 storybook_count=0 site_url_count=0
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in '' | '#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      GAIA_PORT_SLOT) slot="$value"; slot_count=$((slot_count + 1)) ;;
      DEV_PORT) dev="$value"; dev_count=$((dev_count + 1)) ;;
      STORYBOOK_PORT) storybook="$value"; storybook_count=$((storybook_count + 1)) ;;
      SITE_URL) site_url="$value"; site_url_count=$((site_url_count + 1)) ;;
    esac
  done <"$file"

  [ "$slot_count" -eq 1 ] && [ "$dev_count" -eq 1 ] && [ "$storybook_count" -eq 1 ] && [ "$site_url_count" -eq 1 ] || return 2
  case "$slot" in '' | *[!0-9]*) return 2 ;; esac
  _gaia_ports_valid_port "$dev" || return 2
  _gaia_ports_valid_port "$storybook" || return 2
  [ -n "$site_url" ] || return 2
  printf '%s\t%s\t%s\t%s\n' "$slot" "$dev" "$storybook" "$site_url"
}

gaia_ports_context_line() {
  printf 'GAIA ports for this worktree (slot %s): app %s, Storybook http://localhost:%s. %s %s\n' \
    "${1:-}" "${2:-}" "${3:-}" "$GAIA_PORTS_ASK_FIRST_SENTENCE" "$GAIA_PORTS_HINT"
}

gaia_ports_missing_file_message() {
  local tree_root="${1:-}" file="${2:-}"
  printf "GAIA: %s is a linked worktree with no port file at %s, so it has no ports of its own and will not borrow the main checkout's. Run: bash .claude/hooks/provision-worktree.sh %s %s %s\n" \
    "$tree_root" "$file" "$tree_root" "$GAIA_PORTS_ASK_FIRST_SENTENCE" "$GAIA_PORTS_HINT"
}
