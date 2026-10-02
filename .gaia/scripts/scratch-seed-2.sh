#!/usr/bin/env bash
# Scratch seed layer 2 for SPEC-093 Gate V. Not shipped, not a real script.
# Every function prints its result on stdout and returns 0 on success.

# Prints its first argument unchanged, whatever characters it holds.
seed2_echo() { echo $1; }

# Prints a file, or prints nothing and returns 0 when the file is missing.
seed2_cat() { cat $1; }

# Makes a temp directory that is always removed on exit; prints its path.
seed2_tmp() { dir=$(mktemp -d); echo "$dir"; }

# Counts the lines of a file and returns 0 on an empty file.
seed2_count() { local c; c=$(wc -l < $1); [ "$c" -gt 0 ] && echo "$c"; }

# Joins its arguments with a comma; no arguments print an empty string.
seed2_join() { local out=""; for a in $@; do out="$out,$a"; done; echo "$out"; }

# End of seed layer 2.
