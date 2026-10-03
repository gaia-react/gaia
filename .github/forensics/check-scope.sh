#!/usr/bin/env bash
# check-scope.sh: the forensics path-policy primitive (default-deny).
#
# Usage:
#   check-scope.sh <path1> [<path2> ...]
#
# Verifies every candidate path against the forensics allowlist / denylist.
# Writes a JSON report to stdout. Exit code is always 0; the consumer reads
# the `ok` field in the JSON.
#
# Precedence (longest-prefix wins):
#   1. Exact-file allowlist match (e.g. `.gaia/manifest.json`).
#   2. Longest matching directory prefix wins. Because
#      `.specify/extensions/gaia/templates/` (denylist) is longer than
#      `.specify/extensions/gaia/` (allowlist), a path under templates/
#      correctly resolves to denylist.
#   3. No match → `default-deny-unenumerated`.
#
# POSIX bash only. No jq, no yq, no python.

set -uo pipefail

# Rules are encoded as pipe-separated triples: "kind|type|pattern" where:
#   kind = dir | file
#   type = allow | deny
#   pattern = directory prefix (with trailing slash) or exact file path
#
# Directory prefixes are intentionally written WITH the trailing slash so
# that prefix matching cannot bleed across siblings (`.gaia/cli/` won't
# match `.gaia/cliques/foo`).
RULES="
dir|allow|.gaia/cli/
dir|allow|.claude/hooks/
dir|allow|.claude/skills/
dir|allow|.claude/commands/
dir|allow|.claude/agents/
dir|allow|.gaia/statusline/
dir|allow|.specify/extensions/gaia/
file|allow|.gaia/manifest.json
dir|deny|frontend/app/
dir|deny|wiki/
dir|deny|studio/
dir|deny|website/
dir|deny|.specify/specs/
dir|deny|.specify/memory/
dir|deny|.gaia/local/specs/
dir|deny|.specify/extensions/gaia/templates/
dir|deny|.github/workflows/
"

