#!/usr/bin/env bash
# shellcheck shell=bash
#
# GAIA dev-server process library: listener discovery, process identity,
# owning-tree attribution, verified stops, and the launch and session records
# that let a later session stop servers an ended Claude session left running.
# Dual-mode: source it for the functions below, or run it for the CLI at the
# bottom. Bash 3.2 safe, BSD and GNU tools, no `set -e`.
#
# Every automated signal GAIA sends to a dev server goes through this file, and
# a wrong match stops another session's or a human's server. So the rule here
# is "refuse, do not guess": this is a per-tree reaper, and an identity it
# cannot establish with positive evidence is a reason to do nothing.
#
# Process backend, chosen by GAIA_PORTS_PROCESS_PROBE (`auto`, the default,
# `lsof`, or `proc`): `lsof` reads listeners and working directories on macOS
# and Linux alike; `proc` reads listeners from `ss` and working directories
# from /proc/<pid>/cwd on Linux. `auto` prefers `lsof` and falls back to
# `proc` where /proc exists. With neither, listener discovery returns 3,
# ownership answers `unknown`, and nothing is ever stopped.
#
# Listener discovery sees only processes the caller may inspect: an
# unprivileged `lsof` lists the caller's own processes, and `ss` omits the
# owning PID of another user's socket (reported here as PID 0, which no stop
# ever signals).
#
# State lives under the main-anchored ports directory (one file per record, so
# a reaper deletes with `rm` and never rewrites a shared file; this library
# takes no lock):
#   launches/<pid>.tsv     pid, start, command, cwd, port, kind, session id,
#                          host pid, host start, tree root
#   sessions/<id>.tsv      host pid, host start, host command, registered epoch
#   tombstones/*.tsv       slot, tree root, reclaimed epoch (written elsewhere)
#   slots.tsv              slot, tree root, tree marker (read here, never written)
#
# Test seams (not adopter tuning): GAIA_PORTS_PROCESS_PROBE,
# GAIA_PORTS_HOST_PID, GAIA_PORTS_STATE_DIRECTORY, GAIA_PORTS_DEV_BASE_PORT,
# GAIA_PORTS_STORYBOOK_BASE_PORT.
#
# Usage (executable):
#   bash .gaia/scripts/server-process-lib.sh --listener-owner <port> <tree-root>
#   bash .gaia/scripts/server-process-lib.sh --record-launch --pid <pid> \
#     --port <port> --kind <dev|storybook> --tree <tree-root>
#   bash .gaia/scripts/server-process-lib.sh --listeners <port>...
# Exit 0 except usage errors (2).

_gaia_server_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)"
# shellcheck source=main-root-lib.sh
. "$_gaia_server_library_directory/main-root-lib.sh"

_gaia_server_tab=$'\t'
_gaia_server_tombstone_expiry_seconds=$((7 * 24 * 60 * 60))
_gaia_server_stop_wait_tenths=30
_gaia_server_ancestry_step_limit=64

_gaia_server_diagnostic() {
  printf 'GAIA server-process: %s\n' "$*" >&2
}

_gaia_server_is_integer() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
  return 0
}

_gaia_server_is_port() {
  _gaia_server_is_integer "$1" || return 1
  [ "${#1}" -le 5 ] || return 1
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

_gaia_server_is_session_id() {
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]
}

# Strip one or more trailing slashes, keeping a bare `/`.
_gaia_server_strip_trailing_slash() {
  local path="$1"
  while [ "${#path}" -gt 1 ] && [ "${path%/}" != "$path" ]; do
    path="${path%/}"
  done
  printf '%s' "$path"
}

# Physical path of an existing directory, else the argument unchanged (a
# removed tree has nothing left to resolve).
_gaia_server_physical_or_literal() {
  local path resolved
  path="$(_gaia_server_strip_trailing_slash "$1")"
  if [ -d "$path" ] && resolved="$(cd -P "$path" 2>/dev/null && pwd -P)" && [ -n "$resolved" ]; then
    printf '%s' "$resolved"
  else
    printf '%s' "$path"
  fi
}

