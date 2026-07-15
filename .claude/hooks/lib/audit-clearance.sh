#!/usr/bin/env bash
# audit-clearance.sh: the one shared reader for Code Audit Team clearance
# markers. Sourced, never executed; does no work at source time.
#
# A clearance marker is a JSON file under <root>/.gaia/local/audit/, named for
# the audited tree, that a Code Audit Team member writes (via
# .gaia/scripts/audit-write-clearance.sh) to attest it reviewed that content.
# Three provenances, three filename families:
#
#   earned    <tree>.ok        <tree>.<member>.ok
#   carried   <tree>.carried   <tree>.<member>.carried
#   refused   <tree>.refused   <tree>.<member>.refused
#
# The default member (code-audit-frontend) has no member infix; every
# specialized member <m> carries a ".<m>" infix.
#
# clearance_acceptable is a WELL-FORMEDNESS predicate, NOT an anti-forgery
# defense. It proves a marker was produced by the shared writer (parses as
# JSON, its body tree equals the filename key, its member matches, its
# provenance is earned or carried) so carry-forward can tell an earned anchor
# from a carried one. It cannot and does not prove authenticity: anyone who can
# redirect a writer-shaped body into the path can forge one. Do not describe it
# as a forgery defense anywhere.
#
# With jq absent, the parse-dependent predicates degrade to bare existence
# (today's behavior): bricking every gate on a missing jq is a worse failure
# than the one the body check defends against, and the hooks already guard on
# `command -v jq`.
#
# Bash 3.2 compatible (macOS-default bash). Never `cd`.

# The default member owns the infix-free filename family.
CLEARANCE_DEFAULT_MEMBER="code-audit-frontend"

# _clearance_path <root> <tree> <member> <ext> -> path on stdout
# Internal: builds a clearance artifact path for the given extension.
_clearance_path() {
  local root="$1" tree="$2" member="$3" ext="$4"
  if [ "$member" = "$CLEARANCE_DEFAULT_MEMBER" ]; then
    printf '%s\n' "${root}/.gaia/local/audit/${tree}.${ext}"
  else
    printf '%s\n' "${root}/.gaia/local/audit/${tree}.${member}.${ext}"
  fi
}

# clearance_earned_path <root> <tree> <member> -> path on stdout
clearance_earned_path() {
  _clearance_path "$1" "$2" "$3" ok
}

# clearance_carried_path <root> <tree> <member> -> path on stdout
clearance_carried_path() {
  _clearance_path "$1" "$2" "$3" carried
}

# clearance_refused_path <root> <tree> <member> -> path on stdout
clearance_refused_path() {
  _clearance_path "$1" "$2" "$3" refused
}

# clearance_field <path> <key> -> value on stdout, empty when absent
# Empty (and exit 0) when jq is absent, the file is unreadable, or the key is
# missing. Never a hard failure: callers treat empty as "not present".
clearance_field() {
  local path="$1" key="$2"
  command -v jq >/dev/null 2>&1 || return 0
  jq -r --arg k "$key" '.[$k] // empty' "$path" 2>/dev/null || true
}

# clearance_acceptable <path> <member> <tree> -> exit 0 iff writer-shaped
# The well-formedness predicate that replaces every bare `[ -f "$marker" ]`.
# Returns 0 iff: the file exists, its body parses as JSON, the body tree equals
# the filename key <tree>, the body member equals <member>, and provenance is
# earned or carried. It does NOT compare version. Legacy markers (no provenance
# key) are rejected. With jq absent it degrades to bare existence.
clearance_acceptable() {
  local path="$1" member="$2" tree="$3"
  [ -f "$path" ] || return 1
  command -v jq >/dev/null 2>&1 || return 0
  jq -e \
    --arg tree "$tree" \
    --arg member "$member" \
    '(.tree == $tree)
      and (.member == $member)
      and (.provenance == "earned" or .provenance == "carried")' \
    "$path" >/dev/null 2>&1
}

# clearance_member_cleared <root> <tree> <member>
#   exit 0 iff an acceptable earned OR carried clearance exists for this
#   member and tree.
clearance_member_cleared() {
  local root="$1" tree="$2" member="$3" p
  p="$(clearance_earned_path "$root" "$tree" "$member")"
  clearance_acceptable "$p" "$member" "$tree" && return 0
  p="$(clearance_carried_path "$root" "$tree" "$member")"
  clearance_acceptable "$p" "$member" "$tree" && return 0
  return 1
}

# clearance_member_refused <root> <tree> <member>
#   exit 0 iff a refusal artifact exists for this exact tree and member. With
#   jq present the body must parse and carry provenance "refused" with a
#   matching tree and member; with jq absent it degrades to bare existence.
clearance_member_refused() {
  local root="$1" tree="$2" member="$3" p
  p="$(clearance_refused_path "$root" "$tree" "$member")"
  [ -f "$p" ] || return 1
  command -v jq >/dev/null 2>&1 || return 0
  jq -e \
    --arg tree "$tree" \
    --arg member "$member" \
    '(.tree == $tree)
      and (.member == $member)
      and (.provenance == "refused")' \
    "$p" >/dev/null 2>&1
}