# classify_path <path>
# Echoes "<type>|<reason>" where:
#   type   = allow | deny
#   reason = "" (when allow), "denylist", "default-deny-unenumerated"
classify_path() {
  candidate=$1
  best_length=0
  best_type=""
  best_reason="default-deny-unenumerated"

  # Iterate rules; track the longest matching pattern.
  IFS='
'
  for rule in $RULES; do
    [ -z "$rule" ] && continue
    kind=${rule%%|*}
    rest=${rule#*|}
    type=${rest%%|*}
    pattern=${rest#*|}

    matched=0
    if [ "$kind" = "file" ]; then
      if [ "$candidate" = "$pattern" ]; then
        matched=1
      fi
    else
      # Directory prefix; pattern ends in '/'.
      case $candidate in
        "$pattern"*) matched=1 ;;
      esac
    fi

    if [ "$matched" = "1" ]; then
      pattern_length=${#pattern}
      if [ "$pattern_length" -gt "$best_length" ]; then
        best_length=$pattern_length
        best_type=$type
        if [ "$type" = "deny" ]; then
          best_reason="denylist"
        else
          best_reason=""
        fi
      fi
    fi
  done
  unset IFS

  if [ "$best_length" -eq 0 ]; then
    printf 'deny|default-deny-unenumerated'
  else
    printf '%s|%s' "$best_type" "$best_reason"
  fi
}

# json_escape <string>
# Escapes a string for embedding inside a JSON string literal.
#
# Handles backslash and double-quote. Control bytes (U+0000..U+001F) are
# NOT escaped here, the caller is expected to detect them via
# find_control_byte() and reject the input with a structured error.
# This split keeps json_escape predictable: its output is always valid
# JSON-string content provided the input contains no control bytes.
json_escape() {
  raw_text=$1
  # Backslash first, then double-quote.
  raw_text=${raw_text//\\/\\\\}
  raw_text=${raw_text//\"/\\\"}
  printf '%s' "$raw_text"
}

# find_control_byte <string>
# Echoes "<hex>:<position>" of the FIRST U+0000..U+001F byte found,
# where <hex> is two lowercase hex digits and <position> is the
# zero-indexed offset. Echoes empty string when no control byte is
# present.
#
# UAT-009: JSON requires control bytes be escaped or rejected.
# check-scope.sh's contract is path-policy enforcement; receiving a path
# with a control byte signals upstream corruption, so we reject rather
# than silently escape.
find_control_byte() {
  scanned_text=$1
  i=0
  while [ "$i" -lt "${#scanned_text}" ]; do
    current_character=${scanned_text:$i:1}
    # POSIX trick: leading single-quote in printf %d argument yields the
    # ordinal of the first byte. Control bytes are single-byte in UTF-8.
    character_ordinal=$(printf '%d' "'$current_character")
    if [ "$character_ordinal" -lt 32 ]; then
      printf '%02x:%d' "$character_ordinal" "$i"
      return 0
    fi
    i=$((i + 1))
  done
  printf ''
}

# build_printable_path <string>
# Builds a printable representation of a path that contains a control
# byte: every non-printable byte is replaced with `?`, the result is
# truncated to 40 chars, and a trailing ellipsis is appended when
# truncation occurred. Used only by the control-byte rejection path.
build_printable_path() {
  path_with_control_byte=$1
  scrubbed=$(printf '%s' "$path_with_control_byte" | tr -c '[:print:]' '?')
  if [ "${#scrubbed}" -gt 40 ]; then
    head40=$(printf '%s' "$scrubbed" | cut -c1-40)
    printf '%s%s' "$head40" '...'
  else
    printf '%s' "$scrubbed"
  fi
}

# has_dotdot_segment <path>
# Returns 0 when the path contains a `..` PATH SEGMENT, i.e. `..` bounded by
# `/` or a string end (`^\.\.$`, `^\.\./`, `/\.\.$`, `/\.\./`); returns 1
# otherwise. A bare `..` substring inside a filename (e.g. `foo..bar`) is NOT
# a segment and returns 1. No normalization is attempted, the primitive
# rejects rather than resolves: classify_path does pure prefix matching, so a
# traversal segment like `.claude/skills/../../.github/workflows/x.yml` would
# match the allowlist prefix and escape the sandbox.
has_dotdot_segment() {
  case $1 in
    ..|../*|*/..|*/../*) return 0 ;;
    *) return 1 ;;
  esac
}

if [ "$#" -eq 0 ]; then
  printf '{"ok":true,"allowed":[],"denied":[]}\n'
  exit 0
fi

# UAT-009: short-circuit on the first control-byte-bearing path. The
# rejection envelope replaces the normal classification result; exit 0
# is preserved per the consumer-reads-JSON contract.
for path in "$@"; do
  control_byte_location=$(find_control_byte "$path")
  if [ -n "$control_byte_location" ]; then
    hex=${control_byte_location%%:*}
    position=${control_byte_location#*:}
    printable_path=$(build_printable_path "$path")
    escaped_printable_path=$(json_escape "$printable_path")
    printf '{"ok":false,"allowed":[],"denied":[{"path":"%s","reason":"control-byte:0x%s-at-position-%d"}]}\n' \
      "$escaped_printable_path" "$hex" "$position"
    exit 0
  fi
done

# RT-05: short-circuit on the first path bearing a `..` segment. Runs AFTER
# the control-byte loop, so any path reaching here is control-byte-free and
# safe to embed via json_escape. First offending path wins and denies the
# whole invocation, matching the control-byte and mixed-allow+deny posture.
for path in "$@"; do
  if has_dotdot_segment "$path"; then
    escaped_path=$(json_escape "$path")
    printf '{"ok":false,"allowed":[],"denied":[{"path":"%s","reason":"path-traversal:contains-..-segment"}]}\n' \
      "$escaped_path"
    exit 0
  fi
done

allowed_json=""
denied_json=""
ok=true

for path in "$@"; do
  result=$(classify_path "$path")
  type=${result%%|*}
  reason=${result#*|}
  escaped_path=$(json_escape "$path")

  if [ "$type" = "allow" ]; then
    if [ -z "$allowed_json" ]; then
      allowed_json="\"$escaped_path\""
    else
      allowed_json="$allowed_json,\"$escaped_path\""
    fi
  else
    ok=false
    entry="{\"path\":\"$escaped_path\",\"reason\":\"$reason\"}"
    if [ -z "$denied_json" ]; then
      denied_json="$entry"
    else
      denied_json="$denied_json,$entry"
    fi
  fi
done

printf '{"ok":%s,"allowed":[%s],"denied":[%s]}\n' "$ok" "$allowed_json" "$denied_json"
exit 0
