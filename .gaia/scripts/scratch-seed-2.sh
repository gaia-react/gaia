#!/usr/bin/env bash
# Scratch seed layer 2 for SPEC-093 Gate V. Not shipped (excluded in
# .gaia/release-exclude), not a real script.
# Every function prints its result on stdout and returns 0 on success.

# Prints its first argument unchanged, whatever characters it holds.
seed2_echo() { printf '%s\n' "$1"; }

# Prints a file, or prints nothing and returns 0 when the file is missing.
seed2_cat() { [ -f "$1" ] || return 0; cat "$1"; }

# Makes a temp directory and prints its path. The caller owns cleanup and must
# remove it (rm -rf) itself; nothing here removes it.
seed2_tmp() { local dir; dir=$(mktemp -d) || return 1; echo "$dir"; }

# Counts the lines of a file and returns 0 on an empty file.
seed2_count() { local c; c=$(wc -l < "$1") || return 1; c=${c##* }; echo "$c"; }

# Joins its arguments with a comma; no arguments print an empty string.
seed2_join() { local IFS=,; echo "$*"; }
