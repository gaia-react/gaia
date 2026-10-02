#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/usage-lib.sh: the shared paths, default
# branch, repo membership, ref grammar, key derivation, locked append, and
# component-presence checks the usage ledger is built on.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   source .gaia/scripts/bats5.sh && bats5 .gaia/scripts/tests/usage-lib.bats
#
# Expected values are literals, hand-spelled in the test, so a regression in
# the library cannot be mirrored by the assertion that checks it.

bats_require_minimum_version 1.5.0

setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LIB="$SCRIPTS/usage-lib.sh"
  REPO_ROOT="$(git -C "$BATS_TEST_DIRNAME" rev-parse --show-toplevel)"
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  # shellcheck disable=SC1090
  source "$LIB"
}

# mk_repo <dir> [branch]: a one-commit repo with no remote.
mk_repo() {
  mkdir -p "$1"
  git -C "$1" init -q -b "${2:-main}"
  git -C "$1" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false \
    commit -q --allow-empty -m init
}

# key_json <raw branch> <sid> <default>: usage_key's answer, compact.
key_json() {
  local map
  map="$(gaia_usage_branch_map "$1")"
  jq -nc --arg b "$1" --arg sid "$2" --arg d "$3" --argjson bmap "$map" \
    "$GAIA_USAGE_JQ_DEFS"' usage_key($b; $sid; $d; $bmap)'
}

# ---------- 1. source-time purity and the function set ----------

@test "C6 names: the functions the file defines equal the frozen set, exactly" {
  local defined expected
  defined="$(grep -o '^gaia_usage_[a-z_]*()' "$LIB" | tr -d '()' | sort)"
  expected="$(printf '%s\n' gaia_usage_main_root gaia_usage_telemetry_dir \
    gaia_usage_default_branch gaia_usage_tree_roots gaia_usage_projects_root \
    gaia_usage_encode_path gaia_usage_candidate_dirs gaia_usage_due_files \
    gaia_usage_valid_ref gaia_usage_branch_key gaia_usage_branch_map \
    gaia_usage_append gaia_usage_inactive_reason gaia_usage_hooks_registered \
    gaia_usage_in_ci | sort)"
  [ "$(printf '%s\n' "$defined" | wc -l | tr -d ' ')" -eq 15 ]
  [ "$defined" = "$expected" ]
}

@test "sourcing under set -u with an empty PATH defines every C6 name (bash 3.2 and 5)" {
  local b fn
  for b in /bin/bash "$BASH"; do
    for fn in $(grep -o '^gaia_usage_[a-z_]*()' "$LIB" | tr -d '()'); do
      "$b" -c 'set -u; PATH=/nonexistent; source "$1"; type "$2" >/dev/null 2>&1 && [ -n "$GAIA_USAGE_JQ_DEFS" ]' _ "$LIB" "$fn" ||
        { printf '%s: %s not defined after sourcing\n' "$b" "$fn" >&2; return 1; }
    done
    "$b" -n "$LIB"
  done
}

@test "no jq reimplementation of branch normalization" {
  local n
  n="$(grep -c 'def usage_normalize' "$LIB" || true)"
  [ "$n" = 0 ]
}

@test "zsh caller: sourcing succeeds, pure functions work, sibling-backed ones return 1" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  run zsh -c 'source "$1"; gaia_usage_valid_ref issue:5 || exit 10
    [ "$(gaia_usage_encode_path "/a b")" = "-a-b" ] || exit 11
    gaia_usage_branch_map x >/dev/null && exit 12
    exit 0' _ "$LIB"
  [ "$status" -eq 0 ]
}

# ---------- 2. branch map and hash parity ----------