# rc 0 when $1 is $2 or sits below it, on a path-segment boundary, so a tree
# at /x/tree never claims /x/tree-2.
_gaia_server_path_is_under() {
  local path="$1" root
  root="$(_gaia_server_strip_trailing_slash "$2")"
  [ -n "$root" ] || return 1
  [ "$path" = "$root" ] && return 0
  [ "$root" = "/" ] && return 0
  case "$path" in
    "$root"/*) return 0 ;;
  esac
  return 1
}

# The inode of a path, GNU stat first: BSD rejects `-c`, while GNU accepts
# `-f` as "filesystem status" and would print the wrong number.
_gaia_server_inode() {
  local inode
  inode="$(stat -c %i "$1" 2>/dev/null)" || inode=""
  if ! _gaia_server_is_integer "$inode"; then
    inode="$(stat -f %i "$1" 2>/dev/null)" || inode=""
  fi
  _gaia_server_is_integer "$inode" || return 1
  printf '%s' "$inode"
}

# Prints the backend for a capability (`listeners` or `cwds`): lsof, proc, or
# none.
_gaia_server_backend() {
  local capability="$1" requested="${GAIA_PORTS_PROCESS_PROBE:-auto}"
  local lsof_available=0 proc_available=0
  command -v lsof >/dev/null 2>&1 && lsof_available=1
  if [ -e /proc/self ]; then
    if [ "$capability" = "listeners" ]; then
      command -v ss >/dev/null 2>&1 && proc_available=1
    else
      proc_available=1
    fi
  fi
  case "$requested" in
    lsof)
      [ "$lsof_available" -eq 1 ] && { printf 'lsof'; return 0; }
      ;;
    proc)
      [ "$proc_available" -eq 1 ] && { printf 'proc'; return 0; }
      ;;
    auto)
      [ "$lsof_available" -eq 1 ] && { printf 'lsof'; return 0; }
      [ "$proc_available" -eq 1 ] && { printf 'proc'; return 0; }
      ;;
    *)
      _gaia_server_diagnostic "unrecognized GAIA_PORTS_PROCESS_PROBE '$requested' (expected auto, lsof, or proc); no backend used"
      ;;
  esac
  printf 'none'
}

# rc 0 when the port is in the space-separated list.
_gaia_server_port_listed() {
  case " $2 " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# gaia_server_listeners <port>...: `<port>\t<pid>` per TCP listener on any
# listed port, IPv4 and IPv6, from one probe. rc 3 when no backend exists.
gaia_server_listeners() {
  local port wanted_ports="" lsof_port_list=""
  for port in "$@"; do
    if ! _gaia_server_is_port "$port"; then
      _gaia_server_diagnostic "ignoring invalid port '$port'"
      continue
    fi
    _gaia_server_port_listed "$port" "$wanted_ports" && continue
    wanted_ports="$wanted_ports $port"
    lsof_port_list="${lsof_port_list:+$lsof_port_list,}$port"
  done
  local backend
  backend="$(_gaia_server_backend listeners)"
  [ "$backend" = "none" ] && return 3
  [ -n "$wanted_ports" ] || return 0

  local raw_output
  if [ "$backend" = "lsof" ]; then
    # lsof exits 1 when nothing matches, so its status cannot tell "no
    # listener" from a failure; the parsed output is the answer.
    raw_output="$(lsof -nP "-iTCP:$lsof_port_list" -sTCP:LISTEN -Fpn 2>/dev/null)" || true
  else
    raw_output="$(ss -ltnpH 2>/dev/null)" || {
      _gaia_server_diagnostic "ss -ltnpH failed; listeners unknown"
      return 3
    }
  fi

  local seen=" " line current_pid="" address listener_port pid_list pid remainder
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ "$backend" = "lsof" ]; then
      case "$line" in
        p*) current_pid="${line#p}" ;;
        n*)
          address="${line#n}"
          listener_port="${address##*:}"
          _gaia_server_is_integer "$current_pid" || continue
          _gaia_server_port_listed "$listener_port" "$wanted_ports" || continue
          case "$seen" in *" $listener_port:$current_pid "*) continue ;; esac
          seen="$seen$listener_port:$current_pid "
          printf '%s\t%s\n' "$listener_port" "$current_pid"
          ;;
      esac
    else
      # ss -H fields: state, receive queue, send queue, local address, peer
      # address, process. The port follows the local address's last colon.
      read -r _ _ _ address _ <<<"$line"
      listener_port="${address##*:}"
      _gaia_server_port_listed "$listener_port" "$wanted_ports" || continue
      pid_list=""
      remainder="$line"
      while :; do
        case "$remainder" in
          *pid=*) ;;
          *) break ;;
        esac
        remainder="${remainder#*pid=}"
        pid="${remainder%%[!0-9]*}"
        _gaia_server_is_integer "$pid" && pid_list="$pid_list $pid"
      done
      [ -n "$pid_list" ] || pid_list=" 0"
      for pid in $pid_list; do
        case "$seen" in *" $listener_port:$pid "*) continue ;; esac
        seen="$seen$listener_port:$pid "
        printf '%s\t%s\n' "$listener_port" "$pid"
      done
    fi
  done <<EOF
$raw_output
EOF
  return 0
}

# rc 0 when the process exists and is not a zombie (a zombie has exited; only
# its parent has not reaped it yet).
_gaia_server_pid_alive() {
  _gaia_server_is_integer "$1" || return 1
  local process_state
  process_state="$(LC_ALL=C ps -o stat= -p "$1" 2>/dev/null)" || return 1
  process_state="${process_state#"${process_state%%[! ]*}"}"
  [ -n "$process_state" ] || return 1
  case "$process_state" in
    Z*) return 1 ;;
  esac
  return 0
}

# gaia_server_process_identity <pid>: `<start>\t<command>`, the start time
# with whitespace runs collapsed and the command with tabs and newlines turned
# to spaces. rc 1 when the process is gone or unreadable.
gaia_server_process_identity() {
  local pid="$1"
  _gaia_server_is_integer "$pid" || return 1
  [ "$pid" -ge 1 ] || return 1
  _gaia_server_pid_alive "$pid" || return 1
  local start command
  start="$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null)" || return 1
  # Unquoted on purpose: word splitting is what collapses whitespace runs.
  # shellcheck disable=SC2086
  start="$(printf '%s ' $start)"
  start="${start% }"
  [ -n "$start" ] || return 1
  command="$(LC_ALL=C ps -o command= -p "$pid" 2>/dev/null)" || return 1
  command="$(printf '%s' "$command" | tr '\t\n' '  ')"
  command="${command%"${command##*[! ]}"}"
  [ -n "$command" ] || return 1
  printf '%s\t%s\n' "$start" "$command"
}

# Classifies one reported working directory. Args: the reported path, the
# inode the backend reported for it (empty when it reported none). Prints
# `<cwd>\t<state>`.
_gaia_server_classify_cwd() {
  local reported_path="$1" reported_inode="$2" current_inode
  case "$reported_path" in
    *' (deleted)')
      printf '%s\tdeleted\n' "${reported_path% (deleted)}"
      return 0
      ;;
    /*) ;;
    *)
      printf 'unknown\tunknown\n'
      return 0
      ;;
  esac
  if [ ! -e "$reported_path" ]; then
    printf '%s\tdeleted\n' "$reported_path"
    return 0
  fi
  if ! _gaia_server_is_integer "$reported_inode"; then
    printf 'unknown\tunknown\n'
    return 0
  fi
  if ! current_inode="$(_gaia_server_inode "$reported_path")"; then
    printf 'unknown\tunknown\n'
    return 0
  fi
  if [ "$current_inode" = "$reported_inode" ]; then
    printf '%s\tlive\n' "$reported_path"
  else
    printf '%s\tdeleted\n' "$reported_path"
  fi
}

# gaia_server_process_cwds <pid>...: `<pid>\t<cwd>\t<state>` per pid, from one
# batched lookup. state is live, deleted, or unknown; an unknown entry prints
# `unknown` in the cwd field too.
gaia_server_process_cwds() {
  local pid valid_pids="" lsof_pid_list=""
  for pid in "$@"; do
    if _gaia_server_is_integer "$pid" && [ "$pid" -ge 1 ]; then
      valid_pids="$valid_pids $pid"
      lsof_pid_list="${lsof_pid_list:+$lsof_pid_list,}$pid"
    else
      printf '%s\tunknown\tunknown\n' "$pid"
    fi
  done
  [ -n "$valid_pids" ] || return 0

  local backend
  backend="$(_gaia_server_backend cwds)"
  if [ "$backend" = "none" ]; then
    for pid in $valid_pids; do
      printf '%s\tunknown\tunknown\n' "$pid"
    done
    return 0
  fi

  local reported_pids="" reported_paths="" reported_inodes=""
  local reported_path reported_inode
  if [ "$backend" = "lsof" ]; then
    local raw_output line current_pid="" current_path="" current_inode=""
    raw_output="$(lsof -a -d cwd -p "$lsof_pid_list" -Fpin 2>/dev/null)" || true
    # Records are collected into three parallel newline-separated lists, then
    # matched per requested pid below; bash 3.2 has no associative arrays.
    while IFS= read -r line; do
      case "$line" in
        p*)
          if _gaia_server_is_integer "$current_pid"; then
            reported_pids="$reported_pids$current_pid$_gaia_server_tab"
            reported_paths="$reported_paths$current_path$_gaia_server_tab"
            reported_inodes="$reported_inodes$current_inode$_gaia_server_tab"
          fi
          current_pid="${line#p}"
          current_path=""
          current_inode=""
          ;;
        i*) current_inode="${line#i}" ;;
        n*) current_path="${line#n}" ;;
      esac
    done <<EOF
$raw_output
EOF
    if _gaia_server_is_integer "$current_pid"; then
      reported_pids="$reported_pids$current_pid$_gaia_server_tab"
      reported_paths="$reported_paths$current_path$_gaia_server_tab"
      reported_inodes="$reported_inodes$current_inode$_gaia_server_tab"
    fi
    for pid in $valid_pids; do
      local remaining_pids="$reported_pids" remaining_paths="$reported_paths" remaining_inodes="$reported_inodes"
      local candidate_pid found=0
      reported_path=""
      reported_inode=""
      while [ -n "$remaining_pids" ]; do
        candidate_pid="${remaining_pids%%"$_gaia_server_tab"*}"
        remaining_pids="${remaining_pids#*"$_gaia_server_tab"}"
        reported_path="${remaining_paths%%"$_gaia_server_tab"*}"
        remaining_paths="${remaining_paths#*"$_gaia_server_tab"}"
        reported_inode="${remaining_inodes%%"$_gaia_server_tab"*}"
        remaining_inodes="${remaining_inodes#*"$_gaia_server_tab"}"
        if [ "$candidate_pid" = "$pid" ]; then
          found=1
          break
        fi
      done
      if [ "$found" -eq 1 ] && [ -n "$reported_path" ]; then
        printf '%s\t%s\n' "$pid" "$(_gaia_server_classify_cwd "$reported_path" "$reported_inode")"
      else
        printf '%s\tunknown\tunknown\n' "$pid"
      fi
    done
  else
    for pid in $valid_pids; do
      reported_path="$(readlink "/proc/$pid/cwd" 2>/dev/null)" || reported_path=""
      if [ -z "$reported_path" ]; then
        printf '%s\tunknown\tunknown\n' "$pid"
        continue
      fi
      reported_inode="$(stat -L -c %i "/proc/$pid/cwd" 2>/dev/null)" || reported_inode=""
      printf '%s\t%s\n' "$pid" "$(_gaia_server_classify_cwd "$reported_path" "$reported_inode")"
    done
  fi
  return 0
}

# gaia_server_owning_tree <cwd>: the nearest enclosing directory holding a
# `.git` file or directory, physically resolved. A linked worktree nested
# inside the main checkout owns its own servers. rc 1 when the cwd does not
# exist or no ancestor holds `.git`.
gaia_server_owning_tree() {
  local directory
  [ -d "$1" ] || return 1
  directory="$(cd -P "$1" 2>/dev/null && pwd -P)" || return 1
  [ -n "$directory" ] || return 1
  while :; do
    if [ -e "$directory/.git" ]; then
      printf '%s\n' "$directory"
      return 0
    fi
    [ "$directory" = "/" ] && return 1
    directory="${directory%/*}"
    [ -n "$directory" ] || directory="/"
  done
}

# gaia_server_listener_owner <port> <tree-root>: exactly one of `free`,
# `own <pid>`, `foreign <pid> <cwd>`, `foreign <pid> unknown`, `unknown`.
# With several listeners on the port, any non-own listener is the answer.
# Always rc 0.
gaia_server_listener_owner() {
  local port="$1" tree_root listeners listeners_status
  tree_root="$(_gaia_server_physical_or_literal "$2")"
  listeners="$(gaia_server_listeners "$port")"
  listeners_status=$?
  if [ "$listeners_status" -ne 0 ]; then
    printf 'unknown\n'
    return 0
  fi
  if [ -z "$listeners" ]; then
    printf 'free\n'
    return 0
  fi

  local pid_list="" listener_port listener_pid
  while IFS="$_gaia_server_tab" read -r listener_port listener_pid; do
    [ -n "$listener_pid" ] && pid_list="$pid_list $listener_pid"
  done <<EOF
$listeners
EOF
  local cwd_report
  # shellcheck disable=SC2086
  cwd_report="$(gaia_server_process_cwds $pid_list)"

  local first_own="" first_foreign="" cwd_pid cwd_path cwd_state owning_tree
  while IFS="$_gaia_server_tab" read -r cwd_pid cwd_path cwd_state; do
    [ -n "$cwd_pid" ] || continue
    if [ "$cwd_state" = "live" ] && owning_tree="$(gaia_server_owning_tree "$cwd_path")" && [ "$owning_tree" = "$tree_root" ]; then
      [ -n "$first_own" ] || first_own="own $cwd_pid"
      continue
    fi
    if [ -z "$first_foreign" ]; then
      if [ "$cwd_state" = "unknown" ]; then
        first_foreign="foreign $cwd_pid unknown"
      else
        first_foreign="foreign $cwd_pid $cwd_path"
      fi
    fi
  done <<EOF
$cwd_report
EOF
  if [ -n "$first_foreign" ]; then
    printf '%s\n' "$first_foreign"
  elif [ -n "$first_own" ]; then
    printf '%s\n' "$first_own"
  else
    printf 'foreign 0 unknown\n'
  fi
  return 0
}

# rc 0 when pid is this process, the subshell running this code, or any
# ancestor of either. Unreadable ancestry counts as an ancestor (refuse).
_gaia_server_is_caller_or_ancestor() {
  local target_pid="$1" walk_pid parent_pid step=0
  [ "$target_pid" = "$$" ] && return 0
  [ -n "${BASHPID:-}" ] && [ "$target_pid" = "$BASHPID" ] && return 0
  walk_pid="${BASHPID:-$$}"
  while [ "$step" -lt "$_gaia_server_ancestry_step_limit" ]; do
    parent_pid="$(ps -o ppid= -p "$walk_pid" 2>/dev/null)" || return 0
    parent_pid="${parent_pid//[!0-9]/}"
    _gaia_server_is_integer "$parent_pid" || return 0
    [ "$parent_pid" = "$target_pid" ] && return 0
    [ "$parent_pid" -le 1 ] && return 1
    walk_pid="$parent_pid"
    step=$((step + 1))
  done
  return 0
}

# rc 0 when every recorded field still matches the live process: start,
# command, a readable cwd under the prefix, and a listener on the port.
_gaia_server_identity_matches() {
  local pid="$1" expected_start="$2" expected_command="$3" cwd_prefix="$4" port="$5"
  local identity current_start current_command
  identity="$(gaia_server_process_identity "$pid")" || return 1
  current_start="${identity%%"$_gaia_server_tab"*}"
  current_command="${identity#*"$_gaia_server_tab"}"
  [ "$current_start" = "$expected_start" ] || return 1
  [ "$current_command" = "$expected_command" ] || return 1

  local cwd_line cwd_path cwd_state resolved_prefix
  cwd_line="$(gaia_server_process_cwds "$pid")"
  cwd_path="$(printf '%s' "$cwd_line" | cut -f2)"
  cwd_state="$(printf '%s' "$cwd_line" | cut -f3)"
  [ "$cwd_state" = "live" ] || [ "$cwd_state" = "deleted" ] || return 1
  resolved_prefix="$(_gaia_server_physical_or_literal "$cwd_prefix")"
  _gaia_server_path_is_under "$cwd_path" "$cwd_prefix" || _gaia_server_path_is_under "$cwd_path" "$resolved_prefix" || return 1

  local listeners listener_port listener_pid listening=0
  listeners="$(gaia_server_listeners "$port")" || return 1
  while IFS="$_gaia_server_tab" read -r listener_port listener_pid; do
    [ "$listener_pid" = "$pid" ] && listening=1
  done <<EOF
$listeners
EOF
  [ "$listening" -eq 1 ]
}

# Polls up to the given tenths of a second for the pid to exit. rc 0 gone.
_gaia_server_wait_for_exit() {
  local pid="$1" tenths="$2" waited=0
  while [ "$waited" -lt "$tenths" ]; do
    _gaia_server_pid_alive "$pid" || return 0
    sleep 0.1
    waited=$((waited + 1))
  done
  _gaia_server_pid_alive "$pid" && return 1
  return 0
}

# gaia_server_stop_verified <pid> <start> <command> <cwd-prefix> <port>:
# re-reads every field immediately before each signal and skips on any
# mismatch. SIGTERM, a bounded wait, re-verify, SIGKILL only if still
# matching. Never signals pid <= 1, the caller, or an ancestor of the caller.
# rc 0 stopped, 1 skipped, 2 already gone.
gaia_server_stop_verified() {
  local pid="$1" expected_start="$2" expected_command="$3" cwd_prefix="$4" port="$5"
  if ! _gaia_server_is_integer "$pid" || [ "$pid" -le 1 ]; then
    _gaia_server_diagnostic "refusing to signal pid '$pid'"
    return 1
  fi
  if _gaia_server_is_caller_or_ancestor "$pid"; then
    _gaia_server_diagnostic "refusing to signal pid $pid: it is this process or one of its ancestors"
    return 1
  fi
  if ! _gaia_server_is_port "$port" || [ -z "$expected_start" ] || [ -z "$expected_command" ] || [ -z "$cwd_prefix" ]; then
    _gaia_server_diagnostic "refusing to signal pid $pid: incomplete identity"
    return 1
  fi
  _gaia_server_pid_alive "$pid" || return 2
  _gaia_server_identity_matches "$pid" "$expected_start" "$expected_command" "$cwd_prefix" "$port" || return 1

  kill -TERM "$pid" 2>/dev/null || {
    _gaia_server_pid_alive "$pid" || return 0
    _gaia_server_diagnostic "SIGTERM to pid $pid failed"
    return 1
  }
  _gaia_server_wait_for_exit "$pid" "$_gaia_server_stop_wait_tenths" && return 0

  if ! _gaia_server_identity_matches "$pid" "$expected_start" "$expected_command" "$cwd_prefix" "$port"; then
    _gaia_server_diagnostic "pid $pid outlived SIGTERM and no longer matches its identity; not sending SIGKILL"
    return 1
  fi
  kill -KILL "$pid" 2>/dev/null || true
  _gaia_server_wait_for_exit "$pid" 10 && return 0
  _gaia_server_diagnostic "pid $pid survived SIGKILL"
  return 1
}

# Prints `<port>\t<pid>\t<start>\t<command>` for each listener on the ports
# that qualifies for a removed-tree stop: readable cwd under the tree root,
# no other tree nested between them, and the tree directory missing or the
# cwd deleted.
_gaia_server_removed_tree_candidates() {
  local tree_root tree_missing=0
  tree_root="$(_gaia_server_strip_trailing_slash "$1")"
  shift
  case "$tree_root" in
    /?*) ;;
    *) return 0 ;;
  esac
  [ -d "$tree_root" ] || tree_missing=1

  local listeners
  listeners="$(gaia_server_listeners "$@")" || return 0
  [ -n "$listeners" ] || return 0

  local pid_list="" listener_port listener_pid
  while IFS="$_gaia_server_tab" read -r listener_port listener_pid; do
    [ -n "$listener_pid" ] && pid_list="$pid_list $listener_pid"
  done <<EOF
$listeners
EOF
  local cwd_report
  # shellcheck disable=SC2086
  cwd_report="$(gaia_server_process_cwds $pid_list)"

  local cwd_pid cwd_path cwd_state identity nested directory
  while IFS="$_gaia_server_tab" read -r listener_port listener_pid; do
    _gaia_server_is_integer "$listener_pid" || continue
    [ "$listener_pid" -gt 1 ] || continue
    cwd_path=""
    cwd_state="unknown"
    while IFS="$_gaia_server_tab" read -r cwd_pid cwd_path cwd_state; do
      [ "$cwd_pid" = "$listener_pid" ] && break
      cwd_path=""
      cwd_state="unknown"
    done <<EOF
$cwd_report
EOF
    [ "$cwd_state" = "live" ] || [ "$cwd_state" = "deleted" ] || continue
    _gaia_server_path_is_under "$cwd_path" "$tree_root" || continue
    [ "$tree_missing" -eq 1 ] || [ "$cwd_state" = "deleted" ] || continue
    # A live checkout between the tree root and the cwd owns that cwd; the
    # attribution is ambiguous, so refuse.
    nested=0
    directory="$cwd_path"
    while [ "$directory" != "$tree_root" ] && [ "${#directory}" -gt "${#tree_root}" ]; do
      if [ -e "$directory/.git" ]; then
        nested=1
        break
      fi
      directory="${directory%/*}"
    done
    [ "$nested" -eq 0 ] || continue
    identity="$(gaia_server_process_identity "$listener_pid")" || continue
    printf '%s\t%s\t%s\n' "$listener_port" "$listener_pid" "$identity"
  done <<EOF
$listeners
EOF
  return 0
}

# gaia_server_stop_removed_tree_listeners <tree-root> <port>...: stops each
# qualifying listener through the verified stop and prints one removed-tree
# report per stop. Unreadable or ambiguous cwd never stops.
gaia_server_stop_removed_tree_listeners() {
  local tree_root candidates
  tree_root="$(_gaia_server_strip_trailing_slash "$1")"
  shift
  candidates="$(_gaia_server_removed_tree_candidates "$tree_root" "$@")"
  [ -n "$candidates" ] || return 0
  local candidate_port candidate_pid candidate_start candidate_command stop_status
  while IFS="$_gaia_server_tab" read -r candidate_port candidate_pid candidate_start candidate_command; do
    [ -n "$candidate_pid" ] || continue
    gaia_server_stop_verified "$candidate_pid" "$candidate_start" "$candidate_command" "$tree_root" "$candidate_port"
    stop_status=$?
    if [ "$stop_status" -eq 0 ]; then
      printf 'GAIA stopped a server on port %s (PID %s) left running from removed worktree %s.\n' "$candidate_port" "$candidate_pid" "$tree_root"
    fi
  done <<EOF
$candidates
EOF
  return 0
}

# The session host: the first ancestor of the caller's parent that is not a
# plain shell or `env`.
_gaia_server_discover_host_pid() {
  local walk_pid="$PPID" step=0 line parent_pid command_name
  while [ "$step" -lt "$_gaia_server_ancestry_step_limit" ]; do
    _gaia_server_is_integer "$walk_pid" || return 1
    [ "$walk_pid" -gt 1 ] || return 1
    line="$(LC_ALL=C ps -o ppid=,comm= -p "$walk_pid" 2>/dev/null)" || return 1
    line="${line#"${line%%[! ]*}"}"
    parent_pid="${line%% *}"
    command_name="${line#* }"
    command_name="${command_name#"${command_name%%[! ]*}"}"
    command_name="${command_name##*/}"
    command_name="${command_name#-}"
    case "$command_name" in
      sh | bash | zsh | dash | env) ;;
      *)
        printf '%s' "$walk_pid"
        return 0
        ;;
    esac
    walk_pid="$parent_pid"
    step=$((step + 1))
  done
  return 1
}

