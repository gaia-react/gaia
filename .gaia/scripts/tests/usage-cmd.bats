#!/usr/bin/env bats
#
# The `usage.sh` command surface (SPEC-087): write refusals and exit codes,
# `link --pr` / `link --merge` / `pr-branch`, the hooks-not-registered and
# unflushed markers, the jq-absent inactive line, and the frozen subcommand set.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/usage-cmd.bats

bats_require_minimum_version 1.5.0

setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  USAGE="$SCRIPTS/usage.sh"
  FX="$BATS_TEST_DIRNAME/fixtures/usage/resolve"
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  MAIN="$TMP/main"
  TD="$MAIN/.gaia/local/telemetry"
  PROJ="$TMP/projects"
  mkdir -p "$MAIN"
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false commit -q --allow-empty -m init
  register_hooks
  mkdir -p "$TD" "$PROJ"
  export GAIA_RATES_FEED_DISABLE=1 GAIA_RATES_STATE_DIR="$TMP/rates-state"
  unset CLAUDE_CODE_SESSION_ID GAIA_TALLY_PROJECTS_ROOT
}

register_hooks() {
  mkdir -p "$MAIN/.claude"
  cat >"$MAIN/.claude/settings.json" <<'EOF'
{"hooks": {
  "Stop": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/usage-capture.sh"}]}],
  "SessionStart": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/usage-capture.sh"}]}]
}}
EOF
}

u() { bash "$USAGE" "$@" --main-root "$MAIN" --rate-table "$FX/rates-a.json" --projects-root "$PROJ"; }

has_line() { grep -qxF -- "$1" <<<"$output" || { printf 'missing line: [%s]\nin:\n%s\n' "$1" "$output" >&2; return 1; }; }

seed_links() {
  printf '%s\n' '{"schema_version":1,"kind":"edge","child":"spec:SPEC-001","parent":"research:a","source":"link-command","ts":"2026-10-01T00:00:00Z","session_id":null,"sidechain":false}' >"$TD/links.jsonl"
  cp "$TD/links.jsonl" "$TMP/links-before"
}

# ---------- write refusals ----------

@test "link: a ref failing the grammar exits 2 and writes nothing" {
  seed_links
  run u link spec:spec-001 research:x
  [ "$status" -eq 2 ]
  cmp "$TMP/links-before" "$TD/links.jsonl"
  run u link spec:SPEC-002 'research:../x'
  [ "$status" -eq 2 ]
  cmp "$TMP/links-before" "$TD/links.jsonl"
}

@test "declare: only research: and init: refs; a branch ref exits 2 and writes nothing" {
  run u declare branch:fix/foo --session s1
  [ "$status" -eq 2 ]
  [ ! -e "$TD/usage.jsonl" ]
  run u declare research:x --session s1 --at 2026-10-01T09:00:00Z
  [ "$status" -eq 0 ]
  jq -e -s 'length == 1 and .[0].kind == "binding" and .[0].type == "declare" and .[0].ref == "research:x"
    and .[0].session_id == "s1" and .[0].ts == "2026-10-01T09:00:00Z" and .[0].source == "declare-command"
    and .[0].invoking_session_id == null and .[0].sidechain == false and .[0].schema_version == 1' "$TD/usage.jsonl"
}

@test "link: a cycle exits 1, names the path, and writes nothing" {
  seed_links
  run u link research:a spec:SPEC-001
  [ "$status" -eq 1 ]
  grep -qxF '  cycle: research:a -> spec:SPEC-001 -> research:a' <<<"$output"
  cmp "$TMP/links-before" "$TD/links.jsonl"
  run u link research:a research:a
  [ "$status" -eq 1 ]
  cmp "$TMP/links-before" "$TD/links.jsonl"
}

@test "link: a cycle through a derived branch edge is refused too" {
  printf '%s\n' '{"schema_version":1,"kind":"segment","key":"branch:plan/spec-005-x","session_id":"s","inherit":false,"first_ts":"2026-10-01T00:00:00Z","last_ts":"2026-10-01T00:00:00Z","messages":1,"by_model":{}}' >"$TD/usage.jsonl"
  run u link spec:SPEC-005 branch:plan/spec-005-x
  [ "$status" -eq 1 ]
  [ ! -e "$TD/links.jsonl" ]
}