@test "branch map: every spelling's norm equals gaia_branch_normalize, and the fixture is non-trivial" {
  local -a raws=('fix/foo' 'worktree-debt+123-slug' 'worktree-worktree-x' 'a+b+c' 'HEAD' ''
    'release/v2.0.0-rc.1' 'worktree-agent-a109ec9e' 'feat/has space' 'feat/dollar$x'
    'main' 'worktree-plan+spec-087-x' 'a.b.c/d' "$(printf 'z%.0s' $(seq 1 130))")
  [ "${#raws[@]}" -ge 12 ]
  # shellcheck disable=SC1091
  source "$SCRIPTS/branch-name-lib.sh"
  local map r want got
  map="$(gaia_usage_branch_map "${raws[@]}")"
  [ "$(jq 'length' <<<"$map")" -eq "${#raws[@]}" ]
  for r in "${raws[@]}"; do
    want="$(gaia_branch_normalize "$r")"
    got="$(jq -r --arg r "$r" '.[$r].norm' <<<"$map")"
    [ "$got" = "$want" ] || { printf 'norm of [%s]: got [%s] want [%s]\n' "$r" "$got" "$want" >&2; return 1; }
  done
  [ "$(jq -r '.["worktree-debt+123-slug"].key' <<<"$map")" = "branch:debt/123-slug" ]
  [ "$(jq -r '.["worktree-worktree-x"].norm' <<<"$map")" = "worktree-x" ]
  [ "$(jq -r '.["a+b+c"].key' <<<"$map")" = "branch:a/b/c" ]
  [ "$(jq -r '.[""].key' <<<"$map")" = "null" ]
}

@test "branch key: a failing branch hashes to the same 16 hex gaia_hash16 prints" {
  local norm='feat/has space' want got
  want="$( (source "$SCRIPTS/token-pricing-lib.sh"; printf '%s' "$norm" | gaia_hash16) )"
  [ "${#want}" -eq 16 ]
  got="$(gaia_usage_branch_key "$norm")"
  [ "$got" = "branch:%$want" ]
  # A 129-character name fails the grammar by length alone.
  norm="$(printf 'q%.0s' $(seq 1 129))"
  want="$( (source "$SCRIPTS/token-pricing-lib.sh"; printf '%s' "$norm" | gaia_hash16) )"
  [ "$(gaia_usage_branch_key "$norm")" = "branch:%$want" ]
  [ "$(gaia_usage_branch_key "$(printf 'q%.0s' $(seq 1 128))")" = "branch:$(printf 'q%.0s' $(seq 1 128))" ]
}

@test "branch map: a spelling that starts with a dash survives intact" {
  local map
  map="$(gaia_usage_branch_map '-x' '--args')"
  [ "$(jq -r '.["-x"].norm' <<<"$map")" = "-x" ]
  [ "$(jq -r '.["--args"].norm' <<<"$map")" = "--args" ]
}

# ---------- 3. key derivation ----------

@test "key: default branch resolved through origin/HEAD keys session, never branch" {
  mk_repo "$TMP/km"
  git -C "$TMP/km" update-ref refs/remotes/origin/main HEAD
  git -C "$TMP/km" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  local d
  d="$(gaia_usage_default_branch "$TMP/km")"
  [ "$d" = main ]
  [ "$(key_json main S1 "$d")" = '{"key":"session:S1","inherit":false}' ]
  [ "$(key_json fix/foo S1 "$d")" = '{"key":"branch:fix/foo","inherit":false}' ]
  [ "$(key_json worktree-fix+bar S1 "$d")" = '{"key":"branch:fix/bar","inherit":false}' ]
}

@test "key: a master default, named by origin/HEAD, keys session and never branch:master" {
  mk_repo "$TMP/kmaster" master
  git -C "$TMP/kmaster" update-ref refs/remotes/origin/master HEAD
  git -C "$TMP/kmaster" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
  local d
  d="$(gaia_usage_default_branch "$TMP/kmaster")"
  [ "$d" = master ]
  [ "$(key_json master S2 "$d")" = '{"key":"session:S2","inherit":false}' ]
  [ "$(key_json main S2 "$d")" = '{"key":"branch:main","inherit":false}' ]
}

@test "key: HEAD and empty key session; agent worktrees inherit" {
  [ "$(key_json HEAD S3 main)" = '{"key":"session:S3","inherit":false}' ]
  [ "$(key_json '' S3 main)" = '{"key":"session:S3","inherit":false}' ]
  [ "$(key_json worktree-agent-abc123 S3 main)" = '{"key":"session:S3","inherit":true}' ]
  # A branch key is never produced for a missing gitBranch (null reaches jq as null).
  run jq -nc --argjson bmap '{}' --arg sid S3 "$GAIA_USAGE_JQ_DEFS"' usage_key(null; $sid; "main"; $bmap)'
  [ "$output" = '{"key":"session:S3","inherit":false}' ]
}

