#!/usr/bin/env bash
# shellcheck shell=bash
#
# Starts Storybook on this tree's own port and refuses to drift to another one.
#
#   bash .gaia/scripts/storybook-launch.sh [storybook dev args...]
#
# Run from the port package directory (`pnpm storybook` does). Exit codes: 3, 4,
# 5 from ports.sh (no port file in a linked worktree, malformed file, no port
# package), 1 when the port is already in use, else Storybook's own.
#
# Only this launcher is strict. A direct `storybook dev` keeps Storybook's own
# behavior of moving to the next free port.

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/../.." && pwd)"
process_library="$script_directory/server-process-lib.sh"

port="$(bash "$script_directory/ports.sh" --tree "$PWD" --field storybook)" || exit "$?"

listener="$(bash "$process_library" --listeners "$port" 2>/dev/null | head -n 1)"
if [ -n "$listener" ]; then
  listener_pid="${listener#*"$(printf '\t')"}"
  pid_part=''
  case "$listener_pid" in
    '' | *[!0-9]* | 0) ;;
    *) pid_part=" by PID $listener_pid" ;;
  esac
  printf "GAIA: port %s, this tree's Storybook port, is already in use%s. Refusing to start on a different port. Never stop a process on a port another live tree owns without asking the user first. Run bash .gaia/scripts/ports.sh to see this tree's ports.\n" "$port" "$pid_part" >&2
  exit 1
fi

# Storybook resolves its port from -p, SBCONFIG_PORT, and PORT, and in a Claude
# preview launch PORT outranks -p. Setting both variables to the resolved port
# makes every precedence order agree, where clearing them would still let a
# preview launch fall back to a value from the caller's environment.
export PORT="$port"
export SBCONFIG_PORT="$port"

if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && [ -f "$process_library" ]; then
  # exec below keeps this PID as Storybook's, so the recorder records Storybook.
  # The delay lets it bind first; a launch that already died records nothing.
  (
    sleep 5
    kill -0 $$ 2>/dev/null &&
      bash "$process_library" --record-launch --pid $$ --port "$port" --kind storybook --tree "$repository_root"
  ) >/dev/null 2>&1 &
fi

exec storybook dev -p "$port" --exact-port "$@"