@test "link: a held ledger lock exits 75 and writes nothing" {
  mkdir "$TD/specs.lock.d"
  GAIA_LEDGER_LOCK_FORCE_FALLBACK=1 GAIA_LEDGER_LOCK_TIMEOUT_SECS=1 GAIA_LEDGER_LOCK_POLL_SECS=0.1 \
    run u link branch:fix/foo research:x
  [ "$status" -eq 75 ]
  grep -qF 'nothing was written' <<<"$output"
  [ ! -e "$TD/links.jsonl" ]
  rmdir "$TD/specs.lock.d"
  GAIA_LEDGER_LOCK_FORCE_FALLBACK=1 run u link branch:fix/foo research:x
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$TD/links.jsonl" | tr -d ' ')" -eq 1 ]
}

@test "lineage: an empty or missing path exits 2 with the no-SPEC line and writes nothing" {
  run u lineage ""
  [ "$status" -eq 2 ]
  has_line "usage lineage: no SPEC file at ''"
  run u lineage /nonexistent/SPEC.md
  [ "$status" -eq 2 ]
  has_line "usage lineage: no SPEC file at '/nonexistent/SPEC.md'"
  [ ! -e "$TD/links.jsonl" ]
}

# ---------- link --pr, link --merge, pr-branch ----------

@test "link --pr / --merge: raw worktree spellings normalize; repeats and the default branch write nothing; pr-branch follows tombstones" {
  run u link --pr 42 --branch worktree-debt+42-fix
  [ "$status" -eq 0 ]
  [ "$(jq -sc '[.[] | [.kind, .child, .parent]]' "$TD/links.jsonl")" = '[["edge","pr:42","branch:debt/42-fix"]]' ]
  run u link --pr 42 --branch worktree-debt+42-fix
  [ "$status" -eq 0 ]
  run u link --pr 43 --branch main
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$TD/links.jsonl" | tr -d ' ')" -eq 1 ]
  run u link --merge 42 --branch worktree-debt+42-fix --merged-at 2026-10-02T00:00:00Z
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$TD/links.jsonl" | jq -c '[.kind, .pr, .key, .merged_at, .source]')" = '["merge",42,"branch:debt/42-fix","2026-10-02T00:00:00Z","link-command"]' ]
  run u pr-branch 42
  [ "$status" -eq 0 ]
  [ "$output" = "branch:debt/42-fix" ]
  run u unlink pr:42 branch:debt/42-fix
  [ "$status" -eq 0 ]
  run u pr-branch 42
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "link --merge --key: a hashed key is written verbatim; a key with a dot-dot segment exits 2" {
  run u link --merge 43 --key 'branch:%0123456789abcdef' --merged-at 2026-10-03T00:00:00Z
  [ "$status" -eq 0 ]
  [ "$(jq -r .key "$TD/links.jsonl")" = 'branch:%0123456789abcdef' ]
  cp "$TD/links.jsonl" "$TMP/links-before"
  run u link --merge 44 --key 'branch:../x'
  [ "$status" -eq 2 ]
  run u link --merge 44 --key 'research:x'
  [ "$status" -eq 2 ]
  cmp "$TMP/links-before" "$TD/links.jsonl"
}

@test "pr --branch with no number renders the numberless header with a window through now" {
  printf '%s\n' '{"schema_version":1,"kind":"segment","key":"branch:fix/bar","session_id":"s","inherit":false,"first_ts":"2026-10-01T00:00:00Z","last_ts":"2026-10-01T00:00:00Z","messages":1,"by_model":{"claude-opus-5-5":{"fresh_input":100000,"output":10000}}}' >"$TD/usage.jsonl"
  run u pr --branch fix/bar
  [ "$status" -eq 0 ]
  has_line "[PR cost] pr:? branch:fix/bar"
  has_line "  tokens: 110,000 (fresh 100,000, cache write 0, cache read 0, output 10,000)"
  has_line "  window: after start of record through now"
}

# ---------- UAT-025 markers ----------

@test "UAT-025: without the capture hooks registered, every readout prints the marker in place of figures" {
  cp "$FX/prs/usage.jsonl" "$FX/prs/links.jsonl" "$TD/"
  rm "$MAIN/.claude/settings.json"
  local sub
  for sub in "pr 501" "initiative research:topic-a-2026-10-01" reconcile; do
    # shellcheck disable=SC2086
    run u $sub
    [ "$status" -eq 0 ]
    has_line "  ! capture hooks not registered"
    grep -qE 'tokens[: ][^0-9]*[0-9]' <<<"$output" && { printf 'figure printed for %s:\n%s\n' "$sub" "$output" >&2; return 1; }
  done
  true
}