# Writes content to a file through a temporary file in the same directory.
_gaia_server_write_atomic() {
  local target="$1" content="$2" temporary
  temporary="$target.tmp.$$"
  printf '%s\n' "$content" >"$temporary" 2>/dev/null || {
    rm -f "$temporary"
    return 1
  }
  mv -f "$temporary" "$target" 2>/dev/null || {
    rm -f "$temporary"
    return 1
  }
}

# gaia_server_session_register <state-directory> <session-id> [<host-pid>]:
# records the session's host process. The third argument, then
# GAIA_PORTS_HOST_PID, override discovery. Writes only when the host changed.
gaia_server_session_register() {
  local state_directory="$1" session_id="$2" host_pid="${3:-${GAIA_PORTS_HOST_PID:-}}"
  if [ -z "$state_directory" ]; then
    _gaia_server_diagnostic "session register: no state directory"
    return 1
  fi
  if ! _gaia_server_is_session_id "$session_id"; then
    _gaia_server_diagnostic "session register: invalid session id"
    return 1
  fi
  if [ -z "$host_pid" ]; then
    host_pid="$(_gaia_server_discover_host_pid)" || host_pid=""
  fi
  if ! _gaia_server_is_integer "$host_pid" || [ "$host_pid" -le 1 ]; then
    _gaia_server_diagnostic "session register: no session host found"
    return 1
  fi
  local identity
  identity="$(gaia_server_process_identity "$host_pid")" || {
    _gaia_server_diagnostic "session register: host pid $host_pid is not readable"
    return 1
  }
  mkdir -p "$state_directory/sessions" 2>/dev/null || return 1
  local session_file="$state_directory/sessions/$session_id.tsv" existing=""
  if [ -f "$session_file" ]; then
    IFS= read -r existing <"$session_file" || true
  fi
  local host_record="$host_pid$_gaia_server_tab$identity"
  case "$existing" in
    "$host_record$_gaia_server_tab"*) return 0 ;;
  esac
  _gaia_server_write_atomic "$session_file" "$host_record$_gaia_server_tab$(date +%s)"
}