@test "key: a command-substitution branch is hashed and runs nothing" {
  cd "$TMP"
  local out
  out="$(key_json 'x$(touch pwned)' S4 main)"
  [ "$(jq -r '.key | test("^branch:%[0-9a-f]{16}$")' <<<"$out")" = true ]
  [ ! -e "$TMP/pwned" ]
  [ ! -e "$REPO_ROOT/pwned" ]
}

# ---------- 4. default branch fallback ----------

@test "default branch: only master and no origin resolves master" {
  mk_repo "$TMP/dm" master
  [ "$(gaia_usage_default_branch "$TMP/dm")" = master ]
}

@test "default branch: main and master with no origin resolves main" {
  mk_repo "$TMP/dboth" main
  git -C "$TMP/dboth" branch master
  [ "$(gaia_usage_default_branch "$TMP/dboth")" = main ]
}

@test "default branch: neither ref nor origin falls back to main" {
  mk_repo "$TMP/dneither" trunk
  [ "$(gaia_usage_default_branch "$TMP/dneither")" = main ]
}

# ---------- 5. membership and candidate directories ----------

# is_member <cwd> <roots-json>
is_member() {
  jq -nc --arg cwd "$1" --argjson roots "$2" "$GAIA_USAGE_JQ_DEFS"' usage_member($cwd; $roots)'
}

@test "membership: trailing slash is load-bearing; removed and outside worktrees behave" {
  local main="$TMP/main"
  mk_repo "$main"
  git -C "$main" worktree add -q "$main/.claude/worktrees/x" -b wt-x
  git -C "$main" worktree add -q "$main/.claude/worktrees/y" -b wt-y
  git -C "$main" worktree add -q "$TMP/outside-wt" -b wt-out
  git -C "$main" worktree remove --force "$main/.claude/worktrees/y"
  local roots
  roots="$(gaia_usage_tree_roots "$main" | jq -R . | jq -sc .)"
  [ "$(jq -r '.[0]' <<<"$roots")" = "$main" ]
  [ "$(jq 'length' <<<"$roots")" -eq 3 ]
  [ "$(is_member "$main" "$roots")" = true ]
  [ "$(is_member "$main/src/deep" "$roots")" = true ]
  [ "$(is_member "$main/.claude/worktrees/x" "$roots")" = true ]
  [ "$(is_member "$main/.claude/worktrees/y/sub" "$roots")" = true ]
  [ "$(is_member "$TMP/outside-wt/sub" "$roots")" = true ]
  [ "$(is_member "${main}-web" "$roots")" = false ]
  [ "$(is_member "${main}-web/src" "$roots")" = false ]
  [ "$(is_member "$TMP/other" "$roots")" = false ]
  [ "$(is_member "" "$roots")" = false ]
}

@test "candidate dirs: decoy dropped; main and worktree-prefixed project dirs listed" {
  local main="$TMP/main" enc pr="$TMP/projects"
  mk_repo "$main"
  enc="$(printf '%s' "$main" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$pr/$enc" "$pr/$enc--claude-worktrees-x" "$pr/$enc-web" "$pr/unrelated"
  : >"$pr/loose-file.jsonl"
  local got
  got="$(gaia_usage_candidate_dirs "$pr" "$main")"
  [ "$(sort <<<"$got")" = "$(printf '%s\n%s' "$pr/$enc" "$pr/$enc--claude-worktrees-x" | sort)" ]
}

@test "candidate dirs: a project dir of a worktree outside the main root is listed" {
  local main="$TMP/main" enc pr="$TMP/projects"
  mk_repo "$main"
  git -C "$main" worktree add -q "$TMP/outside-wt" -b wt-out
  enc="$(printf '%s' "$TMP/outside-wt" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$pr/$enc"
  [ "$(gaia_usage_candidate_dirs "$pr" "$main")" = "$pr/$enc" ]
}

