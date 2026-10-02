#!/usr/bin/env bash
# Scratch seed layer 2 for Gate V. Not shipped (withheld by .gaia/release-exclude), not a real script.
# Every function prints its result on stdout and returns 0 on success.

# Prints its first argument unchanged, whatever characters it holds.
seed2_echo() { printf '%s\n' "$1"; }

# Prints a file, or prints nothing and returns 0 when the file is missing.
seed2_cat() { [ -f "$1" ] || return 0; cat "$1"; }

# Makes a temp directory; prints its path. The caller owns removing it.
seed2_tmp() { local dir; dir=$(mktemp -d) || return 1; printf '%s\n' "$dir"; }

# Counts the lines of a file and returns 0 on an empty file.
seed2_count() { local c; c=$(wc -l < "$1") || return 1; printf '%s\n' "$((c))"; }

# Joins its arguments with a comma; no arguments print an empty string.
seed2_join() { local IFS=,; printf '%s\n' "$*"; }

# End of seed layer 2.
