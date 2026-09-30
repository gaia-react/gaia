# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # $output is bats'; the sourcing suites read the globals set here
# Shared helpers for usage-e2e.bats and usage-e2e-chains.bats. Sourced from each
# suite's setup(), after the suite has exported its own rates isolation.
#
# Every transcript line is built with `asst`, whose message factor k makes each
# bucket a fixed multiple: fresh k, 5m cache write 10k, 1h cache write 100k,
# cache read 1000k, output as passed. A message is worth 1111k + output tokens,
# so every golden literal in the suites was added up by hand from the k and
# output arguments; nothing here calls the flusher's or the resolver's own code
# to produce an expected value.

E2E_SRC="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

enc() { printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'; }

# build_repo: a tmp git repo holding every production file the feature touches
# at its repo-relative path, including the real settings.json. Sets REPO, PROJ,
# TD, and the gh/curl/wget/nc stubs on PATH (argv to $STUBLOG, nothing else).
build_repo() {
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  REPO="$TMP/repo"
  PROJ="$TMP/projects"
  TD="$REPO/.gaia/local/telemetry"
  STUBLOG="$TMP/net.log"
  unset CLAUDE_CODE_SESSION_ID GAIA_TALLY_PROJECTS_ROOT GITHUB_ACTIONS GAIA_USAGE_HOOKS_DISABLE
  unset GAIA_LEDGER_LOCK_TIMEOUT_SECS GAIA_USAGE_MERGE_CAP_SECS GAIA_USAGE_TEST_BARRIER
  export GIT_AUTHOR_NAME="GAIA Test" GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test" GIT_COMMITTER_EMAIL="gaia-test@example.com"
  export GAIA_LEDGER_LOCK_POLL_SECS=0.1
  mkdir -p "$REPO" "$PROJ/$(enc "$REPO")" "$TMP/bin"
  git -C "$REPO" init -q -b main
  git -C "$REPO" -c commit.gpgsign=false commit -q --allow-empty -m init
  mkdir -p "$REPO/.claude/hooks/lib" "$REPO/.gaia/scripts" "$REPO/.specify/extensions/gaia/lib" \
    "$REPO/.specify/extensions/gaia/templates" "$REPO/.claude/skills/gaia/references"
  cp "$E2E_SRC"/.claude/hooks/*.sh "$REPO/.claude/hooks/"
  cp "$E2E_SRC"/.claude/hooks/lib/*.sh "$REPO/.claude/hooks/lib/"
  cp "$E2E_SRC"/.gaia/scripts/*.sh "$REPO/.gaia/scripts/"
  cp "$E2E_SRC"/.specify/extensions/gaia/lib/*.sh "$REPO/.specify/extensions/gaia/lib/"
  cp "$E2E_SRC/.specify/extensions/gaia/templates/spec-template.md" "$REPO/.specify/extensions/gaia/templates/"
  cp "$E2E_SRC/.claude/skills/gaia/references/spec.md" "$REPO/.claude/skills/gaia/references/"
  cp "$E2E_SRC/.claude/settings.json" "$REPO/.claude/settings.json"
  cat >"$REPO/.gaia/scripts/token-rates.json" <<'JSON'
{
  "cache_multipliers": { "read": 0.1, "write_5m": 1.25, "write_1h": 2.0 },
  "models": { "claude-opus-5-5": [ { "input": 2, "output": 10 } ] }
}
JSON
  cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"$STUBLOG"
[ "$1 $2" = "pr view" ] || exit 2
op="${3:-none}"
case "$op" in -*) op=none ;; esac
f="$GHVIEW_DIR/view-$op.json"
[ -f "$f" ] || f="$GHVIEW_DIR/view.json"
[ -f "$f" ] || exit 1
cat "$f"
STUB
  local h
  for h in curl wget nc; do
    # shellcheck disable=SC2016  # the generated stub, not this script, must expand $* and $STUBLOG
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s $*" >>"$STUBLOG"\n' "$h" >"$TMP/bin/$h"
  done
  chmod +x "$TMP/bin/"*
  GHVIEW_DIR="$TMP/ghview"
  mkdir -p "$GHVIEW_DIR"
  export STUBLOG GHVIEW_DIR
  export PATH="$TMP/bin:$PATH"
}

# gh_view <operand> <number> <headRefName> <state> <mergedAt>
gh_view() {
  jq -nc --argjson n "$2" --arg h "$3" --arg s "$4" --arg m "$5" \
    '{number:$n,headRefName:$h,state:$s,mergedAt:(if $m == "" then null else $m end)}' >"$GHVIEW_DIR/view-$1.json"
}

# asst <file> <sid> <cwd> <branch> <id> <ts> <k> <output> [tool_use array json]
asst() {
  jq -nc --arg s "$2" --arg c "$3" --arg b "$4" --arg i "$5" --arg t "$6" --argjson k "$7" --argjson o "$8" \
    --argjson tool "${9:-[]}" \
    '{type:"assistant",uuid:("u-"+$i),timestamp:$t,cwd:$c,sessionId:$s,gitBranch:$b,
      message:{id:$i,model:"claude-opus-5-5",role:"assistant",
        usage:{input_tokens:$k,cache_creation_input_tokens:(110*$k),cache_read_input_tokens:(1000*$k),output_tokens:$o,
          cache_creation:{ephemeral_5m_input_tokens:(10*$k),ephemeral_1h_input_tokens:(100*$k)}},
        content:($tool + [{type:"text",text:"ok"}])}}' >>"$1"
}

skill_tool() { jq -nc --arg n "$1" '[{type:"tool_use",id:"tu",name:"Skill",input:{skill:$n}}]'; }
write_tool() { jq -nc --arg p "$1" '[{type:"tool_use",id:"tw",name:"Write",input:{file_path:$p,content:"x"}}]'; }

# tpath <sid> [worktree path]: the transcript file for a session, dir created.
tpath() {
  local d
  d="$PROJ/$(enc "${2:-$REPO}")"
  mkdir -p "$d"
  printf '%s/%s.jsonl' "$d" "$1"
}

# mk_worktree <dirname under .claude/worktrees> <branch>: a real linked worktree
# (tree roots come from `git worktree list`); prints its path.
mk_worktree() {
  local wt="$REPO/.claude/worktrees/$1"
  git -C "$REPO" worktree add -q -b "$2" "$wt" >/dev/null 2>&1
  printf '%s' "$wt"
}

flush1() {
  bash "$REPO/.gaia/scripts/usage-flush.sh" --session "$1" --finished-main \
    --projects-root "$PROJ" --main-root "$REPO" "${@:2}"
}

u() { bash "$REPO/.gaia/scripts/usage.sh" "$@" --main-root "$REPO" --projects-root "$PROJ"; }

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
    | reduce .[] as $s ({}; reduce ($s.by_model | to_entries[]) as $m (.;
        reduce ($m.value | to_entries[]) as $b (.; .[$s.key][$m.key][$b.key] += $b.value)))' "$TD/usage.jsonl")"
  [ "$got" = "$want" ] || { printf 'want:\n%s\ngot:\n%s\n' "$want" "$got" >&2; return 1; }
}

# cursors_settled <n>: the cursor cache names n files, each at its file's size.
cursors_settled() {
  local p off n=0
  [ -f "$TD/usage-cursors.json" ] || return 1
  while IFS=$'\t' read -r p off; do
    [ "$off" -eq "$(wc -c <"$p" | tr -d ' ')" ] || return 1
    n=$((n + 1))
  done < <(jq -r '.files | to_entries[] | "\(.key)\t\(.value.offset)"' "$TD/usage-cursors.json" 2>/dev/null)
  [ "$n" -eq "$1" ]
}

# quiesce <n>: every detached flusher of this test has exited and n cursors are
# at their files' ends. Bounded at 20 s.
quiesce() {
  local i=0
  while [ "$i" -lt 200 ]; do
    if ! pgrep -f "$TMP/.*usage-flush" >/dev/null 2>&1 && cursors_settled "$1"; then return 0; fi
    sleep 0.1
    i=$((i + 1))
  done
  echo "no quiescence: $(cat "$TD/usage-cursors.json" 2>/dev/null)" >&2
  return 1
}

hook_payload() { # <event> <sid> <transcript>
  jq -nc --arg e "$1" --arg s "$2" --arg t "$3" \
    '{hook_event_name:$e,session_id:$s,transcript_path:$t,stop_hook_active:false}'
}

merge_payload() { # <command> <sid> <transcript>
  jq -nc --arg c "$1" --arg s "$2" --arg t "$3" \
    '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:"",stderr:""},session_id:$s,transcript_path:$t}'
}

# fire <hook basename> <payload>: the real hook in the tmp repo, cwd = the repo.
fire() {
  run bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$REPO" "$2" "$REPO/.claude/hooks/$1"
}

# seed_debt: the two-session `debt/123-slug` scenario, transcripts only.
# s-m main checkout: k1/o5 + k2/o10; s-w worktree: k4/o20. Sets WT.
seed_debt() {
  WT="$(mk_worktree debt+123-slug debt/123-slug)"
  TP_M="$(tpath s-m)"
  TP_W="$(tpath s-w "$WT")"
  asst "$TP_M" s-m "$REPO" debt/123-slug m1 2026-10-01T09:00:01.000Z 1 5
  asst "$TP_M" s-m "$REPO" debt/123-slug m2 2026-10-01T09:00:02.000Z 2 10
  asst "$TP_W" s-w "$WT" worktree-debt+123-slug m3 2026-10-01T09:30:01.000Z 4 20
}

DEBT_TOTALS='{"branch:debt/123-slug":{"claude-opus-5-5":{"cache_read":7000,"cache_write_1h":700,"cache_write_5m":70,"fresh_input":7,"output":35}}}'

# seed_early: an older session that makes the coverage start 2026-09-28.
seed_early() {
  local tp
  tp="$(tpath s-early)"
  asst "$tp" s-early "$REPO" fix/early e1 2026-09-28T08:00:01.000Z 1 1
}

# derive_subs: the subcommand names in usage.sh's dispatch `case`, sorted, one
# per line. The `""|-h|--help` and `*` arms do not start with a bare name.
derive_subs() {
  awk '/^case "\$SUB" in/ { p = 1; next } /^esac/ { p = 0 } p && /^  [a-z][a-z-]*\)/ { sub(/\).*/, ""); gsub(/ /, ""); print }' \
    "$1" | sort
}

# sub_args <name>: one representative argument list per subcommand, words split
# on purpose. An unknown name fails, so a subcommand added to the dispatch
# without an entry here turns the loops that use it red.
sub_args() {
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