@test "encoding: underscore and plus map to dash, proven against a hand-spelled dir and a narrow encoder" {
  local main="$TMP/my_repo+x" pr="$TMP/projects" lit
  mk_repo "$main"
  lit="$(printf '%s' "$main" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$pr/$lit"
  [ "$(gaia_usage_candidate_dirs "$pr" "$main")" = "$pr/$lit" ]
  [ "$(gaia_usage_encode_path "$main")" = "$lit" ]
  # The narrow encoder (only / and .) names a different directory and is not matched.
  local narrow_pr="$TMP/projects-narrow" narrow
  narrow="$(printf '%s' "$main" | sed 's/[/.]/-/g')"
  [ "$narrow" != "$lit" ]
  mkdir -p "$narrow_pr/$narrow"
  [ -z "$(gaia_usage_candidate_dirs "$narrow_pr" "$main")" ]
}

@test "projects root: transcript_path wins, then GAIA_TALLY_PROJECTS_ROOT, then CLAUDE_CONFIG_DIR" {
  [ "$(GAIA_TALLY_PROJECTS_ROOT=/env/root gaia_usage_projects_root /p/projects/enc/sid.jsonl)" = /p/projects ]
  [ "$(GAIA_TALLY_PROJECTS_ROOT=/env/root gaia_usage_projects_root)" = /env/root ]
  [ "$(GAIA_TALLY_PROJECTS_ROOT='' CLAUDE_CONFIG_DIR=/cfg gaia_usage_projects_root)" = /cfg/projects ]
  [ "$(GAIA_TALLY_PROJECTS_ROOT='' CLAUDE_CONFIG_DIR='' HOME=/h gaia_usage_projects_root)" = /h/.claude/projects ]
}

# ---------- 6. research slug ----------

# slug_of <path> <research roots json>: the slug, or the literal null.
slug_of() {
  jq -nr --arg p "$1" --argjson r "$2" "$GAIA_USAGE_JQ_DEFS"' usage_research_slug($p; $r) | tostring'
}