# mk_transcript <bytes>: one candidate transcript for the main checkout.
mk_transcript() {
  local dir
  dir="$PROJ/$(printf '%s' "$MAIN" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$dir"
  head -c "$1" /dev/zero | tr '\0' 'x' >"$dir/sess-1.jsonl"
  TRANSCRIPT="$dir/sess-1.jsonl"
}

# cursors <offset>: the cursor cache in its frozen shape, one file entry.
cursors() {
  jq -n --arg p "$TRANSCRIPT" --argjson o "$1" '{schema_version: 1, ledger_bytes: 0,
    files: {($p): {session_id: "sess-1", role: "main", offset: $o, size: $o}}, pairs: {}}' >"$TD/usage-cursors.json"
}

@test "UAT-025: a transcript larger than its cursor prints the unflushed marker beside the figure; a flushed one does not" {
  cp "$FX/prs/usage.jsonl" "$FX/prs/links.jsonl" "$TD/"
  mk_transcript 1000
  cursors 400
  run u pr 503
  has_line "  tokens: 440,000 (fresh 400,000, cache write 0, cache read 0, output 40,000)"
  has_line "  ! unflushed: 1 file(s), 600 bytes not yet recorded"
  run u initiative issue:200
  has_line "  ! unflushed: 1 file(s), 600 bytes not yet recorded"
  cursors 1000
  run u pr 503
  has_line "  tokens: 440,000 (fresh 400,000, cache write 0, cache read 0, output 40,000)"
  grep -qF 'unflushed' <<<"$output" && return 1
  true
}

# ---------- UAT-013 jq absent ----------

@test "UAT-013: with jq absent every subcommand prints the inactive line, exits 0, and creates no telemetry" {
  local bin="$TMP/nojq" t sub
  mkdir -p "$bin"
  for t in dirname date git cat mkdir mktemp rm sed awk tr head find xargs stat shasum sha256sum; do
    if command -v "$t" >/dev/null 2>&1; then ln -s "$(command -v "$t")" "$bin/$t"; fi
  done
  [ ! -e "$bin/jq" ]
  rm -rf "$MAIN/.gaia/local"
  local subs=(
    "link branch:fix/foo research:x" "unlink branch:fix/foo research:x" "lineage $TMP/none.md"
    "declare research:x --session s1" "pr 1" "pr-branch 1" "initiative research:x" "reconcile"
  )
  [ "${#subs[@]}" -eq 8 ]
  for sub in "${subs[@]}"; do
    # shellcheck disable=SC2086
    run env PATH="$bin" "$BASH" "$USAGE" $sub --main-root "$MAIN" --projects-root "$PROJ"
    [ "$status" -eq 0 ]
    [ "$output" = "usage tracking inactive: jq not found" ] || { printf '%s: [%s]\n' "$sub" "$output" >&2; return 1; }
  done
  [ ! -e "$MAIN/.gaia/local" ]
}

# ---------- help and the frozen subcommand set ----------

@test "no arguments and --help print the summary and exit 0; an unknown subcommand exits 2" {
  run bash "$USAGE"
  [ "$status" -eq 0 ]
  grep -qF 'usage: bash .gaia/scripts/usage.sh <subcommand>' <<<"$output"
  run bash "$USAGE" --help
  [ "$status" -eq 0 ]
  run bash "$USAGE" frobnicate
  [ "$status" -eq 2 ]
}

@test "subcommand set: the dispatch arms are exactly the frozen names" {
  local arms
  arms="$(awk '/^case "\$SUB" in$/ { c = 1; next } c && /^esac$/ { exit }
    c && /^  [^ ]/ { sub(/^  /, ""); sub(/\).*/, ""); print }' "$USAGE" |
    grep -vxF -e '"" | -h | --help' -e '*' | sort)"
  [ "$(printf '%s\n' "$arms" | wc -l | tr -d ' ')" -eq 8 ]
  [ "$arms" = "$(printf '%s\n' link unlink lineage declare pr pr-branch initiative reconcile | sort)" ]
  # Both excluded arms are present, so the exclusion above removed something real.
  [ "$(awk '/^case "\$SUB" in$/ { c = 1; next } c && /^esac$/ { exit } c' "$USAGE" | grep -cE '^  ("" \| -h \| --help|\*)\)')" -eq 2 ]
}
