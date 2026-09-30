#!/usr/bin/env bash
# Shared setup for the usage-merge.bats suite: the tmp repo with the merge hook
# and the usage scripts copied in, the `gh` and network stubs, the payload
# builders, and the assertion helpers. Source it from `setup()`, which sets
# SRC, TMP, and GHSTUB_DIR before calling make_stubs and build_repo.
#
# `status` and `output` come from bats' own `run`, and the suite reads the
# variables build_repo sets, neither of which the linter can see from here.
# The stub templates are single-quoted on purpose: `$0`, `$*`, and the stub
# log path must expand when a stub runs, not when it is written.
# shellcheck disable=SC2154,SC2034,SC2016

make_stubs() {
  cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GHSTUB_DIR/argv.log"
[ -f "$GHSTUB_DIR/sleep" ] && sleep "$(cat "$GHSTUB_DIR/sleep")"
[ "$1 $2" = "pr view" ] || exit 2
op="${3:-none}"
case "$op" in -*) op=none ;; esac
f="$GHSTUB_DIR/view-$op.json"
[ -f "$f" ] || f="$GHSTUB_DIR/view.json"
[ -f "$f" ] || exit 1
cat "$f"
EOF
  local h
  for h in curl wget nc; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$0 $*" >>"$GHSTUB_DIR/net.log"\n' >"$TMP/bin/$h"
  done
  chmod +x "$TMP/bin/"*
}

enc() { printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'; }

build_repo() {
  REPO="$TMP/repo"
  PROJ="$TMP/projects"
  TD="$REPO/.gaia/local/telemetry"
  mkdir -p "$REPO" "$PROJ/$(enc "$REPO")"
  git -C "$REPO" init -q -b main
  git -C "$REPO" -c commit.gpgsign=false commit -q --allow-empty -m init
  mkdir -p "$REPO/.claude/hooks/lib" "$REPO/.gaia/scripts" "$REPO/.specify/extensions/gaia/lib" "$TD"
  local f
  cp "$SRC/.claude/hooks/token-rollup-merge.sh" "$REPO/.claude/hooks/"
  for f in verb-arming.sh verb-arming-walk.sh repo-scope.sh gaia-active-plan.sh; do
    cp "$SRC/.claude/hooks/lib/$f" "$REPO/.claude/hooks/lib/"
  done
  for f in "$SRC"/.gaia/scripts/usage*.sh "$SRC"/.gaia/scripts/token-pricing-lib.sh \
    "$SRC"/.gaia/scripts/token-rates-local-lib.sh "$SRC"/.gaia/scripts/token-rates-feed-lib.sh \
    "$SRC"/.gaia/scripts/ledger-path-lib.sh "$SRC"/.gaia/scripts/main-root-lib.sh \
    "$SRC"/.gaia/scripts/branch-name-lib.sh "$SRC"/.gaia/scripts/token-rollup.sh; do
    cp "$f" "$REPO/.gaia/scripts/"
  done
  cp "$SRC/.specify/extensions/gaia/lib/with-ledger-lock.sh" "$REPO/.specify/extensions/gaia/lib/"
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

# seg <key> <sid> <first_ts> <fresh> <output>: one usage.jsonl segment row.
seg() {
  jq -nc --arg k "$1" --arg s "$2" --arg t "$3" --argjson f "$4" --argjson o "$5" \
    '{schema_version:1,kind:"segment",key:$k,session_id:$s,inherit:false,first_ts:$t,last_ts:$t,messages:2,
      by_model:{"claude-opus-5-5":{fresh_input:$f,cache_write_5m:0,cache_write_1h:0,cache_read:0,output:$o}}}'
}

# gh_view <operand> <number> <headRefName> <state> <mergedAt>
gh_view() {
  jq -nc --argjson n "$2" --arg h "$3" --arg s "$4" --arg m "$5" \
    '{number:$n,headRefName:$h,state:$s,mergedAt:(if $m == "" then null else $m end)}' >"$GHSTUB_DIR/view-$1.json"
}

payload_for() {
  local cmd="$1" sid="${2:-s-hook}" tp="${3:-}"
  [ -n "$tp" ] || tp="$PROJ/$(enc "$REPO")/$sid.jsonl"
  jq -nc --arg c "$cmd" --arg s "$sid" --arg t "$tp" \
    '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:"",stderr:""},session_id:$s,transcript_path:$t}'
}

# run_merge <command> [sid]: the real hook, cwd = the tmp repo.
run_merge() {
  run bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$REPO" "$(payload_for "$1" "${2:-s-hook}")" "$REPO/.claude/hooks/token-rollup-merge.sh"
}

# run_script <script> <command> [sid]: a usage-merge.sh copy run directly.
run_script() {
  run bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$REPO" "$(payload_for "$2" "${3:-s-hook}")" "$1"
}

has_line() { grep -qxF -- "$1" <<<"$output" || { printf 'missing line: [%s]\nin:\n%s\n' "$1" "$output" >&2; return 1; }; }
lacks() { grep -qF -- "$1" <<<"$output" && { printf 'unexpected [%s] in:\n%s\n' "$1" "$output" >&2; return 1; }; return 0; }
merge_rows() { jq -s --argjson p "$1" '[.[] | select(.kind == "merge" and .pr == $p)] | length' "$TD/links.jsonl"; }
