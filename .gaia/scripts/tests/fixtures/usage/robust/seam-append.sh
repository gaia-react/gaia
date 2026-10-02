#!/usr/bin/env bash
# Test seam for usage-memo-robust.bats: the readout runs this between the
# memo warm-up and the single parse, so every row appended here is one the memo
# never saw. It names a branch key (branch:fix/2330-fresh-one) that occurs
# nowhere in the committed identity fixture, through a segment, a binding and a
# merge row. The first run appends; later runs find the marker session and do
# nothing, so a rerun inside one readout adds no second copy.
#
# UMEMO_SEAM_TELEMETRY_DIRECTORY names the telemetry dir; the suite exports it.

telemetry_directory="${UMEMO_SEAM_TELEMETRY_DIRECTORY:?UMEMO_SEAM_TELEMETRY_DIRECTORY names the telemetry dir}"

if grep -qF '"session_id":"s-seam"' "$telemetry_directory/usage.jsonl" 2>/dev/null; then
  exit 0
fi

printf '%s\n' \
  '{"schema_version":1,"kind":"segment","key":"branch:fix/2330-fresh-one","session_id":"s-seam","inherit":false,"first_ts":"2026-09-29T10:00:00Z","last_ts":"2026-09-29T10:00:00Z","messages":2,"by_model":{"claude-opus-5-5":{"fresh_input":200000,"cache_write_5m":20000,"cache_write_1h":0,"cache_read":400000,"output":20000}}}' \
  '{"schema_version":1,"kind":"binding","type":"research","session_id":"s-seam","ts":"2026-09-29T09:00:00Z","ref":"research:seam-topic","source":"transcript"}' \
  >>"$telemetry_directory/usage.jsonl"

printf '%s\n' \
  '{"schema_version":1,"kind":"merge","pr":2501,"key":"branch:fix/2330-fresh-one","merged_at":"2026-09-30T00:00:00Z","source":"gh-pr-merge","ts":"2026-09-30T00:00:00Z","session_id":null}' \
  >>"$telemetry_directory/links.jsonl"
