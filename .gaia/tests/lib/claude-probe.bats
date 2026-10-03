#!/usr/bin/env bats
# Tests for the Claude probe harness in .gaia/tests/claude-probe/ (SPEC-092
# Phase 0, UAT-001): the expectation table's schema and floor check, the pure
# comparator, the fixture-tree builder, and run-probe.sh's refusals, cost cap
# and observation sourcing. No test calls the real Claude: run-probe.sh runs
# against a stub `claude` on PATH that emits canned stream-json.
#
# The comparator cases run the committed table with --only, so they judge a
# few real rows against hand-built evidence; the floor and schema checks still
# read the whole table.
#
# Assertion style follows .claude/rules/bats-assertions.md: POSIX `[ ]` and
# `grep -qF` for non-final assertions, `&& return 1` for absence checks.

setup_file() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HARNESS="$REPO_ROOT/.gaia/tests/claude-probe"
  export REPO_ROOT HARNESS
  FIXTURE_TREE="$BATS_FILE_TMPDIR/fixture-tree"
  bash "$HARNESS/build-fixture-tree.sh" "$FIXTURE_TREE" >/dev/null
  export FIXTURE_TREE
}

setup() {
  TABLE="$HARNESS/expectations.json"
  BIN="$BATS_TEST_TMPDIR/bin"
  STUB_LOG="$BATS_TEST_TMPDIR/stub-calls"
  mkdir -p "$BIN"
  export STUB_LOG
  PATH="$BIN:$PATH"
}

# A stub `claude`: logs each call, plays the SessionStart probe hook (one
# line tagged for the launch dir's settings file), then prints an init event,
# an assistant message whose TEXT claims a rule loaded, and a result carrying
# $STUB_COST as total_cost_usd. It never writes an InstructionsLoaded line.
write_claude_stub() {
  cat >"$BIN/claude" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "0.0.0 (stub)"; exit 0; fi
printf '%s\n' "$*" >>"$STUB_LOG"
tag=root-settings
case "$PWD" in */frontend) tag=frontend-settings ;; esac
if [ -n "${GAIA_PROBE_LOG:-}" ]; then
  printf '{"event":"SessionStart","tag":"%s","source":"startup","claude_project_dir":"%s","pwd":"%s","toplevel":"%s"}\n' \
    "$tag" "$PWD" "$PWD" "$(git rev-parse --show-toplevel)" >>"$GAIA_PROBE_LOG"
fi
printf '{"type":"system","subtype":"init","session_id":"stub","skills":[],"agents":[],"mcp_servers":[]}\n'
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"CLAUDE.md loaded. I have read CLAUDE.md and every rule."}]}}\n'
printf '{"type":"result","subtype":"success","total_cost_usd":%s,"permission_denials":[]}\n' "${STUB_COST:-0.01}"
STUB
  chmod +x "$BIN/claude"
}

# table_repo <dir>: a git repo holding the committed table at its real path.
table_repo() {
  mkdir -p "$1/.gaia/tests/claude-probe"
  cp "$TABLE" "$1/.gaia/tests/claude-probe/expectations.json"
  git -C "$1" init -q
  git -C "$1" add -A
  git -C "$1" -c user.name=probe -c user.email=probe@example.invalid commit -q -m "probe table"
}

