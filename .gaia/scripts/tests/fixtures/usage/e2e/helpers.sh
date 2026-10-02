# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # $output is bats'; the sourcing suites read the globals set here
# Shared helpers for usage-e2e.bats and usage-e2e-chains.bats. Sourced from each
# suite's setup(), after the suite has exported its own rates isolation.
#
# Every transcript line is built with `write_assistant_message`, whose message factor k makes each
# bucket a fixed multiple: fresh k, 5m cache write 10k, 1h cache write 100k,
# cache read 1000k, output as passed. A message is worth 1111k + output tokens,
# so every golden literal in the suites was added up by hand from the k and
# output arguments; nothing here calls the flusher's or the resolver's own code
# to produce an expected value.

E2E_SOURCE_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

encode_project_path() { printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'; }

# build_repo: a tmp git repo holding every production file the feature touches
# at its repo-relative path, including the real settings.json. Sets REPO, PROJECTS_DIRECTORY,
# TELEMETRY_DIRECTORY, and the gh/curl/wget/nc stubs on PATH (argv to $STUBLOG, nothing else).
build_repo() {
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  REPO="$TEMPORARY_DIRECTORY/repo"
  PROJECTS_DIRECTORY="$TEMPORARY_DIRECTORY/projects"
  TELEMETRY_DIRECTORY="$REPO/.gaia/local/telemetry"
  STUBLOG="$TEMPORARY_DIRECTORY/net.log"
  unset CLAUDE_CODE_SESSION_ID GAIA_TALLY_PROJECTS_ROOT GITHUB_ACTIONS GAIA_USAGE_HOOKS_DISABLE
  unset GAIA_LEDGER_LOCK_TIMEOUT_SECONDS GAIA_USAGE_MERGE_CAP_SECONDS GAIA_USAGE_TEST_BARRIER
  export GIT_AUTHOR_NAME="GAIA Test" GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test" GIT_COMMITTER_EMAIL="gaia-test@example.com"
  export GAIA_LEDGER_LOCK_POLL_SECONDS=0.1
  mkdir -p "$REPO" "$PROJECTS_DIRECTORY/$(encode_project_path "$REPO")" "$TEMPORARY_DIRECTORY/bin"
  git -C "$REPO" init -q -b main
  git -C "$REPO" -c commit.gpgsign=false commit -q --allow-empty -m init
  mkdir -p "$REPO/.claude/hooks/lib" "$REPO/.gaia/scripts" "$REPO/.specify/extensions/gaia/lib" \
    "$REPO/.specify/extensions/gaia/templates" "$REPO/.claude/skills/gaia/references"
  cp "$E2E_SOURCE_ROOT"/.claude/hooks/*.sh "$REPO/.claude/hooks/"
  cp "$E2E_SOURCE_ROOT"/.claude/hooks/lib/*.sh "$REPO/.claude/hooks/lib/"
  cp "$E2E_SOURCE_ROOT"/.gaia/scripts/*.sh "$REPO/.gaia/scripts/"
  cp "$E2E_SOURCE_ROOT"/.specify/extensions/gaia/lib/*.sh "$REPO/.specify/extensions/gaia/lib/"
  cp "$E2E_SOURCE_ROOT/.specify/extensions/gaia/templates/spec-template.md" "$REPO/.specify/extensions/gaia/templates/"
  cp "$E2E_SOURCE_ROOT/.claude/skills/gaia/references/spec.md" "$REPO/.claude/skills/gaia/references/"
  cp "$E2E_SOURCE_ROOT/.claude/settings.json" "$REPO/.claude/settings.json"
  cat >"$REPO/.gaia/scripts/token-rates.json" <<'JSON'
{
  "cache_multipliers": { "read": 0.1, "write_5m": 1.25, "write_1h": 2.0 },
  "models": { "claude-opus-5-5": [ { "input": 2, "output": 10 } ] }
}
JSON
  cat >"$TEMPORARY_DIRECTORY/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"$STUBLOG"
[ "$1 $2" = "pr view" ] || exit 2
operand="${3:-none}"
case "$operand" in -*) operand=none ;; esac
view_file="$GHVIEW_DIRECTORY/view-$operand.json"
[ -f "$view_file" ] || view_file="$GHVIEW_DIRECTORY/view.json"
[ -f "$view_file" ] || exit 1
cat "$view_file"
STUB
  local network_tool
  for network_tool in curl wget nc; do
    # shellcheck disable=SC2016  # the generated stub, not this script, must expand $* and $STUBLOG
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s $*" >>"$STUBLOG"\n' "$network_tool" >"$TEMPORARY_DIRECTORY/bin/$network_tool"
  done
  chmod +x "$TEMPORARY_DIRECTORY/bin/"*
  GHVIEW_DIRECTORY="$TEMPORARY_DIRECTORY/ghview"
  mkdir -p "$GHVIEW_DIRECTORY"
  export STUBLOG GHVIEW_DIRECTORY
  export PATH="$TEMPORARY_DIRECTORY/bin:$PATH"
}

# gh_view <operand> <number> <headRefName> <state> <mergedAt>
gh_view() {
  jq -nc --argjson pr_number "$2" --arg head_ref_name "$3" --arg state "$4" --arg merged_at "$5" \
    '{number:$pr_number,headRefName:$head_ref_name,state:$state,mergedAt:(if $merged_at == "" then null else $merged_at end)}' >"$GHVIEW_DIRECTORY/view-$1.json"
}

# write_assistant_message <file> <session_id> <cwd> <branch> <id> <ts> <input_tokens> <output> [tool_use array json]
write_assistant_message() {
  jq -nc --arg session_id "$2" --arg cwd "$3" --arg branch "$4" --arg message_id "$5" --arg timestamp "$6" --argjson input_tokens "$7" --argjson output_tokens "$8" \
    --argjson tool "${9:-[]}" \
    '{type:"assistant",uuid:("u-"+$message_id),timestamp:$timestamp,cwd:$cwd,sessionId:$session_id,gitBranch:$branch,
      message:{id:$message_id,model:"claude-opus-5-5",role:"assistant",
        usage:{input_tokens:$input_tokens,cache_creation_input_tokens:(110*$input_tokens),cache_read_input_tokens:(1000*$input_tokens),output_tokens:$output_tokens,
          cache_creation:{ephemeral_5m_input_tokens:(10*$input_tokens),ephemeral_1h_input_tokens:(100*$input_tokens)}},
        content:($tool + [{type:"text",text:"ok"}])}}' >>"$1"
}

skill_tool() { jq -nc --arg skill_name "$1" '[{type:"tool_use",id:"tu",name:"Skill",input:{skill:$skill_name}}]'; }
write_tool() { jq -nc --arg file_path "$1" '[{type:"tool_use",id:"tw",name:"Write",input:{file_path:$file_path,content:"x"}}]'; }

# transcript_path_for_session <session_id> [worktree path]: the transcript file for a session, dir created.
transcript_path_for_session() {
  local transcript_directory
  transcript_directory="$PROJECTS_DIRECTORY/$(encode_project_path "${2:-$REPO}")"
  mkdir -p "$transcript_directory"
  printf '%s/%s.jsonl' "$transcript_directory" "$1"
}

# make_worktree <dirname under .claude/worktrees> <branch>: a real linked worktree
# (tree roots come from `git worktree list`); prints its path.
make_worktree() {
  local worktree_path="$REPO/.claude/worktrees/$1"
  git -C "$REPO" worktree add -q -b "$2" "$worktree_path" >/dev/null 2>&1
  printf '%s' "$worktree_path"
}

flush_session() {
  bash "$REPO/.gaia/scripts/usage-flush.sh" --session "$1" --finished-main \
    --projects-root "$PROJECTS_DIRECTORY" --main-root "$REPO" "${@:2}"
}

run_usage() { bash "$REPO/.gaia/scripts/usage.sh" "$@" --main-root "$REPO" --projects-root "$PROJECTS_DIRECTORY"; }

has_line() { grep -qxF -- "$1" <<<"$output" || { printf 'missing line: [%s]\nin:\n%s\n' "$1" "$output" >&2; return 1; }; }
lacks() {
  if grep -qF -- "$1" <<<"$output"; then printf 'unexpected [%s] in:\n%s\n' "$1" "$output" >&2; return 1; fi
  return 0
}

# assert_totals <golden json>: per-key, per-model, per-bucket sums of the
# usage.jsonl segment rows, by plain jq, equal the literal.
assert_totals() {
  local want got
  want="$(jq -S . <<<"$1")"
  got="$(jq -S -s '[.[] | select(.kind == "segment")]
    | reduce .[] as $segment ({}; reduce ($segment.by_model | to_entries[]) as $model (.;
        reduce ($model.value | to_entries[]) as $bucket (.; .[$segment.key][$model.key][$bucket.key] += $bucket.value)))' "$TELEMETRY_DIRECTORY/usage.jsonl")"
  [ "$got" = "$want" ] || { printf 'want:\n%s\ngot:\n%s\n' "$want" "$got" >&2; return 1; }
}

# cursors_settled <n>: the cursor cache names n files, each at its file's size.
cursors_settled() {
  local file_path cursor_offset settled_count=0
  [ -f "$TELEMETRY_DIRECTORY/usage-cursors.json" ] || return 1
  while IFS=$'\t' read -r file_path cursor_offset; do
    [ "$cursor_offset" -eq "$(wc -c <"$file_path" | tr -d ' ')" ] || return 1
    settled_count=$((settled_count + 1))
  done < <(jq -r '.files | to_entries[] | "\(.key)\t\(.value.offset)"' "$TELEMETRY_DIRECTORY/usage-cursors.json" 2>/dev/null)
  [ "$settled_count" -eq "$1" ]
}

# quiesce <n>: every detached flusher of this test has exited and n cursors are
# at their files' ends. Bounded at 20 s.
quiesce() {
  local i=0
  while [ "$i" -lt 200 ]; do
    if ! pgrep -f "$TEMPORARY_DIRECTORY/.*usage-flush" >/dev/null 2>&1 && cursors_settled "$1"; then return 0; fi
    sleep 0.1
    i=$((i + 1))
  done
  echo "no quiescence: $(cat "$TELEMETRY_DIRECTORY/usage-cursors.json" 2>/dev/null)" >&2
  return 1
}

hook_payload() { # <event> <session_id> <transcript>
  jq -nc --arg event_name "$1" --arg session_id "$2" --arg transcript_path "$3" \
    '{hook_event_name:$event_name,session_id:$session_id,transcript_path:$transcript_path,stop_hook_active:false}'
}

merge_payload() { # <command> <session_id> <transcript>
  jq -nc --arg command "$1" --arg session_id "$2" --arg transcript_path "$3" \
    '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:$command},tool_response:{stdout:"",stderr:""},session_id:$session_id,transcript_path:$transcript_path}'
}

# fire <hook basename> <payload>: the real hook in the tmp repo, cwd = the repo.
fire() {
  run bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$REPO" "$2" "$REPO/.claude/hooks/$1"
}

# seed_debt: the two-session `debt/123-slug` scenario, transcripts only.
# s-m main checkout: k1/o5 + k2/o10; s-w worktree: k4/o20. Sets WORKTREE.
seed_debt() {
  WORKTREE="$(make_worktree debt+123-slug debt/123-slug)"
  TRANSCRIPT_PATH_MAIN="$(transcript_path_for_session s-m)"
  TRANSCRIPT_PATH_WORKTREE="$(transcript_path_for_session s-w "$WORKTREE")"
  write_assistant_message "$TRANSCRIPT_PATH_MAIN" s-m "$REPO" debt/123-slug m1 2026-10-01T09:00:01.000Z 1 5
  write_assistant_message "$TRANSCRIPT_PATH_MAIN" s-m "$REPO" debt/123-slug m2 2026-10-01T09:00:02.000Z 2 10
  write_assistant_message "$TRANSCRIPT_PATH_WORKTREE" s-w "$WORKTREE" worktree-debt+123-slug m3 2026-10-01T09:30:01.000Z 4 20
}

DEBT_TOTALS='{"branch:debt/123-slug":{"claude-opus-5-5":{"cache_read":7000,"cache_write_1h":700,"cache_write_5m":70,"fresh_input":7,"output":35}}}'

# seed_early: an older session that makes the coverage start 2026-09-28.
seed_early() {
  local transcript_path
  transcript_path="$(transcript_path_for_session s-early)"
  write_assistant_message "$transcript_path" s-early "$REPO" fix/early e1 2026-09-28T08:00:01.000Z 1 1
}

# derive_subcommands: the subcommand names in usage.sh's dispatch `case`, sorted, one
# per line. The `""|-h|--help` and `*` arms do not start with a bare name.
derive_subcommands() {
  awk '/^case "\$SUBCOMMAND" in/ { in_case = 1; next } /^esac/ { in_case = 0 } in_case && /^  [a-z][a-z-]*\)/ { sub(/\).*/, ""); gsub(/ /, ""); print }' \
    "$1" | sort
}

# subcommand_arguments <name>: one representative argument list per subcommand, words split
# on purpose. An unknown name fails, so a subcommand added to the dispatch
# without an entry here turns the loops that use it red.
subcommand_arguments() {
  case "$1" in
    link) echo "link spec:SPEC-002 research:x" ;;
    unlink) echo "unlink spec:SPEC-001 research:x" ;;
    lineage) echo "lineage $REPO/.gaia/local/specs/SPEC-009/SPEC.md" ;;
    declare) echo "declare research:x --session s-decl" ;;
    pr) echo "pr 101 --branch debt/123-slug" ;;
    pr-branch) echo "pr-branch 101" ;;
    initiative) echo "initiative issue:123" ;;
    reconcile) echo "reconcile" ;;
    *) return 1 ;;
  esac
}