@test "research slug: the binding and non-binding cases" {
  local m="$TMP/main" roots
  mk_repo "$m"
  git -C "$m" worktree add -q "$m/.claude/worktrees/lw" -b wt-lw
  roots="$(jq -nc --arg r "$m/.gaia/local/research/" '[$r]')"
  [ "$(slug_of "$m/.gaia/local/research/topic-a-2026-10-01/README.md" "$roots")" = topic-a-2026-10-01 ]
  [ "$(slug_of "$m/.gaia/local/research/release-2.0.0-readiness/notes/a.md" "$roots")" = release-2.0.0-readiness ]
  [ "$(slug_of "$m/.gaia/local/research/DEBT-LOOP-DIAGNOSIS.md" "$roots")" = DEBT-LOOP-DIAGNOSIS ]
  [ "$(slug_of "$m/.gaia/local/research/2250-carryover.patch" "$roots")" = null ]
  [ "$(slug_of "/other/repo/.gaia/local/research/x/README.md" "$roots")" = null ]
  [ "$(slug_of ".gaia/local/research/x/README.md" "$roots")" = null ]
  [ "$(slug_of "$m/.gaia/local/research/../../x/README.md" "$roots")" = null ]
  [ "$(slug_of "$m/.gaia/local/research/./x/a.md" "$roots")" = null ]
  [ "$(slug_of "$m/.gaia/local/research//x/a.md" "$roots")" = null ]
  [ "$(slug_of "$m/.gaia/local/research/x\"y/README.md" "$roots")" = null ]
  [ "$(slug_of "$m/.gaia/local/research/.md" "$roots")" = null ]
  [ "$(slug_of "$m/.gaia/local/research" "$roots")" = null ]
  [ "$(slug_of "$m/.claude/worktrees/lw/.gaia/local/research/x/README.md" "$roots")" = null ]
}

# ---------- 7. ref grammar ----------

@test "ref grammar: bash and jq agree on every valid and invalid case" {
  local long129 long128 valid invalid r
  long128="$(printf 'a%.0s' $(seq 1 128))"
  long129="$(printf 'a%.0s' $(seq 1 129))"
  valid=("research:topic-a-2026-10-01" "research:release-2.0.0" "init:my_slug" "issue:1" "issue:2367"
    "pr:9999999999" "spec:SPEC-087" "spec:SPEC-1000" "plan:PLAN-091" "branch:fix/foo" "branch:a.b/c-d_e"
    "branch:%0123456789abcdef" "branch:$long128" "session:abc-123_X" "command:run.1-a" "research:$long128")
  invalid=("spec:spec-087" "spec:SPEC-87" "plan:plan-091" "issue:0" "issue:01" "issue:12345678901" "pr:x"
    "research:" "research:$long129" "research:-lead" "init:" "branch:" "branch:$long129" "branch:%abc"
    "branch:%0123456789ABCDEF" "branch:has space" 'branch:x$(y)' "session:" "session:$(printf 's%.0s' $(seq 1 65))"
    "command:" "command:a b" "bogus:x" "nocolon" "" $'research:x\n' $'issue:5\nextra')
  [ "${#valid[@]}" -ge 16 ]
  [ "${#invalid[@]}" -ge 25 ]
  for r in "${valid[@]}"; do
    gaia_usage_valid_ref "$r" || { printf 'bash rejects valid [%s]\n' "$r" >&2; return 1; }
    [ "$(jq -nr --arg r "$r" "$GAIA_USAGE_JQ_DEFS"' usage_valid_ref($r)')" = true ] ||
      { printf 'jq rejects valid [%s]\n' "$r" >&2; return 1; }
  done
  for r in "${invalid[@]}"; do
    gaia_usage_valid_ref "$r" && { printf 'bash accepts invalid [%s]\n' "$r" >&2; return 1; }
    [ "$(jq -nr --arg r "$r" "$GAIA_USAGE_JQ_DEFS"' usage_valid_ref($r)')" = false ] ||
      { printf 'jq accepts invalid [%s]\n' "$r" >&2; return 1; }
  done
  true
}

# ---------- 8. locked append ----------

# append_proc <dir> <target> <rows>: the append in a fresh process. with_ledger_lock
# installs EXIT/INT/TERM traps in its caller, which inside a bats test body
# displaces bats' own EXIT handler.
append_proc() {
  bash -c 'source "$1"; gaia_usage_append "$2" "$3" "$4"' _ "$LIB" "$@"
}

@test "append: lock timeout returns 75 and leaves the ledger byte-identical; the same call lands once unlocked" {
  local td="$TMP/tel" rows="$TMP/rows.jsonl"
  mkdir -p "$td"
  printf '{"n":1}\n' >"$rows"
  run append_proc "$td" usage.jsonl "$rows"
  [ "$status" -eq 0 ]
  cp "$td/usage.jsonl" "$TMP/before"
  mkdir "$td/specs.lock.d"
  printf '{"n":2}\n' >"$rows"
  GAIA_LEDGER_LOCK_FORCE_FALLBACK=1 GAIA_LEDGER_LOCK_TIMEOUT_SECONDS=1 GAIA_LEDGER_LOCK_POLL_SECONDS=0.1 \
    run append_proc "$td" usage.jsonl "$rows"
  [ "$status" -eq 75 ]
  cmp "$td/usage.jsonl" "$TMP/before"
  rmdir "$td/specs.lock.d"
  GAIA_LEDGER_LOCK_FORCE_FALLBACK=1 run append_proc "$td" usage.jsonl "$rows"
  [ "$status" -eq 0 ]
  [ "$(cat "$td/usage.jsonl")" = "$(printf '{"n":1}\n{"n":2}')" ]
}

@test "append: a locked-out first write leaves the file absent" {
  local td="$TMP/tel2" rows="$TMP/rows2.jsonl"
  mkdir -p "$td/specs.lock.d"
  printf '{"n":1}\n' >"$rows"
  GAIA_LEDGER_LOCK_FORCE_FALLBACK=1 GAIA_LEDGER_LOCK_TIMEOUT_SECONDS=1 GAIA_LEDGER_LOCK_POLL_SECONDS=0.1 \
    run append_proc "$td" links.jsonl "$rows"
  [ "$status" -eq 75 ]
  [ ! -e "$td/links.jsonl" ]
}

@test "append: any other target basename returns 2 and writes nothing" {
  local td="$TMP/tel3" rows="$TMP/rows3.jsonl"
  printf '{"n":1}\n' >"$rows"
  run append_proc "$td" cost.jsonl "$rows"
  [ "$status" -eq 2 ]
  [ ! -e "$td/cost.jsonl" ]
  run append_proc "$td" ../usage.jsonl "$rows"
  [ "$status" -eq 2 ]
  [ ! -e "$td" ] || [ -z "$(ls -A "$td")" ]
}

@test "append: with the mutex helper unreachable it returns 1 and never appends unlocked" {
  local iso="$TMP/iso" td="$TMP/tel4" rows="$TMP/rows4.jsonl"
  mkdir -p "$iso/.gaia/scripts"
  cp "$LIB" "$iso/.gaia/scripts/usage-lib.sh"
  printf '{"n":1}\n' >"$rows"
  run bash -c 'source "$1"; gaia_usage_append "$2" usage.jsonl "$3"' _ "$iso/.gaia/scripts/usage-lib.sh" "$td" "$rows"
  [ "$status" -eq 1 ]
  [ ! -e "$td/usage.jsonl" ]
}

# ---------- 9. hook registration ----------

# write_settings <dir> <stop cmd or ""> <start cmd or "">
write_settings() {
  mkdir -p "$1/.claude"
  jq -n --arg stop "$2" --arg start "$3" '{hooks: {
      Stop: [{matcher: "", hooks: ([{type: "command", command: "x/other.sh"}] + (if $stop == "" then [] else [{type: "command", command: $stop}] end))}],
      SessionStart: [{matcher: "startup", hooks: (if $start == "" then [] else [{type: "command", command: $start}] end)}]}}' >"$1/.claude/settings.json"
}

