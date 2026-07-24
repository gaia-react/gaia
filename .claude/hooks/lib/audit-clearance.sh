#!/usr/bin/env bash
# audit-clearance.sh: the one shared reader for Code Audit Team clearance
# markers. Sourced, never executed; does no work at source time.
#
# A clearance marker is a JSON file under <root>/.gaia/local/audit/, named for
# the audited MEMBER'S CONTENT DIGEST (a digest over exactly the files that
# member owns plus the shared gate machinery), that a Code Audit Team member
# writes (via .gaia/scripts/audit-write-clearance.sh) to attest it reviewed
# that content. Two provenances, two filename families:
#
#   earned    <digest>.ok        <digest>.<member>.ok
#   refused   <digest>.refused   <digest>.<member>.refused
#
# The default member (code-audit-frontend) has no member infix; every
# specialized member <m> carries a ".<m>" infix.
#
# clearance_acceptable is a WELL-FORMEDNESS / change-detection validity-key
# predicate, NOT an anti-forgery defense. It proves a marker was produced by
# the shared writer for the exact digest being checked (parses as JSON, its
# body digest equals the filename key, its member matches, its provenance is
# earned). It cannot and does not prove authenticity: anyone who can redirect
# a writer-shaped body into the path can forge one. Do not describe it as a
# forgery defense anywhere.
#
# jq is REQUIRED for every digest-keyed predicate below. With jq absent they
# return 1 (fail-closed): a missing jq must never degrade a digest-keyed check
# to a bare-existence match, that would accept an arbitrary file dropped at
# the right path with no content validation at all.
#
# Bash 3.2 compatible (macOS-default bash). Never `cd`.

# The default member owns the infix-free filename family.
CLEARANCE_DEFAULT_MEMBER="code-audit-frontend"

# _clearance_path <root> <digest> <member> <ext> -> path on stdout
# Internal: builds a clearance artifact path for the given extension.
_clearance_path() {
  local root="$1" digest="$2" member="$3" ext="$4"
  if [ "$member" = "$CLEARANCE_DEFAULT_MEMBER" ]; then
    printf '%s\n' "${root}/.gaia/local/audit/${digest}.${ext}"
  else
    printf '%s\n' "${root}/.gaia/local/audit/${digest}.${member}.${ext}"
  fi
}

# clearance_earned_path <root> <digest> <member> -> path on stdout
clearance_earned_path() {
  _clearance_path "$1" "$2" "$3" ok
}

# clearance_refused_path <root> <digest> <member> -> path on stdout
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

# clearance_acceptable <path> <member> <digest> -> exit 0 iff writer-shaped
# The well-formedness / change-detection validity-key predicate that replaces
# every bare `[ -f "$marker" ]`. Returns 0 iff: the file exists, jq is
# present, the body parses as JSON, the body digest equals the filename key
# <digest>, the body member equals <member>, and provenance is "earned". An
# old-scheme body (no .digest field) can never match. With jq absent this
# returns 1 (fail-closed): it does NOT degrade to bare existence.
clearance_acceptable() {
  local path="$1" member="$2" digest="$3"
  [ -f "$path" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e \
    --arg digest "$digest" \
    --arg member "$member" \
    '(.digest == $digest)
      and (.member == $member)
      and (.provenance == "earned")' \
    "$path" >/dev/null 2>&1
}

# clearance_refusal_acceptable <path> <member> <digest> -> exit 0 iff the file
# at <path> is a writer-shaped REFUSAL for this member and digest. The refusal
# twin of clearance_acceptable, with the same well-formedness semantics and the
# same fail-closed jq rule, taking a PATH rather than a root: a caller holding
# only the artifact's path (the no-op classifier derives the refusal from the
# marker path it was handed, never from a root) has no root to pass
# clearance_member_refused. That function delegates here, so both entry points
# read a refusal through one predicate.
clearance_refusal_acceptable() {
  local path="$1" member="$2" digest="$3"
  [ -f "$path" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e \
    --arg digest "$digest" \
    --arg member "$member" \
    '(.digest == $digest)
      and (.member == $member)
      and (.provenance == "refused")' \
    "$path" >/dev/null 2>&1
}

# clearance_member_cleared <root> <digest> <member>
#   exit 0 iff an acceptable earned clearance exists for this member and
#   digest. Earned only, there is no carried family.
clearance_member_cleared() {
  local root="$1" digest="$2" member="$3" p
  p="$(clearance_earned_path "$root" "$digest" "$member")"
  clearance_acceptable "$p" "$member" "$digest"
}

# clearance_member_refused <root> <digest> <member>
#   exit 0 iff a refusal artifact exists for this exact digest and member. jq
#   is REQUIRED: the body must parse and carry provenance "refused" with a
#   matching digest and member. With jq absent this returns 1 (fail-closed).
#
#   Deliberately no timestamp comparison and no same-digest .ok lookup. A
#   refusal is retired by its own author removing it, never by this reader
#   inferring supersession: the shared writer
#   (.gaia/scripts/audit-write-clearance.sh --supersede-refusal <reason>)
#   removes the sibling refusal when the member explicitly and reasonedly
#   reverses it, so by the time the gate runs there is no refusal left to
#   find. Inferring "newest marker wins" here instead would turn refusal
#   precedence, the control that stops someone re-running an auditor until it
#   passes, into a no-op.
clearance_member_refused() {
  local root="$1" digest="$2" member="$3" p
  p="$(clearance_refused_path "$root" "$digest" "$member")"
  clearance_refusal_acceptable "$p" "$member" "$digest"
}
