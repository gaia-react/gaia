#!/usr/bin/env bats
#
# Research attribution path form (SPEC-088 UAT-017): a research Write binds
# session spend to research:<topic>-<date> only when it goes through the main
# checkout's absolute path. The same Write through a linked worktree's
# .gaia/local symlink binds nothing; `usage.sh declare` is the route that does.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/usage-research-binding.bats
#
# The ledger is built by running usage-flush.sh over transcripts this suite
# writes (never by hand-writing ledger files), and every assertion reads only
# `usage.sh initiative` output. Token totals are hand-added from the fixture
# usage blocks: sess-wt = (100+10) + (200+20) = 330, sess-main =
# (1000+100) + (2000+200) = 3300 (no cache tokens, so total = input + output).

bats_require_minimum_version 1.5.0

setup_file() {
  REAL="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd -P)"
  export REAL
  ls -la "$REAL/.gaia/local/telemetry" >"$BATS_FILE_TMPDIR/real-before" 2>&1 || true
}

setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  USAGE="$SCRIPTS/usage.sh"
  FLUSH="$SCRIPTS/usage-flush.sh"
  RATES="$BATS_TEST_DIRNAME/fixtures/usage/resolve/rates-a.json"
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  MAIN="$TMP/main"
  WT="$TMP/wt"
  PROJ="$TMP/projects"
  TEL="$MAIN/.gaia/local/telemetry"
  export GAIA_RATES_FEED_DISABLE=1 GAIA_RATES_STATE_DIR="$TMP/rates-state"
  unset CLAUDE_CODE_SESSION_ID GAIA_TALLY_PROJECTS_ROOT GITHUB_ACTIONS
  mkdir -p "$MAIN" "$MAIN/.gaia/local/research" "$PROJ/$(enc "$MAIN")"
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false \
    commit -q --allow-empty -m init
  git -C "$MAIN" worktree add -q -b side "$WT"
  register_hooks "$MAIN"
  # Every call below runs from outside any repo, so a missing --main-root
  # fails instead of resolving the real checkout.
  cd "$BATS_TEST_TMPDIR" || return 1
}

enc() { printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'; }

register_hooks() {
  mkdir -p "$1/.claude"
  cat >"$1/.claude/settings.json" <<'JSON'
{"hooks": {
  "Stop": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/usage-capture.sh"}]}],
  "SessionStart": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/usage-capture.sh"}]}]
}}
JSON
}

# transcript <sid> <input-a> <output-a> <input-b> <output-b> <write-path>:
# one user line, then two assistant messages; the second carries the Write.
# Prints the transcript path.
transcript() {
  local sid="$1" f
  f="$PROJ/$(enc "$MAIN")/$sid.jsonl"
  {
    jq -nc --arg sid "$sid" --arg cwd "$MAIN" \
      '{type:"user",uuid:"u0",timestamp:"2026-10-01T00:00:00.000Z",cwd:$cwd,sessionId:$sid,gitBranch:"main",message:{role:"user",content:"start"}}'
    jq -nc --arg sid "$sid" --arg cwd "$MAIN" --argjson i "$2" --argjson o "$3" \
      '{type:"assistant",uuid:"u-m1",timestamp:"2026-10-01T00:00:01.000Z",cwd:$cwd,sessionId:$sid,gitBranch:"main",message:{id:"m1",model:"claude-opus-5-5",role:"assistant",usage:{input_tokens:$i,cache_creation_input_tokens:0,cache_read_input_tokens:0,output_tokens:$o},content:[{type:"text",text:"ok"}]}}'
    jq -nc --arg sid "$sid" --arg cwd "$MAIN" --argjson i "$4" --argjson o "$5" --arg p "$6" \
      '{type:"assistant",uuid:"u-m2",timestamp:"2026-10-01T00:00:02.000Z",cwd:$cwd,sessionId:$sid,gitBranch:"main",message:{id:"m2",model:"claude-opus-5-5",role:"assistant",usage:{input_tokens:$i,cache_creation_input_tokens:0,cache_read_input_tokens:0,output_tokens:$o},content:[{type:"tool_use",id:"tu",name:"Write",input:{file_path:$p,content:"x"}}]}}'
    jq -nc --arg sid "$sid" --arg cwd "$MAIN" \
      '{type:"user",uuid:"u1",timestamp:"2026-10-01T00:00:03.000Z",cwd:$cwd,sessionId:$sid,gitBranch:"main",message:{role:"user",content:[{type:"tool_result",tool_use_id:"tu",content:"done"}]}}'
  } >"$f"
  touch -t 202001010000 "$f"
  printf '%s' "$f"
}

flush() {
  bash "$FLUSH" --session "$1" --transcript "$2" --finished-main \
    --projects-root "$PROJ" --main-root "$MAIN" --telemetry-dir "$TEL"
}

# make_wt_session <write-path>: sess-wt, 330 tokens.
make_wt_session() { flush sess-wt "$(transcript sess-wt 100 10 200 20 "$1")"; }
# make_main_session <write-path>: sess-main, 3300 tokens.
make_main_session() { flush sess-main "$(transcript sess-main 1000 100 2000 200 "$1")"; }

init() {
  bash "$USAGE" initiative "$1" --main-root "$MAIN" --rate-table "$RATES" --projects-root "$PROJ"
}

has_line() { grep -qxF -- "$1" <<<"$output" || { printf 'missing line: [%s]\nin:\n%s\n' "$1" "$output" >&2; return 1; }; }

X="research/topic-x-2026-10-01/README.md"

@test "a main-path Write binds its session; a worktree-path Write binds nothing" {
  make_wt_session "$WT/.gaia/local/$X"
  make_main_session "$MAIN/.gaia/local/$X"
  run init research:topic-x-2026-10-01
  [ "$status" -eq 0 ]
  has_line "  total (distinct segments): tokens 3,300  est. \$0.01"
}

@test "positive control: only the worktree-path session is flushed and it reports no spend" {
  make_wt_session "$WT/.gaia/local/$X"
  run init research:topic-x-2026-10-01
  [ "$status" -eq 0 ]
  has_line "  total (distinct segments): tokens 0  est. \$0.00"
}

@test "positive control: the same session with a main-path Write reports its tokens" {
  make_wt_session "$MAIN/.gaia/local/$X"
  run init research:topic-x-2026-10-01
  [ "$status" -eq 0 ]
  has_line "  total (distinct segments): tokens 330  est. \$0.00"
}

@test "declare binds a session's spend to a research initiative without a Write" {
  make_wt_session "$WT/.gaia/local/$X"
  run bash "$USAGE" declare research:topic-y-2026-10-01 --session sess-wt \
    --main-root "$MAIN" --telemetry-dir "$TEL"
  [ "$status" -eq 0 ]
  run init research:topic-y-2026-10-01
  [ "$status" -eq 0 ]
  has_line "  total (distinct segments): tokens 330  est. \$0.00"
}

@test "the real checkout's telemetry directory is untouched by this suite" {
  ls -la "$REAL/.gaia/local/telemetry" >"$BATS_TEST_TMPDIR/real-after" 2>&1 || true
  # Compare names only: this file is the suite's last case, but a sibling
  # run may legitimately touch mtimes; new or removed entries are the failure.
  [ "$(awk '{print $NF}' "$BATS_FILE_TMPDIR/real-before")" = "$(awk '{print $NF}' "$BATS_TEST_TMPDIR/real-after")" ]
}