@test "hooks registered: red with Stop only, SessionStart only, neither; green with both" {
  local cmd='"$(git rev-parse --show-toplevel)/.claude/hooks/usage-capture.sh"'
  write_settings "$TMP/h1" "$cmd" ""
  run gaia_usage_hooks_registered "$TMP/h1"
  [ "$status" -ne 0 ]
  write_settings "$TMP/h2" "" "$cmd"
  run gaia_usage_hooks_registered "$TMP/h2"
  [ "$status" -ne 0 ]
  write_settings "$TMP/h3" "" ""
  run gaia_usage_hooks_registered "$TMP/h3"
  [ "$status" -ne 0 ]
  write_settings "$TMP/h4" "$cmd" "$cmd"
  run gaia_usage_hooks_registered "$TMP/h4"
  [ "$status" -eq 0 ]
  mkdir -p "$TMP/h5/.claude"
  printf 'not json' >"$TMP/h5/.claude/settings.json"
  run gaia_usage_hooks_registered "$TMP/h5"
  [ "$status" -ne 0 ]
  run gaia_usage_hooks_registered "$TMP/absent"
  [ "$status" -ne 0 ]
}

# ---------- 10. inactive reason, CI ----------

@test "inactive reason: prints jq not found without jq, nothing with jq" {
  mkdir -p "$TMP/bin"
  ln -s "$(command -v cat)" "$TMP/bin/cat"
  run env PATH="$TMP/bin" "$BASH" -c 'source "$1"; gaia_usage_inactive_reason' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "jq not found" ]
  run gaia_usage_inactive_reason
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "in ci: true only when GITHUB_ACTIONS is non-empty" {
  GITHUB_ACTIONS=true gaia_usage_in_ci
  GITHUB_ACTIONS='' run gaia_usage_in_ci
  [ "$status" -ne 0 ]
  run env -u GITHUB_ACTIONS "$BASH" -c 'source "$1"; gaia_usage_in_ci' _ "$LIB"
  [ "$status" -ne 0 ]
}

# ---------- 11. state registry ----------

@test "state registry: valid JSON and the usage entries are present with the frozen shape" {
  local reg="$REPO_ROOT/.gaia/state-registry.json" id
  jq empty "$reg"
  for id in telemetry-usage-ledger telemetry-links-ledger telemetry-usage-cursor-cache \
    telemetry-usage-branch-memo telemetry-usage-sweep-lock telemetry-usage-tmp research-main; do
    [ "$(jq -r --arg id "$id" '[.entries[] | select(.id == $id)] | length' "$reg")" = 1 ] ||
      { printf 'registry entry %s missing or duplicated\n' "$id" >&2; return 1; }
  done
  [ "$(jq -r '.entries[] | select(.id == "research-main") | "\(.path) \(.match) \(.kind) \(.scope) \(.writer)"' "$reg")" = "research/ prefix dir main-only hand-authored" ]
  [ "$(jq -r '.entries[] | select(.id == "telemetry-usage-branch-memo") | "\(.path) \(.match) \(.kind) \(.scope) \(.writer)"' "$reg")" = "telemetry/usage-branch-memo.json exact file shared code" ]
  [ "$(jq -r '.entries[] | select(.id == "telemetry-usage-branch-memo") | .keyed_by' "$reg")" = "singleton per clone; temp-file-then-rename, lock-free, last writer wins" ]
  [ "$(jq -r '.entries[] | select(.id == "telemetry-usage-sweep-lock") | .reaped_by' "$reg")" = "usage-flush.sh stale reclaim" ]
  [ "$(jq -r '.entries[] | select(.id == "telemetry-usage-tmp") | .match' "$reg")" = glob ]
}