# gaia_server_host_alive <host-pid> <host-start>: rc 0 when the host is alive
# and its start time still matches.
gaia_server_host_alive() {
  local identity
  _gaia_server_is_integer "$1" || return 1
  [ "$1" -gt 1 ] || return 1
  kill -0 "$1" 2>/dev/null || _gaia_server_pid_alive "$1" || return 1
  identity="$(gaia_server_process_identity "$1")" || return 1
  [ "${identity%%"$_gaia_server_tab"*}" = "$2" ]
}

# Prints `<host-pid>\t<host-start>` from a session file; rc 1 when malformed.
_gaia_server_read_session_host() {
  local line host_pid host_start
  [ -f "$1" ] || return 1
  IFS= read -r line <"$1" || [ -n "$line" ] || return 1
  host_pid="${line%%"$_gaia_server_tab"*}"
  line="${line#*"$_gaia_server_tab"}"
  host_start="${line%%"$_gaia_server_tab"*}"
  _gaia_server_is_integer "$host_pid" || return 1
  [ -n "$host_start" ] || return 1
  printf '%s\t%s\n' "$host_pid" "$host_start"
}

# gaia_server_record_launch <state-directory> <pid> <port> <kind> <tree-root>:
# records a server launched by a live Claude session, attributed by process
# ancestry, falling back to sessions/$CLAUDE_CODE_SESSION_ID.tsv when the
# chain was broken by reparenting. Never probes a port. rc 0 whether or not a
# record was written; rc 1 on invalid arguments.
gaia_server_record_launch() {
  local state_directory="$1" pid="$2" port="$3" kind="$4" tree_root="$5"
  if [ -z "$state_directory" ] || ! _gaia_server_is_integer "$pid" || [ "$pid" -le 1 ] || ! _gaia_server_is_port "$port"; then
    _gaia_server_diagnostic "record launch: invalid state directory, pid, or port"
    return 1
  fi
  case "$kind" in
    dev | storybook) ;;
    *)
      _gaia_server_diagnostic "record launch: kind must be dev or storybook"
      return 1
      ;;
  esac
  case "$tree_root" in
    /*) ;;
    *)
      _gaia_server_diagnostic "record launch: tree root must be absolute"
      return 1
      ;;
  esac
  tree_root="$(_gaia_server_physical_or_literal "$tree_root")"

  local identity
  identity="$(gaia_server_process_identity "$pid")" || return 0

  local session_id="" host_pid="" host_start="" session_file session_host
  local ancestor_pid parent_pid step=0 candidate_host_pid candidate_host_start
  ancestor_pid="$pid"
  if [ -d "$state_directory/sessions" ]; then
    while [ "$step" -lt "$_gaia_server_ancestry_step_limit" ] && [ -z "$session_id" ]; do
      parent_pid="$(ps -o ppid= -p "$ancestor_pid" 2>/dev/null)" || break
      parent_pid="${parent_pid//[!0-9]/}"
      _gaia_server_is_integer "$parent_pid" || break
      [ "$parent_pid" -gt 1 ] || break
      for session_file in "$state_directory"/sessions/*.tsv; do
        [ -f "$session_file" ] || continue
        session_host="$(_gaia_server_read_session_host "$session_file")" || continue
        candidate_host_pid="${session_host%%"$_gaia_server_tab"*}"
        candidate_host_start="${session_host#*"$_gaia_server_tab"}"
        [ "$candidate_host_pid" = "$parent_pid" ] || continue
        gaia_server_host_alive "$candidate_host_pid" "$candidate_host_start" || continue
        session_id="${session_file##*/}"
        session_id="${session_id%.tsv}"
        _gaia_server_is_session_id "$session_id" || { session_id=""; continue; }
        host_pid="$candidate_host_pid"
        host_start="$candidate_host_start"
        break
      done
      ancestor_pid="$parent_pid"
      step=$((step + 1))
    done
  fi

  if [ -z "$session_id" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    if _gaia_server_is_session_id "$CLAUDE_CODE_SESSION_ID"; then
      session_file="$state_directory/sessions/$CLAUDE_CODE_SESSION_ID.tsv"
      if session_host="$(_gaia_server_read_session_host "$session_file")"; then
        candidate_host_pid="${session_host%%"$_gaia_server_tab"*}"
        candidate_host_start="${session_host#*"$_gaia_server_tab"}"
        if gaia_server_host_alive "$candidate_host_pid" "$candidate_host_start"; then
          session_id="$CLAUDE_CODE_SESSION_ID"
          host_pid="$candidate_host_pid"
          host_start="$candidate_host_start"
        fi
      fi
    else
      _gaia_server_diagnostic "record launch: ignoring invalid CLAUDE_CODE_SESSION_ID"
    fi
  fi
  [ -n "$session_id" ] || return 0

  local cwd_line cwd_path cwd_state
  cwd_line="$(gaia_server_process_cwds "$pid")"
  cwd_path="$(printf '%s' "$cwd_line" | cut -f2)"
  cwd_state="$(printf '%s' "$cwd_line" | cut -f3)"
  if [ "$cwd_state" != "live" ]; then
    _gaia_server_diagnostic "record launch: working directory of pid $pid is not readable; not recorded"
    return 0
  fi

  mkdir -p "$state_directory/launches" 2>/dev/null || return 0
  _gaia_server_write_atomic "$state_directory/launches/$pid.tsv" \
    "$pid$_gaia_server_tab$identity$_gaia_server_tab$cwd_path$_gaia_server_tab$port$_gaia_server_tab$kind$_gaia_server_tab$session_id$_gaia_server_tab$host_pid$_gaia_server_tab$host_start$_gaia_server_tab$tree_root" || true
  return 0
}

