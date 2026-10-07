# shellcheck shell=bash
#
# Read-only access to the verification pass record that
# `bash .gaia/tests/verify-harness.sh branch` writes when a branch run ends
# with no new failure. The audit-loop dispatch gate sources this file to decide
# whether the branch was verified at its current HEAD.
#
# Read-only by design: nothing here writes or removes a record. The only
# writer is private to .gaia/tests/verify-harness.sh, so no sourceable
# function exists that could stamp a record without running the checks.
#
# Record path: <main-root>/.gaia/local/protected/verify-pass/<branch-key>.json,
# where <main-root> is gaia_resolve_main_root (.gaia/scripts/main-root-lib.sh)
# and <branch-key> is gaia_loop_key (.gaia/scripts/audit-loop-state-lib.sh).
# The key may contain `/`, so a record can sit in a subdirectory.
#
# Record shape:
#   {"schema":1,"branch":"<key>","head":"<full sha>","written_at":"<UTC>",
#    "skipped":["<label>: <reason>",...],"preexisting":["<label>",...]}
#
# Sourcing defines functions only and runs no command. Bash 3.2 compatible;
# jq is the one external tool, probed with `command -v`. Maintainer-only:
# .gaia/tests is release-excluded wholesale.

# gaia_verify_pass_record_path <main-root> <branch-key>: print the record path.
gaia_verify_pass_record_path() {
  printf '%s/.gaia/local/protected/verify-pass/%s.json\n' "${1-}" "${2-}"
}

# gaia_verify_pass_record_check <main-root> <branch-key> <head-sha>
#   0  the record exists, parses, has schema 1, and its head equals <head-sha>
#   1  no record
#   2  a record for another head; the recorded head is printed on stdout
#   5  the record is unreadable or malformed (not one JSON object, schema not
#      1, or a head that is not a hex object id)
#   6  jq is not installed
# The single-quoted jq program is jq text, not a shell expansion.
# shellcheck disable=SC2016
gaia_verify_pass_record_check() {
  local main_root="${1-}" branch_key="${2-}" expected_head="${3-}" record_path recorded_head
  record_path="$(gaia_verify_pass_record_path "$main_root" "$branch_key")"
  [ -e "$record_path" ] || [ -L "$record_path" ] || return 1
  command -v jq >/dev/null 2>&1 || return 6
  [ -f "$record_path" ] && [ -r "$record_path" ] || return 5
  recorded_head="$(jq -r -s '
    if length == 1 and (.[0] | type) == "object" and .[0].schema == 1
       and (.[0].head | type) == "string"
       and (.[0].head | test("^([0-9a-f]{40}|[0-9a-f]{64})$"))
    then .[0].head
    else error("malformed verify pass record")
    end' "$record_path" 2>/dev/null)" || return 5
  [ -n "$recorded_head" ] || return 5
  if [ "$recorded_head" = "$expected_head" ]; then
    return 0
  fi
  printf '%s\n' "$recorded_head"
  return 2
}
