#!/usr/bin/env bash
# Shared setup for the usage-merge.bats suite: the tmp repo with the merge hook
# and the usage scripts copied in, the `gh` and network stubs, the payload
# builders, and the assertion helpers. Source it from `setup()`, which sets
# SOURCE_ROOT, TEMPORARY_DIRECTORY, and GH_STUB_DIRECTORY before calling make_stubs and build_repo.
#
# `status` and `output` come from bats' own `run`, and the suite reads the
# variables build_repo sets, neither of which the linter can see from here.
# The stub templates are single-quoted on purpose: `$0`, `$*`, and the stub
# log path must expand when a stub runs, not when it is written.
# shellcheck disable=SC2154,SC2034,SC2016

make_stubs() {
  cat >"$TEMPORARY_DIRECTORY/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_STUB_DIRECTORY/argv.log"
[ -f "$GH_STUB_DIRECTORY/sleep" ] && sleep "$(cat "$GH_STUB_DIRECTORY/sleep")"
[ "$1 $2" = "pr view" ] || exit 2
op="${3:-none}"
case "$op" in -*) op=none ;; esac
view_file="$GH_STUB_DIRECTORY/view-$op.json"
[ -f "$view_file" ] || view_file="$GH_STUB_DIRECTORY/view.json"
[ -f "$view_file" ] || exit 1
cat "$view_file"
EOF
  local network_tool
  for network_tool in curl wget nc; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$0 $*" >>"$GH_STUB_DIRECTORY/net.log"\n' >"$TEMPORARY_DIRECTORY/bin/$network_tool"
  done
  chmod +x "$TEMPORARY_DIRECTORY/bin/"*
}

encode_project_path() { printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'; }

build_repo() {
  REPO="$TEMPORARY_DIRECTORY/repo"
  PROJECTS_DIRECTORY="$TEMPORARY_DIRECTORY/projects"
  TELEMETRY_DIRECTORY="$REPO/.gaia/local/telemetry"
  mkdir -p "$REPO" "$PROJECTS_DIRECTORY/$(encode_project_path "$REPO")"
  git -C "$REPO" init -q -b main
  git -C "$REPO" -c commit.gpgsign=false commit -q --allow-empty -m init
  mkdir -p "$REPO/.claude/hooks/lib" "$REPO/.gaia/scripts" "$REPO/.gaia/scripts/spec" "$TELEMETRY_DIRECTORY"
  local copied_file
  cp "$SOURCE_ROOT/.claude/hooks/pr-merge-cost.sh" "$REPO/.claude/hooks/"
  for copied_file in verb-arming.sh verb-arming-walk.sh repo-scope.sh hook-payload.sh audit-scope.sh; do
    cp "$SOURCE_ROOT/.claude/hooks/lib/$copied_file" "$REPO/.claude/hooks/lib/"
  done
  for copied_file in "$SOURCE_ROOT"/.gaia/scripts/usage*.sh "$SOURCE_ROOT"/.gaia/scripts/token-pricing-lib.sh \
    "$SOURCE_ROOT"/.gaia/scripts/token-rates-local-lib.sh "$SOURCE_ROOT"/.gaia/scripts/token-rates-feed-lib.sh \
    "$SOURCE_ROOT"/.gaia/scripts/ledger-path-lib.sh "$SOURCE_ROOT"/.gaia/scripts/main-root-lib.sh \
    "$SOURCE_ROOT"/.gaia/scripts/branch-name-lib.sh "$SOURCE_ROOT"/.gaia/scripts/token-rollup.sh; do
    cp "$copied_file" "$REPO/.gaia/scripts/"
  done
  cp "$SOURCE_ROOT/.gaia/scripts/spec/with-ledger-lock.sh" "$REPO/.gaia/scripts/spec/"
  cat >"$REPO/.gaia/audit-ci.yml" <<'EOF'
auditors:
  - name: code-audit-frontend
    default: true
    globs:
      - "frontend/app/**"
  - name: code-audit-maintainer-shell
    globs:
      - ".gaia/scripts/**"
EOF
  cat >"$REPO/.gaia/scripts/token-rates.json" <<'EOF'
{
  "cache_multipliers": { "read": 0.1, "write_5m": 1.25, "write_1h": 2.0 },
  "models": { "claude-opus-5-5": [ { "input": 2, "output": 10 } ] }
}
EOF
  cat >"$REPO/.claude/settings.json" <<'EOF'
{"hooks": {
  "Stop": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/usage-capture.sh"}]}],
  "SessionStart": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/usage-capture.sh"}]}]
}}
EOF
}

# segment_row <key> <session_id> <first_ts> <fresh> <output>: one usage.jsonl segment row.
segment_row() {
  jq -nc --arg key "$1" --arg session_id "$2" --arg timestamp "$3" --argjson fresh_input "$4" --argjson output_tokens "$5" \
    '{schema_version:1,kind:"segment",key:$key,session_id:$session_id,inherit:false,first_ts:$timestamp,last_ts:$timestamp,messages:2,
      by_model:{"claude-opus-5-5":{fresh_input:$fresh_input,cache_write_5m:0,cache_write_1h:0,cache_read:0,output:$output_tokens}}}'
}

# gh_view <operand> <number> <headRefName> <state> <mergedAt>
gh_view() {
  jq -nc --argjson number "$2" --arg head_ref_name "$3" --arg state "$4" --arg merged_at "$5" \
    '{number:$number,headRefName:$head_ref_name,state:$state,mergedAt:(if $merged_at == "" then null else $merged_at end)}' >"$GH_STUB_DIRECTORY/view-$1.json"
}

payload_for() {
  local command="$1" session_id="${2:-s-hook}" transcript_path="${3:-}"
  [ -n "$transcript_path" ] || transcript_path="$PROJECTS_DIRECTORY/$(encode_project_path "$REPO")/$session_id.jsonl"
  jq -nc --arg command "$command" --arg session_id "$session_id" --arg transcript_path "$transcript_path" \
    '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:$command},tool_response:{stdout:"",stderr:""},session_id:$session_id,transcript_path:$transcript_path}'
}

# run_merge <command> [session_id]: the real hook, cwd = the tmp repo.
run_merge() {
  run bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$REPO" "$(payload_for "$1" "${2:-s-hook}")" "$REPO/.claude/hooks/pr-merge-cost.sh"
}

# run_script <script> <command> [session_id]: a usage-merge.sh copy run directly.
run_script() {
  run bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$REPO" "$(payload_for "$2" "${3:-s-hook}")" "$1"
}

has_line() { grep -qxF -- "$1" <<<"$output" || { printf 'missing line: [%s]\nin:\n%s\n' "$1" "$output" >&2; return 1; }; }
lacks() { grep -qF -- "$1" <<<"$output" && { printf 'unexpected [%s] in:\n%s\n' "$1" "$output" >&2; return 1; }; return 0; }
merge_rows() { jq -s --argjson pr_number "$1" '[.[] | select(.kind == "merge" and .pr == $pr_number)] | length' "$TELEMETRY_DIRECTORY/links.jsonl"; }