# Reads a launch record into the _gaia_server_record_* variables. rc 1 when
# malformed or when the pid field disagrees with the file name.
_gaia_server_read_launch_record() {
  local record_file="$1" line file_pid
  _gaia_server_record_pid=""
  _gaia_server_record_start=""
  _gaia_server_record_command=""
  _gaia_server_record_cwd=""
  _gaia_server_record_port=""
  _gaia_server_record_kind=""
  _gaia_server_record_session=""
  _gaia_server_record_host_pid=""
  _gaia_server_record_host_start=""
  _gaia_server_record_tree=""
  [ -f "$record_file" ] || return 1
  IFS= read -r line <"$record_file" || [ -n "$line" ] || return 1
  IFS="$_gaia_server_tab" read -r _gaia_server_record_pid _gaia_server_record_start _gaia_server_record_command \
    _gaia_server_record_cwd _gaia_server_record_port _gaia_server_record_kind _gaia_server_record_session \
    _gaia_server_record_host_pid _gaia_server_record_host_start _gaia_server_record_tree <<EOF
$line
EOF
  file_pid="${record_file##*/}"
  file_pid="${file_pid%.tsv}"
  _gaia_server_is_integer "$_gaia_server_record_pid" || return 1
  [ "$file_pid" = "$_gaia_server_record_pid" ] || return 1
  _gaia_server_is_port "$_gaia_server_record_port" || return 1
  _gaia_server_is_integer "$_gaia_server_record_host_pid" || return 1
  [ -n "$_gaia_server_record_tree" ] || return 1
  return 0
}

