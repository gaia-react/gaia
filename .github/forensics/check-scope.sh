#!/usr/bin/env bash
# check-scope.sh — SPEC-002 path-policy primitive (default-deny).
#
# Usage:
#   check-scope.sh <path1> [<path2> ...]
#
# Verifies every candidate path against the SPEC-002 allowlist / denylist.
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

set -u

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
dir|deny|app/
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
  best_len=0
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
      plen=${#pattern}
      if [ "$plen" -gt "$best_len" ]; then
        best_len=$plen
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

  if [ "$best_len" -eq 0 ]; then
    printf 'deny|default-deny-unenumerated'
  else
    printf '%s|%s' "$best_type" "$best_reason"
  fi
}

# json_escape <string>
# Escapes a string for embedding inside a JSON string literal.
json_escape() {
  s=$1
  # Backslash first, then double-quote.
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

if [ "$#" -eq 0 ]; then
  printf '{"ok":true,"allowed":[],"denied":[]}\n'
  exit 0
fi

allowed_json=""
denied_json=""
ok=true

for path in "$@"; do
  result=$(classify_path "$path")
  type=${result%%|*}
  reason=${result#*|}
  esc=$(json_escape "$path")

  if [ "$type" = "allow" ]; then
    if [ -z "$allowed_json" ]; then
      allowed_json="\"$esc\""
    else
      allowed_json="$allowed_json,\"$esc\""
    fi
  else
    ok=false
    entry="{\"path\":\"$esc\",\"reason\":\"$reason\"}"
    if [ -z "$denied_json" ]; then
      denied_json="$entry"
    else
      denied_json="$denied_json,$entry"
    fi
  fi
done

printf '{"ok":%s,"allowed":[%s],"denied":[%s]}\n' "$ok" "$allowed_json" "$denied_json"
exit 0
