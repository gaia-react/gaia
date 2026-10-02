#!/usr/bin/env bash
# Scratch seed layer 1 for SPEC-093 Gate V. Not shipped, not a real script.
# Every function prints its result on stdout and returns 0 on success.

# Prints its first argument unchanged, whatever characters it holds.
seed1_echo() { printf '%s\n' "$1"; }

# Prints a file, or prints nothing and returns 0 when the file is missing.
seed1_cat() { [ -f "$1" ] || return 0; cat "$1"; }

# Makes a temp directory that is removed when the calling shell exits; prints its path.
# Call it directly, not inside $(...), where the trap would fire in the subshell.
# shellcheck disable=SC2064  # expand $dir now, on purpose
seed1_tmp() { local dir; dir=$(mktemp -d) || return 1; trap "rm -rf \"$dir\"" EXIT; printf '%s\n' "$dir"; }

# Counts the lines of a file and returns 0 on an empty file.
seed1_count() { local c; c=$(wc -l < "$1") || return 1; printf '%s\n' "$((c))"; }

# Joins its arguments with a comma; no arguments print an empty string.
seed1_join() { local IFS=,; printf '%s\n' "$*"; }
