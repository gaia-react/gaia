#!/usr/bin/env bash
# SessionStart hook: writes the head of wiki/hot.md to stdout so the recent-context
# cache reaches every session at startup, resume, clear, and compact.
#
# GAIA owns this load. claude-obsidian 2.x has its own SessionStart hot.md load,
# but it is opt-in (CLAUDE_OBSIDIAN_SESSION_CONTEXT, left unset here) and its vault
# discovery fails closed on GAIA's layout, where .obsidian/ sits inside wiki/. A
# project that sets the variable gets no second copy for the same reason.
#
# Output: at most 4096 bytes of wiki/hot.md as plain text. When the file is larger,
# one trailing line says it was cut: "[wiki/hot.md truncated at 4096 bytes; read the
# file for the rest]". That differs on purpose from workflow-doctrine-inject.sh,
# which skips an over-cap file silently: a cut hot.md is still useful, a cut
# doctrine file is not.
#
# The repo root comes from git, run in the process cwd, so a session launched from
# frontend/ reads the same wiki/hot.md as one launched from the root. Outside a
# repo, or with no readable wiki/hot.md, the hook prints nothing. It needs no jq,
# writes nothing to stderr, and always exits 0.

set -uo pipefail
trap 'exit 0' ERR

# Byte-wise lengths and cuts, whatever the user's locale.
LC_ALL=C

cat >/dev/null 2>&1 || true

maximum_bytes=4096
truncation_notice='[wiki/hot.md truncated at 4096 bytes; read the file for the rest]'

repository_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$repository_root" ] || exit 0

hot_cache="$repository_root/wiki/hot.md"
[ -f "$hot_cache" ] && [ -r "$hot_cache" ] || exit 0

size_in_bytes=$(wc -c <"$hot_cache" 2>/dev/null) || exit 0
size_in_bytes=${size_in_bytes//[[:space:]]/}
[ -n "$size_in_bytes" ] || exit 0

# The trailing x keeps command substitution from eating the cut's final newlines.
head_of_file=$(head -c "$maximum_bytes" "$hot_cache" 2>/dev/null; printf x) || exit 0
head_of_file=${head_of_file%x}
printf '%s' "$head_of_file"

if [ "$size_in_bytes" -gt "$maximum_bytes" ]; then
  case "$head_of_file" in
    *$'\n') ;;
    *) printf '\n' ;;
  esac
  printf '%s\n' "$truncation_notice"
fi
exit 0
