# shellcheck shell=bash
# Fixture helpers for the archive scripts' usage-ledger gate. Source it; it
# defines functions only.
#
#   copy_usage_gate <real_root> <sandbox_root>
#     Copies usage.sh and every library usage.sh sources at top level into
#     <sandbox_root>/.gaia/scripts, derived from usage.sh's own source lines so
#     a library added or removed there follows without an edit here. Also
#     copies what the libraries load lazily at run time (the main-root and
#     branch-name resolvers, the pricing helpers and rate table, the ledger
#     mutex). Everything is copied at call time from the real tree, never from
#     a frozen copy.
#
#   seed_close_row <telemetry_dir> <ref> <workflow>
#     Appends one close binding row to <telemetry_dir>/usage.jsonl, the row
#     `usage.sh represented` looks for.

copy_usage_gate() {
  local real_root="$1" sandbox_root="$2" scripts_source library_name
  scripts_source="$real_root/.gaia/scripts"
  mkdir -p "$sandbox_root/.gaia/scripts/spec"
  cp "$scripts_source/usage.sh" "$sandbox_root/.gaia/scripts/usage.sh"
  # shellcheck disable=SC2016  # the pattern matches a literal "$" in usage.sh's source lines
  while IFS= read -r library_name; do
    [ -n "$library_name" ] || continue
    cp "$scripts_source/$library_name" "$sandbox_root/.gaia/scripts/$library_name"
  done < <(grep -oE '\$_usage_script_directory/[A-Za-z0-9_.-]+\.sh' "$scripts_source/usage.sh" | sed 's|.*/||' | sort -u)
  for library_name in main-root-lib.sh branch-name-lib.sh token-rates.json; do
    [ -f "$scripts_source/$library_name" ] && cp "$scripts_source/$library_name" "$sandbox_root/.gaia/scripts/$library_name"
  done
  for library_name in "$scripts_source"/token-*-lib.sh; do
    [ -f "$library_name" ] && cp "$library_name" "$sandbox_root/.gaia/scripts/$(basename "$library_name")"
  done
  cp "$scripts_source/spec/with-ledger-lock.sh" "$sandbox_root/.gaia/scripts/spec/with-ledger-lock.sh"
  return 0
}

seed_close_row() {
  local telemetry_directory="$1" ref="$2" workflow="$3"
  mkdir -p "$telemetry_directory"
  jq -cn --arg ref "$ref" --arg workflow "$workflow" \
    '{schema_version: 1, kind: "binding", type: "close", session_id: "sess-fixture",
      ts: "2026-01-02T00:00:00Z", ref: $ref, workflow: $workflow, source: "record-command"}' \
    >> "$telemetry_directory/usage.jsonl"
}
