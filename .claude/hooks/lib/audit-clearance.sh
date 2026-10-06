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

# _clearance_path <root> <digest> <member> <extension> -> path on stdout
# Internal: builds a clearance artifact path for the given extension.
_clearance_path() {
  local root="$1" digest="$2" member="$3" extension="$4"
  if [ "$member" = "$CLEARANCE_DEFAULT_MEMBER" ]; then
    printf '%s\n' "${root}/.gaia/local/audit/${digest}.${extension}"
  else
    printf '%s\n' "${root}/.gaia/local/audit/${digest}.${member}.${extension}"
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
  local root="$1" digest="$2" member="$3" earned_path
  earned_path="$(clearance_earned_path "$root" "$digest" "$member")"
  clearance_acceptable "$earned_path" "$member" "$digest"
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
  local root="$1" digest="$2" member="$3" refused_path
  refused_path="$(clearance_refused_path "$root" "$digest" "$member")"
  clearance_refusal_acceptable "$refused_path" "$member" "$digest"
}

# clearance_review_kind <path> -> "full", "light", or "-"
#   The body's `review` value when it is exactly full or light, else "-"
#   (legacy markers, refusals, unknown values). jq absent prints "-", exit 0.
clearance_review_kind() {
  local review
  review="$(clearance_field "$1" review)"
  case "$review" in
    full|light) printf '%s\n' "$review" ;;
    *) printf '%s\n' "-" ;;
  esac
  return 0
}

# clearance_scan <root> <member> <provenance> -> "<tree>\t<version>\t<sha>\t<review>\t<path>" lines
# <review> is full, light, or "-" (see clearance_review_kind). Only "full" is
# ever an incremental-scope anchor; a caller choosing an anchor must skip the
# rest.
# The enumerating counterpart to the digest-keyed predicates above: a caller
# that holds a member and a provenance but no digest (the per-member base
# resolver, choosing among this member's own history) cannot ask
# clearance_acceptable anything. This walks every artifact in the member's
# <provenance> family and applies the SAME well-formedness key
# (clearance_acceptable's digest/member/provenance equality), read from the
# filename instead of supplied by the caller. It is still not an anti-forgery
# defense, only proof a record is writer-shaped.
#
# The recorded TREE is the field callers match on, not the sha: a clean-round
# stamp amends HEAD (rewriting the sha a moments-old clearance recorded) while
# preserving the tree. `.version` and `.sha` are advisory and may come back
# empty when the body predates that field; `.tree` is never empty for an
# accepted record. Callers must never match on an empty value (the writer
# applies no empty-guard to the recorded fields it emits).
#
# jq REQUIRED, fail-closed: absent jq prints nothing and returns 1, same as
# every other predicate here -- it must never degrade to a bare filename scan.
# Returns 0 iff at least one line was emitted. Output order is unspecified
# (glob order happens to be lexical, but callers must not depend on it).
clearance_scan() {
  local root="$1" member="$2" provenance="$3"
  local audit_directory extension file base stem digest tree version sha any=1
  local fields rest marker_member marker_provenance review tab
  tab="$(printf '\t')"
  command -v jq >/dev/null 2>&1 || return 1
  case "$provenance" in
    earned) extension="ok" ;;
    refused) extension="refused" ;;
    *) return 1 ;;
  esac
  audit_directory="${root}/.gaia/local/audit"
  [ -d "$audit_directory" ] || return 1
  for file in "$audit_directory"/*."$extension"; do
    [ -e "$file" ] || continue
    base="$(basename "$file")"
    stem="${base%."$extension"}"
    if [ "$member" != "$CLEARANCE_DEFAULT_MEMBER" ]; then
      case "$stem" in
        *".$member") stem="${stem%."$member"}" ;;
        *) continue ;;
      esac
    fi
    # One jq read per marker: seven tab-separated fields, emitted in a fixed
    # order and peeled with parameter expansion (not `read` under a tab IFS,
    # which would collapse an empty version or sha and shift the later fields).
    fields="$(jq -r '[.digest, .member, .provenance, .tree, .version, .sha, .review]
      | map(if . == null then "" elif type == "string" then . else tojson end) | join("\t")' "$file" 2>/dev/null)" || continue
    digest="${fields%%"$tab"*}"
    rest="${fields#*"$tab"}"
    marker_member="${rest%%"$tab"*}"
    rest="${rest#*"$tab"}"
    marker_provenance="${rest%%"$tab"*}"
    rest="${rest#*"$tab"}"
    tree="${rest%%"$tab"*}"
    rest="${rest#*"$tab"}"
    version="${rest%%"$tab"*}"
    rest="${rest#*"$tab"}"
    sha="${rest%%"$tab"*}"
    review="${rest#*"$tab"}"
    [ -n "$digest" ] && [ "$digest" = "$stem" ] || continue
    [ "$marker_member" = "$member" ] || continue
    [ "$marker_provenance" = "$provenance" ] || continue
    [ -n "$tree" ] || continue
    case "$review" in
      full|light) ;;
      *) review="-" ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$tree" "$version" "$sha" "$review" "$file"
    any=0
  done
  return "$any"
}
