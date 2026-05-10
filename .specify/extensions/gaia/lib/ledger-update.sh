#!/usr/bin/env bash
# ledger-update.sh — Merge a JSON object into the .gaia/specs.json row matching
# spec_id. Existing fields are overwritten; absent fields are preserved.
#
# Usage:
#   ledger-update.sh <repo_root> <spec_id> '<json-object>'
#
# Refuses if the row is missing — callers must allocate via spec-allocator.sh first.
# Exit codes: 0 ok, 2 usage, 4 ledger or row missing, 5 invalid patch JSON.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: ledger-update.sh <repo_root> <spec_id> '<json-object>'" >&2
  exit 2
fi

repo_root="$1"
spec_id="$2"
patch="$3"
ledger_path="${repo_root%/}/.gaia/specs.json"

if [ ! -f "$ledger_path" ]; then
  echo "ledger-update: ledger not found at $ledger_path" >&2
  exit 4
fi

if ! jq -e --arg id "$spec_id" '.specs[] | select(.id == $id)' "$ledger_path" >/dev/null 2>&1; then
  echo "ledger-update: spec $spec_id not in ledger" >&2
  exit 4
fi

tmp="$(mktemp)"
if ! jq --arg id "$spec_id" --argjson patch "$patch" \
  '.specs |= map(if .id == $id then . + $patch else . end)' \
  "$ledger_path" > "$tmp" 2>/dev/null; then
  rm -f "$tmp"
  echo "ledger-update: jq failed (invalid patch JSON?)" >&2
  exit 5
fi

mv "$tmp" "$ledger_path"