# write_evidence <dir> <reps>: evidence for the root launch's session_start
# scenario that matches every `root-root-*` row in the committed table.
write_evidence() {
  local evidence="$1" reps="$2" rep scenario root="/probe/target"
  local snapshot="$evidence/snapshot/root"
  mkdir -p "$snapshot/files/.claude/rules"
  printf '%s\n' CLAUDE.md .claude/rules/always.md .claude/rules/scoped.md \
    .claude/skills/alpha/SKILL.md .claude/commands/tidy.md .claude/agents/helper.md \
    .claude/settings.json >"$snapshot/tree.txt"
  printf '# Always\n' >"$snapshot/files/.claude/rules/always.md"
  printf -- "---\npaths:\n  - 'app/**'\n---\n\n# Scoped\n" >"$snapshot/files/.claude/rules/scoped.md"
  cat >"$snapshot/files/.claude/settings.json" <<'SETTINGS'
{"permissions": {"deny": ["Edit(.env)"]},
 "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "bash .claude/hooks/guard.sh"}]}]}}
SETTINGS
  jq -n --argjson reps "$reps" '{reps: $reps, expectations_commit: "0000000", table_sha256: null}' >"$evidence/meta.json"
  for rep in $(seq 1 "$reps"); do
    scenario="$evidence/rep-$rep/root/session-start"
    mkdir -p "$scenario"
    jq -n --arg root "$root" '{launch: "root", trigger: "session_start", launch_root: $root, launch_directory: $root}' >"$scenario/scenario.json"
    {
      printf '{"event":"SessionStart","tag":"root-settings","source":"startup","claude_project_dir":"%s","pwd":"%s","toplevel":"%s"}\n' "$root" "$root" "$root"
      printf '{"event":"InstructionsLoaded","tag":"root-settings","file_path":"%s/CLAUDE.md","load_reason":"session_start"}\n' "$root"
      printf '{"event":"InstructionsLoaded","tag":"root-settings","file_path":"%s/.claude/rules/always.md","load_reason":"session_start"}\n' "$root"
    } >"$scenario/probe.jsonl"
    {
      printf '{"type":"system","subtype":"init","session_id":"s%s","skills":["alpha"],"slash_commands":["tidy","compact"],"agents":["helper","general-purpose"],"mcp_servers":[]}\n' "$rep"
      printf '{"type":"result","subtype":"success","total_cost_usd":0.01,"permission_denials":[]}\n'
    } >"$scenario/stream-1.jsonl"
  done
}

# --- table check -------------------------------------------------------------

@test "the committed table passes the schema, floor and root-deny checks" {
  run node "$HARNESS/compare.mjs" --check-table "$TABLE" --root-settings "$REPO_ROOT/.claude/settings.json"
  [ "$status" -eq 0 ]
  grep -q '^OK ' <<<"$output"
}

@test "deleting the rows behind any one floor item fails the check and names that item" {
  local floor_map item_count=0 item_id row_ids
  floor_map="$(node "$HARNESS/compare.mjs" --floor-map "$TABLE")"
  # Derived from the comparator's own floor list, so a new item is covered
  # without editing this test; an empty map would make the loop vacuous.
  [ -n "$floor_map" ]
  while IFS="$(printf '\t')" read -r item_id row_ids; do
    item_count=$((item_count + 1))
    [ -n "$row_ids" ] || { echo "floor item $item_id has no row in the committed table" >&2; return 1; }
    jq --arg ids "$row_ids" '.rows |= map(select(.id as $id | ($ids | split(",") | index($id)) | not))' \
      "$TABLE" >"$BATS_TEST_TMPDIR/table.json"
    run node "$HARNESS/compare.mjs" --check-table "$BATS_TEST_TMPDIR/table.json"
    [ "$status" -eq 1 ] || { echo "deleting $row_ids did not fail the check" >&2; return 1; }
    grep -qF -- "MISSING_FLOOR $item_id:" <<<"$output" || { echo "message does not name $item_id: $output" >&2; return 1; }
  done <<<"$floor_map"
  [ "$item_count" -gt 0 ]
}

@test "a row missing a schema key fails the check" {
  jq '.rows[0] |= del(.source)' "$TABLE" >"$BATS_TEST_TMPDIR/table.json"
  run node "$HARNESS/compare.mjs" --check-table "$BATS_TEST_TMPDIR/table.json"
  [ "$status" -eq 1 ]
  grep -qF "missing key(s) source" <<<"$output"
}

@test "a root Edit deny that no floor row exercises fails the check" {
  jq '.permissions.deny += ["Edit(secrets.txt)"]' "$REPO_ROOT/.claude/settings.json" >"$BATS_TEST_TMPDIR/settings.json"
  run node "$HARNESS/compare.mjs" --check-table "$TABLE" --root-settings "$BATS_TEST_TMPDIR/settings.json"
  [ "$status" -eq 1 ]
  grep -qF "MISSING_FLOOR deny-frontend: no frontend floor row exercises root deny Edit(secrets.txt)" <<<"$output"
}

# --- comparator --------------------------------------------------------------

@test "compare exits 0 when every repetition matches" {
  write_evidence "$BATS_TEST_TMPDIR/evidence" 3
  run node "$HARNESS/compare.mjs" "$TABLE" "$BATS_TEST_TMPDIR/evidence" --only 'root-root-*'
  [ "$status" -eq 0 ]
  grep -qF "SUMMARY floor_mismatches=0 other_mismatches=0 unlisted=0 reps=3" <<<"$output"
}

@test "compare exits 1 and prints MISMATCH when one repetition disagrees on one row" {
  write_evidence "$BATS_TEST_TMPDIR/evidence" 3
  grep -vF '.claude/rules/always.md' "$BATS_TEST_TMPDIR/evidence/rep-2/root/session-start/probe.jsonl" >"$BATS_TEST_TMPDIR/probe.jsonl"
  mv "$BATS_TEST_TMPDIR/probe.jsonl" "$BATS_TEST_TMPDIR/evidence/rep-2/root/session-start/probe.jsonl"
  run node "$HARNESS/compare.mjs" "$TABLE" "$BATS_TEST_TMPDIR/evidence" --only 'root-root-*'
  [ "$status" -eq 1 ]
  grep -qxF "MISMATCH root-root-always-rules@.claude/rules/always.md rep=2 expected=loaded observed=not_loaded" <<<"$output"
  # The other repetitions still match, so only rep 2 is reported.
  grep -qF "rep=1 " <<<"$output" && return 1
  grep -qF "rep=3 " <<<"$output" && return 1
  true
}

@test "compare exits 1 and prints UNLISTED for an observed skill no row covers" {
  write_evidence "$BATS_TEST_TMPDIR/evidence" 3
  printf '%s\n' backend/.claude/skills/rogue/SKILL.md >>"$BATS_TEST_TMPDIR/evidence/snapshot/root/tree.txt"
  jq -c 'if .subtype == "init" then .skills += ["rogue"] else . end' \
    "$BATS_TEST_TMPDIR/evidence/rep-1/root/session-start/stream-1.jsonl" >"$BATS_TEST_TMPDIR/stream.jsonl"
  mv "$BATS_TEST_TMPDIR/stream.jsonl" "$BATS_TEST_TMPDIR/evidence/rep-1/root/session-start/stream-1.jsonl"
  run node "$HARNESS/compare.mjs" "$TABLE" "$BATS_TEST_TMPDIR/evidence" --only 'root-root-*'
  [ "$status" -eq 1 ]
  grep -qxF "UNLISTED skill rogue launch=root" <<<"$output"
}

@test "compare exits 1 with EMPTY when a row's expansion finds nothing" {
  write_evidence "$BATS_TEST_TMPDIR/evidence" 1
  grep -vF SKILL.md "$BATS_TEST_TMPDIR/evidence/snapshot/root/tree.txt" >"$BATS_TEST_TMPDIR/tree.txt"
  mv "$BATS_TEST_TMPDIR/tree.txt" "$BATS_TEST_TMPDIR/evidence/snapshot/root/tree.txt"
  run node "$HARNESS/compare.mjs" "$TABLE" "$BATS_TEST_TMPDIR/evidence" --only 'root-root-skills'
  [ "$status" -eq 1 ]
  grep -qF "EMPTY root-root-skills launch=root" <<<"$output"
}

@test "compare exits 2, never 0, on a malformed evidence line" {
  write_evidence "$BATS_TEST_TMPDIR/evidence" 3
  printf '{"event":"InstructionsLoaded",\n' >>"$BATS_TEST_TMPDIR/evidence/rep-3/root/session-start/probe.jsonl"
  run node "$HARNESS/compare.mjs" "$TABLE" "$BATS_TEST_TMPDIR/evidence" --only 'root-root-*'
  [ "$status" -eq 2 ]
  grep -qF "malformed evidence line" <<<"$output"
}

@test "compare exits 2 on a usage error" {
  run node "$HARNESS/compare.mjs" "$TABLE"
  [ "$status" -eq 2 ]
}

@test "a row edited after the first-run commit fails as UNCITED until it cites a run" {
  local repo="$BATS_TEST_TMPDIR/table-repo" first_run copy
  table_repo "$repo"
  first_run="$(git -C "$repo" rev-parse HEAD)"
  copy="$repo/.gaia/tests/claude-probe/expectations.json"
  write_evidence "$BATS_TEST_TMPDIR/evidence" 3

  jq '(.rows[] | select(.id == "root-root-claude-md") | .source) |= . + " (reworded)"' "$TABLE" >"$copy"
  git -C "$repo" -c user.name=probe -c user.email=probe@example.invalid commit -q -am "edit without citation"
  run node "$HARNESS/compare.mjs" "$copy" "$BATS_TEST_TMPDIR/evidence" --only 'root-root-*' --first-run-commit "$first_run"
  [ "$status" -eq 1 ]
  grep -qxF "UNCITED root-root-claude-md" <<<"$output"

  jq '(.rows[] | select(.id == "root-root-claude-md")) |= (.source += " (reworded)" | .cited_run = "evidence/2026-10-03-spike")' "$TABLE" >"$copy"
  git -C "$repo" -c user.name=probe -c user.email=probe@example.invalid commit -q -am "edit citing the run"
  run node "$HARNESS/compare.mjs" "$copy" "$BATS_TEST_TMPDIR/evidence" --only 'root-root-*' --first-run-commit "$first_run"
  [ "$status" -eq 0 ]
  grep -qF UNCITED <<<"$output" && return 1
  true
}

# --- fixture tree ------------------------------------------------------------

@test "the fixture's frontend settings carry every root PreToolUse command verbatim" {
  local root_settings="$REPO_ROOT/.claude/settings.json" frontend_settings="$FIXTURE_TREE/frontend/.claude/settings.json"
  local command_count=0 command
  while IFS= read -r command; do
    command_count=$((command_count + 1))
    jq -e --arg command "$command" '[.hooks.PreToolUse[].hooks[].command] | index($command) != null' "$frontend_settings" >/dev/null \
      || { echo "missing PreToolUse command: $command" >&2; return 1; }
  done < <(jq -r '.hooks.PreToolUse[].hooks[].command' "$root_settings")
  [ "$command_count" -gt 0 ]
  [ "$command_count" -eq "$(jq '[.hooks.PreToolUse[].hooks[]] | length' "$root_settings")" ]
}

@test "the fixture's frontend settings add additionalDirectories [..] and re-anchor every root Edit deny" {
  local frontend_settings="$FIXTURE_TREE/frontend/.claude/settings.json" deny_count=0 spec expected
  jq -e '.permissions.additionalDirectories == [".."]' "$frontend_settings" >/dev/null
  while IFS= read -r spec; do
    deny_count=$((deny_count + 1))
    case "$spec" in
      '**/'* | '//'* | \~/*) expected="Edit($spec)" ;;
      *) expected="Edit(../${spec#./})" ;;
    esac
    jq -e --arg rule "$expected" '.permissions.deny | index($rule) != null' "$frontend_settings" >/dev/null \
      || { echo "missing re-anchored deny: $expected" >&2; return 1; }
  done < <(jq -r '.permissions.deny[] | capture("^Edit\\((?<spec>.*)\\)$").spec' "$REPO_ROOT/.claude/settings.json")
  [ "$deny_count" -gt 0 ]
}

@test "the fixture is a git repo of real files with the frontend-only units under frontend/.claude" {
  git -C "$FIXTURE_TREE" rev-parse --git-dir >/dev/null
  [ -z "$(find "$FIXTURE_TREE" -path "$FIXTURE_TREE/.git" -prune -o -type l -print)" ]
  [ -f "$FIXTURE_TREE/frontend/.claude/skills/new-component/SKILL.md" ]
  [ -f "$FIXTURE_TREE/frontend/.claude/rules/tailwind.md" ]
  [ -f "$FIXTURE_TREE/frontend/.claude/agents/code-audit-frontend/cn.md" ]
  [ ! -e "$FIXTURE_TREE/.claude/skills/new-component" ]
  [ -f "$FIXTURE_TREE/.claude/agents/code-audit-frontend.md" ]
}

@test "re-injecting probe fixtures leaves exactly one probe hook per event per settings file" {
  bash "$HARNESS/inject-probe-fixtures.sh" "$FIXTURE_TREE"
  local settings_file
  for settings_file in .claude/settings.json .claude/settings.local.json frontend/.claude/settings.json frontend/.claude/settings.local.json; do
    [ "$(jq '[.hooks.SessionStart[].hooks[] | select(.command | contains("claude-probe/probe-hooks/"))] | length' "$FIXTURE_TREE/$settings_file")" -eq 1 ]
    [ "$(jq '[.hooks.PreToolUse[].hooks[] | select(.command | contains("claude-probe/probe-hooks/"))] | length' "$FIXTURE_TREE/$settings_file")" -eq 1 ]
  done
}

# --- run-probe.sh ------------------------------------------------------------

@test "run-probe refuses to start without --max-usd and names the flag" {
  write_claude_stub
  run bash "$HARNESS/run-probe.sh" --target "$FIXTURE_TREE" --evidence "$BATS_TEST_TMPDIR/evidence"
  [ "$status" -eq 2 ]
  grep -qF -- "--max-usd is required" <<<"$output"
  [ ! -s "$STUB_LOG" ]
}

@test "run-probe refuses a dirty table, names the file, and never calls claude" {
  write_claude_stub
  local repo="$BATS_TEST_TMPDIR/table-repo"
  table_repo "$repo"
  printf '\n' >>"$repo/.gaia/tests/claude-probe/expectations.json"
  run bash "$HARNESS/run-probe.sh" --target "$FIXTURE_TREE" --evidence "$BATS_TEST_TMPDIR/evidence" --max-usd 1 --table-repo "$repo"
  [ "$status" -eq 2 ]
  grep -qF ".gaia/tests/claude-probe/expectations.json is dirty or untracked" <<<"$output"
  [ ! -s "$STUB_LOG" ]
}

@test "run-probe refuses an untracked table" {
  write_claude_stub
  local repo="$BATS_TEST_TMPDIR/table-repo"
  mkdir -p "$repo/.gaia/tests/claude-probe"
  git -C "$repo" init -q
  cp "$TABLE" "$repo/.gaia/tests/claude-probe/expectations.json"
  run bash "$HARNESS/run-probe.sh" --target "$FIXTURE_TREE" --evidence "$BATS_TEST_TMPDIR/evidence" --max-usd 1 --table-repo "$repo"
  [ "$status" -eq 2 ]
  grep -qF "dirty or untracked" <<<"$output"
  [ ! -s "$STUB_LOG" ]
}

@test "run-probe refuses this checkout as a target even with a separate table repo" {
  write_claude_stub
  local repo="$BATS_TEST_TMPDIR/table-repo"
  table_repo "$repo"
  run bash "$HARNESS/run-probe.sh" --target "$REPO_ROOT" --evidence "$BATS_TEST_TMPDIR/evidence" --max-usd 1 --table-repo "$repo"
  [ "$status" -eq 2 ]
  grep -qF "shares a git directory" <<<"$output"
  [ ! -s "$STUB_LOG" ]
}

@test "run-probe records the table commit and hash before its first claude call" {
  write_claude_stub
  local repo="$BATS_TEST_TMPDIR/table-repo" evidence="$BATS_TEST_TMPDIR/evidence"
  table_repo "$repo"
  run bash "$HARNESS/run-probe.sh" --target "$FIXTURE_TREE" --evidence "$evidence" --max-usd 5 --reps 1 \
    --table-repo "$repo" --launches root --only 'root-root-claude-md'
  [ -s "$STUB_LOG" ]
  [ "$(jq -r .expectations_commit "$evidence/meta.json")" = "$(git -C "$repo" log -1 --format=%H -- .gaia/tests/claude-probe/expectations.json)" ]
  [ "$(jq -r .table_sha256 "$evidence/meta.json")" = "$(node -e 'process.stdout.write(require("node:crypto").createHash("sha256").update(require("node:fs").readFileSync(process.argv[1])).digest("hex"))' "$repo/.gaia/tests/claude-probe/expectations.json")" ]
}

@test "run-probe stops past the cost cap before the comparator runs" {
  write_claude_stub
  local repo="$BATS_TEST_TMPDIR/table-repo" evidence="$BATS_TEST_TMPDIR/evidence"
  table_repo "$repo"
  STUB_COST=0.6 run bash "$HARNESS/run-probe.sh" --target "$FIXTURE_TREE" --evidence "$evidence" --max-usd 1 --table-repo "$repo"
  [ "$status" -eq 3 ]
  grep -qF "cost cap exceeded" <<<"$output"
  # Two calls at 0.6 pass a 1.0 cap; a third would mean the cap did not stop it.
  [ "$(grep -c . "$STUB_LOG")" -eq 2 ]
  [ ! -e "$evidence/compare.txt" ]
  grep -qF SUMMARY <<<"$output" && return 1
  true
}

@test "run-probe reads no observation from model text: a claimed load with no InstructionsLoaded line is not_loaded" {
  write_claude_stub
  local repo="$BATS_TEST_TMPDIR/table-repo" evidence="$BATS_TEST_TMPDIR/evidence"
  table_repo "$repo"
  run bash "$HARNESS/run-probe.sh" --target "$FIXTURE_TREE" --evidence "$evidence" --max-usd 5 --reps 1 \
    --table-repo "$repo" --launches root --only 'root-root-claude-md'
  [ "$status" -eq 1 ]
  grep -qF "CLAUDE.md loaded" "$evidence/rep-1/root/session-start/stream-1.jsonl"
  grep -qxF "MISMATCH root-root-claude-md rep=1 expected=loaded observed=not_loaded" "$evidence/compare.txt"
}

@test "run-probe puts the target back: injected files restored and the worktree removed" {
  write_claude_stub
  local repo="$BATS_TEST_TMPDIR/table-repo" before after
  table_repo "$repo"
  before="$(git -C "$FIXTURE_TREE" status --porcelain --untracked-files=all; cat "$FIXTURE_TREE/.claude/settings.json")"
  run bash "$HARNESS/run-probe.sh" --target "$FIXTURE_TREE" --evidence "$BATS_TEST_TMPDIR/evidence" --max-usd 5 --reps 1 \
    --table-repo "$repo" --only 'fl-worktree-code-audit-frontend'
  [ -s "$STUB_LOG" ]
  after="$(git -C "$FIXTURE_TREE" status --porcelain --untracked-files=all; cat "$FIXTURE_TREE/.claude/settings.json")"
  [ "$before" = "$after" ]
  [ "$(git -C "$FIXTURE_TREE" worktree list | grep -c .)" -eq 1 ]
}