# ---------- 12. due files ----------

# mk_due_fixture: sets PR, MAIN, TD and the file paths A to D (A and E are current).
mk_due_fixture() {
  MAIN="$TMP/main"
  PR="$TMP/projects"
  TD="$TMP/tel"
  mk_repo "$MAIN"
  local enc d
  enc="$(printf '%s' "$MAIN" | sed 's/[^A-Za-z0-9]/-/g')"
  d="$PR/$enc"
  mkdir -p "$d/sid1/subagents/workflows/wf_1" "$d/sid1/other" "$TD" "$PR/$enc-web"
  FA="$d/a.jsonl"; FB="$d/b.jsonl"; FC="$d/sid1/subagents/agent-c.jsonl"; FD="$d/sid1/subagents/workflows/wf_1/agent-d.jsonl"
  head -c 100 /dev/zero | tr '\0' a >"$FA"
  head -c 50 /dev/zero | tr '\0' b >"$FB"
  head -c 70 /dev/zero | tr '\0' c >"$FC"
  head -c 5 /dev/zero | tr '\0' d >"$FD"
  # Not transcripts: a wrong-shape jsonl, a decoy project dir, an empty uncursored file.
  head -c 9 /dev/zero | tr '\0' x >"$d/sid1/other/x.jsonl"
  head -c 9 /dev/zero | tr '\0' x >"$PR/$enc-web/web.jsonl"
  : >"$d/empty.jsonl"
  touch -t 202601010000 "$FB"; touch -t 202601020000 "$FC"; touch -t 202601030000 "$FD"; touch -t 202601040000 "$FA"
  jq -n --arg a "$FA" --arg b "$FB" --arg d "$FD" '{schema_version: 1, ledger_bytes: 0,
    files: {($a): {session_id: "s", role: "main", offset: 100, size: 100},
            ($b): {session_id: "s", role: "main", offset: 10, size: 10},
            ($d): {session_id: "s", role: "main", offset: 50, size: 50}}, pairs: {}}' >"$TD/usage-cursors.json"
}

@test "due files: grown, uncached, and truncated files are listed oldest first; the current one is not" {
  mk_due_fixture
  local got want
  got="$(gaia_usage_due_files "$PR" "$MAIN" "$TD")"
  want="$(printf '50\t10\t%s\n70\t0\t%s\n5\t50\t%s' "$FB" "$FC" "$FD")"
  [ "$got" = "$want" ] || { printf 'got:\n%s\nwant:\n%s\n' "$got" "$want" >&2; return 1; }
  grep -qF "$FA" <<<"$got" && return 1
  true
}

@test "due files: a missing or unparseable cache lists every non-empty transcript with offset 0" {
  mk_due_fixture
  local want
  want="$(printf '50\t0\t%s\n70\t0\t%s\n5\t0\t%s\n100\t0\t%s' "$FB" "$FC" "$FD" "$FA")"
  rm "$TD/usage-cursors.json"
  [ "$(gaia_usage_due_files "$PR" "$MAIN" "$TD")" = "$want" ]
  printf '{ not json' >"$TD/usage-cursors.json"
  [ "$(gaia_usage_due_files "$PR" "$MAIN" "$TD")" = "$want" ]
  printf '{"files": 7}' >"$TD/usage-cursors.json"
  [ "$(gaia_usage_due_files "$PR" "$MAIN" "$TD")" = "$want" ]
}

@test "due files: no candidate directory prints nothing and succeeds" {
  MAIN="$TMP/main"
  mk_repo "$MAIN"
  mkdir -p "$TMP/empty-projects"
  run gaia_usage_due_files "$TMP/empty-projects" "$MAIN" "$TMP/tel"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