# gaia_server_cleanup_needed <state-directory>: rc 0 when a reap has work: a
# slots.tsv entry whose directory is missing, any tombstone, or a launch
# record whose host is not alive. Reads files and `ps` only; never lsof or ss.
gaia_server_cleanup_needed() {
  local state_directory="$1" tree_root record_file
  [ -n "$state_directory" ] && [ -d "$state_directory" ] || return 1
  if [ -f "$state_directory/slots.tsv" ]; then
    while IFS="$_gaia_server_tab" read -r _ tree_root _; do
      [ -n "$tree_root" ] || continue
      [ -d "$tree_root" ] || return 0
    done <"$state_directory/slots.tsv"
  fi
  for record_file in "$state_directory"/tombstones/*.tsv; do
    [ -e "$record_file" ] && return 0
  done
  for record_file in "$state_directory"/launches/*.tsv; do
    [ -f "$record_file" ] || continue
    # A malformed record is work too: the reap deletes it.
    _gaia_server_read_launch_record "$record_file" || return 0
    gaia_server_host_alive "$_gaia_server_record_host_pid" "$_gaia_server_record_host_start" || return 0
  done
  return 1
}

# gaia_server_reap_dead_sessions <state-directory>: stops the servers of
# launch records whose session host has died, after verifying identity; drops
# records whose process is gone or no longer matches; then drops session files
# whose host is dead and which no launch record names.
gaia_server_reap_dead_sessions() {
  local state_directory="$1" record_file identity stop_status
  [ -n "$state_directory" ] && [ -d "$state_directory" ] || return 0
  # Without a backend a matching process could never be verified, so keep
  # every record for a later pass that can.
  if [ "$(_gaia_server_backend listeners)" = "none" ] || [ "$(_gaia_server_backend cwds)" = "none" ]; then
    return 0
  fi
  for record_file in "$state_directory"/launches/*.tsv; do
    [ -f "$record_file" ] || continue
    if ! _gaia_server_read_launch_record "$record_file"; then
      _gaia_server_diagnostic "dropping malformed launch record ${record_file##*/}"
      rm -f "$record_file"
      continue
    fi
    gaia_server_host_alive "$_gaia_server_record_host_pid" "$_gaia_server_record_host_start" && continue
    identity="$(gaia_server_process_identity "$_gaia_server_record_pid")" || {
      rm -f "$record_file"
      continue
    }
    if [ "$identity" != "$_gaia_server_record_start$_gaia_server_tab$_gaia_server_record_command" ]; then
      rm -f "$record_file"
      continue
    fi
    gaia_server_stop_verified "$_gaia_server_record_pid" "$_gaia_server_record_start" "$_gaia_server_record_command" \
      "$_gaia_server_record_cwd" "$_gaia_server_record_port"
    stop_status=$?
    if [ "$stop_status" -eq 0 ]; then
      printf 'GAIA stopped a %s server on port %s (PID %s) launched by an ended Claude session in %s.\n' \
        "$_gaia_server_record_kind" "$_gaia_server_record_port" "$_gaia_server_record_pid" "$_gaia_server_record_tree"
    fi
    rm -f "$record_file"
  done

  local session_file session_id session_host named
  for session_file in "$state_directory"/sessions/*.tsv; do
    [ -f "$session_file" ] || continue
    if session_host="$(_gaia_server_read_session_host "$session_file")" &&
      gaia_server_host_alive "${session_host%%"$_gaia_server_tab"*}" "${session_host#*"$_gaia_server_tab"}"; then
      continue
    fi
    session_id="${session_file##*/}"
    session_id="${session_id%.tsv}"
    named=0
    for record_file in "$state_directory"/launches/*.tsv; do
      [ -f "$record_file" ] || continue
      _gaia_server_read_launch_record "$record_file" || continue
      if [ "$_gaia_server_record_session" = "$session_id" ]; then
        named=1
        break
      fi
    done
    [ "$named" -eq 0 ] && rm -f "$session_file"
  done
  return 0
}

_gaia_server_base_port() {
  local value="$1" default="$2"
  if _gaia_server_is_port "$value"; then
    printf '%s' "$value"
  else
    printf '%s' "$default"
  fi
}

# gaia_server_reap_tombstones <state-directory>: per tombstone, stops the
# removed tree's qualifying listeners on its slot's dev and Storybook ports,
# drops that tree's launch records whose process is gone or no longer
# matches, deletes the tombstone once nothing qualifies, and only then
# applies the age expiry to the tombstones still standing.
gaia_server_reap_tombstones() {
  local state_directory="$1"
  [ -n "$state_directory" ] && [ -d "$state_directory" ] || return 0
  local dev_base storybook_base backend_available=1
  dev_base="$(_gaia_server_base_port "${GAIA_PORTS_DEV_BASE_PORT:-}" 5173)"
  storybook_base="$(_gaia_server_base_port "${GAIA_PORTS_STORYBOOK_BASE_PORT:-}" 6006)"
  if [ "$(_gaia_server_backend listeners)" = "none" ] || [ "$(_gaia_server_backend cwds)" = "none" ]; then
    backend_available=0
  fi

  local tombstone_file line slot tree_root reclaimed_epoch dev_port storybook_port
  local record_file identity now remaining
  for tombstone_file in "$state_directory"/tombstones/*.tsv; do
    [ -f "$tombstone_file" ] || continue
    line=""
    IFS= read -r line <"$tombstone_file" || true
    IFS="$_gaia_server_tab" read -r slot tree_root reclaimed_epoch <<EOF
$line
EOF
    tree_root="$(_gaia_server_strip_trailing_slash "$tree_root")"
    if ! _gaia_server_is_integer "$slot" || ! _gaia_server_is_integer "$reclaimed_epoch" || [ "${tree_root#/}" = "$tree_root" ] || [ "$tree_root" = "/" ]; then
      _gaia_server_diagnostic "dropping malformed tombstone ${tombstone_file##*/}"
      rm -f "$tombstone_file"
      continue
    fi
    dev_port=$((dev_base + slot))
    storybook_port=$((storybook_base + slot))

    if [ "$backend_available" -eq 1 ]; then
      gaia_server_stop_removed_tree_listeners "$tree_root" "$dev_port" "$storybook_port"

      for record_file in "$state_directory"/launches/*.tsv; do
        [ -f "$record_file" ] || continue
        _gaia_server_read_launch_record "$record_file" || continue
        [ "$_gaia_server_record_tree" = "$tree_root" ] || continue
        identity="$(gaia_server_process_identity "$_gaia_server_record_pid")" || {
          rm -f "$record_file"
          continue
        }
        [ "$identity" = "$_gaia_server_record_start$_gaia_server_tab$_gaia_server_record_command" ] || rm -f "$record_file"
      done

      remaining="$(_gaia_server_removed_tree_candidates "$tree_root" "$dev_port" "$storybook_port")"
      if [ -z "$remaining" ]; then
        rm -f "$tombstone_file"
        continue
      fi
    fi

    now="$(date +%s)"
    if [ $((now - reclaimed_epoch)) -gt "$_gaia_server_tombstone_expiry_seconds" ]; then
      rm -f "$tombstone_file"
    fi
  done
  return 0
}

# Resolves the ports state directory for the CLI: the seam, else
# <main-root>/.gaia/local/ports for the given directory.
_gaia_server_state_directory() {
  local main_root
  if [ -n "${GAIA_PORTS_STATE_DIRECTORY:-}" ]; then
    printf '%s' "$GAIA_PORTS_STATE_DIRECTORY"
    return 0
  fi
  main_root="$(gaia_resolve_main_root "${1:-}" 2>/dev/null)" || return 1
  [ -n "$main_root" ] || return 1
  printf '%s/.gaia/local/ports' "$main_root"
}

_gaia_server_usage() {
  {
    printf 'usage: server-process-lib.sh --listener-owner <port> <tree-root>\n'
    printf '       server-process-lib.sh --record-launch --pid <pid> --port <port> --kind <dev|storybook> --tree <tree-root>\n'
    printf '       server-process-lib.sh --listeners <port>...\n'
  } >&2
  return 2
}

_gaia_server_main() {
  case "${1:-}" in
    --listener-owner)
      [ "$#" -eq 3 ] || { _gaia_server_usage; return 2; }
      _gaia_server_is_port "$2" || { _gaia_server_usage; return 2; }
      [ -n "$3" ] || { _gaia_server_usage; return 2; }
      gaia_server_listener_owner "$2" "$3"
      return 0
      ;;
    --listeners)
      shift
      [ "$#" -ge 1 ] || { _gaia_server_usage; return 2; }
      local port
      for port in "$@"; do
        _gaia_server_is_port "$port" || { _gaia_server_usage; return 2; }
      done
      gaia_server_listeners "$@" || _gaia_server_diagnostic "no process backend available (lsof, or ss with /proc)"
      return 0
      ;;
    --record-launch)
      shift
      local pid="" port="" kind="" tree_root=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --pid | --port | --kind | --tree)
            [ "$#" -ge 2 ] || { _gaia_server_usage; return 2; }
            case "$1" in
              --pid) pid="$2" ;;
              --port) port="$2" ;;
              --kind) kind="$2" ;;
              --tree) tree_root="$2" ;;
            esac
            shift 2
            ;;
          *)
            _gaia_server_usage
            return 2
            ;;
        esac
      done
      _gaia_server_is_integer "$pid" && [ "$pid" -gt 1 ] || { _gaia_server_usage; return 2; }
      _gaia_server_is_port "$port" || { _gaia_server_usage; return 2; }
      case "$kind" in dev | storybook) ;; *) _gaia_server_usage; return 2 ;; esac
      case "$tree_root" in /*) ;; *) _gaia_server_usage; return 2 ;; esac
      local state_directory
      state_directory="$(_gaia_server_state_directory "$tree_root")" || {
        _gaia_server_diagnostic "record launch: ports state directory unresolvable; not recorded"
        return 0
      }
      gaia_server_record_launch "$state_directory" "$pid" "$port" "$kind" "$tree_root" || true
      return 0
      ;;
    *)
      _gaia_server_usage
      return 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _gaia_server_main "$@"
  exit $?
fi
