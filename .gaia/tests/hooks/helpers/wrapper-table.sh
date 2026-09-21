#!/usr/bin/env bash
# Shared readers for the command-wrapper table in
# .claude/hooks/lib/command-wrappers.sh.
#
# Two suites need the SET of wrappers rather than the stripping behaviour:
# block-no-verify.bats drives every row through the commit guards, and
# verb-arming-lib.bats drives every row through the arming decision. Deriving
# the set in both from one reader is what stops a row landing in the table and
# reaching only one of them, which is the failure a second copy of this parse
# would reintroduce the moment the two copies diverged.
#
# Set WRAPPER_TABLE_FILE to the library's path before calling anything here.

# Print `<name> <operand-count>` for every row of the shared wrapper table.
wrapper_table() {
  sed -n '/GAIA_WRAPPER_TABLE_BEGIN/,/GAIA_WRAPPER_TABLE_END/p' \
      "$WRAPPER_TABLE_FILE" \
    | sed -nE 's/^[[:space:]]*([a-z]+)\)[[:space:]]*_w_valued=.*_w_operands=([0-9]+).*/\1 \2/p'
}

# How many rows that table holds, counted independently of the parse above so a
# row the parse cannot read is a short read rather than an invisible one.
wrapper_table_rows() {
  sed -n '/GAIA_WRAPPER_TABLE_BEGIN/,/GAIA_WRAPPER_TABLE_END/p' \
      "$WRAPPER_TABLE_FILE" \
    | grep -cE '^[[:space:]]*[a-z]+\)[[:space:]]*_w_valued='
}

# Print `<row> <option>` for every option in every row of the shared table.
#
# The option list is split with `read -r -a` rather than an unquoted expansion,
# the same discipline the library this parses states for itself: an unquoted
# split also pathname-expands, so a glob character in a segment would change the
# word count the callers depend on.
wrapper_table_options() {
  sed -n '/GAIA_WRAPPER_TABLE_BEGIN/,/GAIA_WRAPPER_TABLE_END/p' \
      "$WRAPPER_TABLE_FILE" \
    | sed -nE "s/^[[:space:]]*([a-z]+)\)[[:space:]]*_w_valued='([^']*)'.*/\1 \2/p" \
    | while read -r _row _opts; do
        read -r -a _optv <<<"$_opts"
        for _o in ${_optv[@]+"${_optv[@]}"}; do printf '%s %s\n' "$_row" "$_o"; done
      done
}

# How many options that table holds, counted independently of the parse above
# so a row the parse cannot read is a short read rather than an invisible one.
wrapper_table_option_count() {
  sed -n '/GAIA_WRAPPER_TABLE_BEGIN/,/GAIA_WRAPPER_TABLE_END/p' \
      "$WRAPPER_TABLE_FILE" \
    | grep -oE "_w_valued='[^']*'" \
    | sed -E "s/_w_valued='//; s/'$//" \
    | tr ' ' '\n' \
    | grep -c '^-'
}

# The wrapper written the way its own grammar requires: its name, then as many
# operands of its own as the table says it consumes.
wrapper_prefix() {
  local operands="$2" out="$1" i=0
  while [ "$i" -lt "$operands" ]; do
    out="$out 5"
    i=$((i + 1))
  done
  printf '%s' "$out"
}
