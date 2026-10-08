#!/usr/bin/env bats
#
# End-to-end UAT suite for SPEC-086's machine-local rate table (seed, sync,
# merge, worktrees, override, docs). Every test drives the REAL
# token-tally.sh / token-rollup.sh from a temp fixture git repo, never a mock
# and never the pricing lib directly.
#
# Fixtures (fixtures/rates-local/), all hand-authored:
#
#   dist-a.json   the "old" distributed table. Rates are dollars per million
#                 tokens: claude-sonnet-5 2/10, claude-opus-5-5 4/20 (cache
#                 read multiplier 0.05), claude-haiku-4-5 1/5. Multipliers
#                 read 0.1, write_5m 1.25, write_1h 2.0.
#   projects/proj-hash-rl/  one-turn-per-model transcripts, each turn 1,000,000
#                 fresh input tokens and nothing else, so a model's share is
#                 exactly its `input` rate in dollars (1e6 * rate / 1e6):
#                   ratessonnet5      claude-sonnet-5                 -> $2.00
#                   ratesopus55       claude-opus-5-5                 -> $4.00
#                   ratesopus6        claude-opus-6                   -> unpriced
#                                     (dist-a has no opus-6 row)
#                   ratesopus6haiku   claude-opus-6 + claude-haiku-4-5 -> $1.00
#                                     (haiku only; opus-6 is the lower bound)
#   feed-opus6.json     the stub's table: claude-opus-6 input 7 -> $7.00
#   override-opus6.json a --rate-table file pricing opus-6 at 9 -> $9.00, a
#                       rate no other table in this suite uses
#   ledger-opus6.jsonl / ledger-opus6-haiku.jsonl  one hand-written execute
#                       row each (by_model 1,000,000 fresh input per model):
#                       opus-6 alone, and opus-6 + haiku
#
# "Priced command line" (SPEC Constitution): stdout carries the hand-computed
# non-zero dollar figure, no unpriced-model marker, no `unavailable`, and the
# ledger row's `dollars` is non-null and non-zero with no `unpriced` field.
#
# Mutation seam: RATES_E2E_SCRIPTS points the suite at another copy of
# .gaia/scripts (a scratch copy with a deliberately broken lib) to prove a
# test can fail. Unset, the real scripts run.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# bats file_tags=whole-tree

bats_require_minimum_version 1.5.0

setup_file() {
  local here
  here="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  RATES_REAL_LISTING_BEFORE="$(real_listing "$here")"
  export RATES_REAL_LISTING_BEFORE
}

setup() {
  # Isolate pricing from the developer's real rate table and the network.
  export GAIA_RATES_STATE_DIRECTORY="$BATS_TEST_TMPDIR/rates-state"
  export GAIA_RATES_FEED_DISABLE=1
  unset GAIA_RATES_FEED_URL
  TESTS_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REAL_SCRIPTS="$(cd "$TESTS_DIRECTORY/.." && pwd)"
  REAL_ROOT="$(cd "$TESTS_DIRECTORY/../../.." && pwd)"
  SCRIPTS="${RATES_E2E_SCRIPTS:-$REAL_SCRIPTS}"
  FIXTURES="$TESTS_DIRECTORY/fixtures/rates-local"
  PROJECTS="$FIXTURES/projects"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  REPO="$TEMPORARY_DIRECTORY/repo"
  LEDGER="$TEMPORARY_DIRECTORY/ledger.jsonl"
  CACHE="$TEMPORARY_DIRECTORY/cache"
  mkdir -p "$CACHE"
  STATE="$GAIA_RATES_STATE_DIRECTORY"

  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"

  # shellcheck source=fixtures/rates-feed/stub-lib.sh
  source "$TESTS_DIRECTORY/fixtures/rates-feed/stub-lib.sh"
}

teardown() {
  rates_stub_stop
}

# ---------- helpers ----------

# sha_file <path>: the sha256 hex of a file's bytes.
sha_file() {
  local digest_line
  if digest_line="$(shasum -a 256 "$1" 2>/dev/null)"; then :; else digest_line="$(sha256sum "$1")"; fi
  printf '%s' "${digest_line%% *}"
}

# real_listing <repo_root>: name and checksum of every token-rates file (dot
# temp files included) under the real checkout's telemetry dir.
real_listing() {
  local telemetry_directory="$1/.gaia/local/telemetry" listed_file
  for listed_file in "$telemetry_directory"/token-rates* "$telemetry_directory"/.token-rates*; do
    [ -f "$listed_file" ] || continue
    printf '%s %s\n' "$(basename "$listed_file")" "$(sha_file "$listed_file")"
  done | sort
}

# state_listing <state_directory>: name + checksum of every file in a state dir except the
# ledger.
state_listing() {
  local state_directory="$1" listed_file
  for listed_file in "$state_directory"/* "$state_directory"/.[!.]*; do
    [ -f "$listed_file" ] || continue
    [ "$(basename "$listed_file")" = "cost.jsonl" ] && continue
    printf '%s %s\n' "$(basename "$listed_file")" "$(sha_file "$listed_file")"
  done | sort
}

# make_repo <repository_directory> [distributed_table]: a temp git repo with the repository's real .gitignore
# and a committed distributed table at .gaia/scripts/token-rates.json.
make_repo() {
  local repository_directory="$1" distributed_table="${2:-$FIXTURES/dist-a.json}"
  mkdir -p "$repository_directory/.gaia/scripts"
  git init -q "$repository_directory"
  cp "$REAL_ROOT/.gitignore" "$repository_directory/.gitignore"
  cp "$distributed_table" "$repository_directory/.gaia/scripts/token-rates.json"
  git -C "$repository_directory" add -A
  git -C "$repository_directory" commit -q -m init
}

# jq_edit <file> <jq args...>: rewrite a JSON file in place.
jq_edit() {
  local table_file="$1"
  shift
  jq "$@" "$table_file" >"$table_file.new" && mv "$table_file.new" "$table_file"
}

# set_distributed_table <repo> <file>: replace the repo's distributed table's bytes.
set_distributed_table() {
  cp "$2" "$1/.gaia/scripts/token-rates.json"
}

# tally <repo> <session-id> [extra args]: the real tally, cwd in the repo.
# Sets TALLY_EXIT_STATUS; stdout in $TEMPORARY_DIRECTORY/t.out, stderr in $TEMPORARY_DIRECTORY/t.err.
tally() {
  local repo="$1" session_id="$2"
  shift 2
  TALLY_EXIT_STATUS=0
  (
    cd "$repo" &&
      bash "$SCRIPTS/token-tally.sh" --action command --command gaia-audit \
        --session-id "$session_id" --projects-root "$PROJECTS" --ledger "$LEDGER" \
        --cache-dir "$CACHE" "$@"
  ) >"$TEMPORARY_DIRECTORY/t.out" 2>"$TEMPORARY_DIRECTORY/t.err" || TALLY_EXIT_STATUS=$?
}

# rollup <repo> <ledger> [extra args]: the real roll-up, cwd in the repo.
# Sets ROLLUP_EXIT_STATUS; stdout in $TEMPORARY_DIRECTORY/r.out, stderr in $TEMPORARY_DIRECTORY/r.err.
rollup() {
  local repo="$1" ledger="$2"
  shift 2
  ROLLUP_EXIT_STATUS=0
  (
    cd "$repo" &&
      bash "$SCRIPTS/token-rollup.sh" --spec-id SPEC-860 --ledger "$ledger" "$@"
  ) >"$TEMPORARY_DIRECTORY/r.out" 2>"$TEMPORARY_DIRECTORY/r.err" || ROLLUP_EXIT_STATUS=$?
}

last_row() { tail -n 1 "$LEDGER"; }

# assert_priced <dollars>: the last tally was a priced command line worth
# exactly <dollars> (a hand-computed figure, printed and in the ledger row).
assert_priced() {
  local want="$1" printed
  [ "$TALLY_EXIT_STATUS" -eq 0 ] || { echo "tally exited $TALLY_EXIT_STATUS: $(cat "$TEMPORARY_DIRECTORY/t.err")" >&2; return 1; }
  printed="$(cat "$TEMPORARY_DIRECTORY/t.out")"
  case "$printed" in
    *"\$$(printf '%.2f' "$want")"*) : ;;
    *) echo "printed line lacks \$$want: $printed" >&2; return 1 ;;
  esac
  case "$printed" in *unavailable*) echo "line says unavailable: $printed" >&2; return 1 ;; esac
  case "$printed" in *"lower bound"*) echo "line carries a lower-bound marker: $printed" >&2; return 1 ;; esac
  last_row | jq -e --argjson dollars "$want" '(.dollars != null) and (.dollars > 0) and ((.dollars - $dollars | fabs) < 0.000001) and (has("unpriced") | not)' >/dev/null
}

# table_id <file>: sha256:<first 16 hex of the file's sha256>.
table_id() {
  printf 'sha256:%s' "$(sha_file "$1" | cut -c1-16)"
}

# seed_state: a first run that seeds the local table from the repo's dist.
seed_state() {
  tally "$REPO" ratessonnet5
  [ "$TALLY_EXIT_STATUS" -eq 0 ]
  [ -s "$STATE/token-rates.json" ]
}

# model_rows_equal <table> <model> <other-table>: the model's rows are JSON-equal.
model_rows_equal() {
  jq -e --arg model "$2" --slurpfile other_table "$3" '.models[$model] == $other_table[0].models[$model]' "$1" >/dev/null
}

# ---------- UAT-001 ----------

@test "UAT-001: a first run seeds the local table byte-identical to the distributed table, priced, nothing in git" {
  unset GAIA_RATES_STATE_DIRECTORY
  make_repo "$REPO"
  local before untracked
  before="$(git -C "$REPO" status --porcelain)"

  tally "$REPO" ratessonnet5

  local table="$REPO/.gaia/local/telemetry/token-rates.json"
  [ -s "$table" ]
  cmp -s "$table" "$REPO/.gaia/scripts/token-rates.json"
  # sonnet-5 at input 2, 1M tokens: 1e6 * 2 / 1e6 = 2.00
  assert_priced 2
  [ "$(last_row | jq -r '.rate_table_id')" = "$(table_id "$REPO/.gaia/scripts/token-rates.json")" ]
  [ "$(git -C "$REPO" status --porcelain)" = "$before" ]
  untracked=0
  while IFS= read -r -d '' _; do
    untracked=$((untracked + 1))
  done < <(git -C "$REPO" ls-files -z --others --exclude-standard)
  [ "$untracked" -eq 0 ]
}

# ---------- UAT-002 ----------

@test "UAT-002: an unedited row byte-identical to its base takes the new distributed row; the table then equals the distributed file" {
  make_repo "$REPO"
  seed_state
  jq '.models["claude-sonnet-5"][0].input = 3' "$FIXTURES/dist-a.json" >"$TEMPORARY_DIRECTORY/dist-b.json"
  set_distributed_table "$REPO" "$TEMPORARY_DIRECTORY/dist-b.json"

  tally "$REPO" ratessonnet5

  # sonnet-5 now input 3: 1e6 * 3 / 1e6 = 3.00
  assert_priced 3
  model_rows_equal "$STATE/token-rates.json" claude-sonnet-5 "$TEMPORARY_DIRECTORY/dist-b.json"
  model_rows_equal "$STATE/token-rates.base.json" claude-sonnet-5 "$TEMPORARY_DIRECTORY/dist-b.json"
  cmp -s "$STATE/token-rates.json" "$REPO/.gaia/scripts/token-rates.json"
}

@test "UAT-002: an unedited row differing from its base only in key order and whitespace also takes the new row" {
  make_repo "$REPO"
  seed_state
  # Same value, keys reordered, tab-indented. The base file is left untouched.
  jq --tab '.models["claude-sonnet-5"] = [{"output": 10, "input": 2}]' "$STATE/token-rates.json" >"$TEMPORARY_DIRECTORY/reordered.json"
  cp "$TEMPORARY_DIRECTORY/reordered.json" "$STATE/token-rates.json"
  jq '.models["claude-sonnet-5"][0].input = 3' "$FIXTURES/dist-a.json" >"$TEMPORARY_DIRECTORY/dist-b.json"
  set_distributed_table "$REPO" "$TEMPORARY_DIRECTORY/dist-b.json"

  tally "$REPO" ratessonnet5

  assert_priced 3
  model_rows_equal "$STATE/token-rates.json" claude-sonnet-5 "$TEMPORARY_DIRECTORY/dist-b.json"
  model_rows_equal "$STATE/token-rates.base.json" claude-sonnet-5 "$TEMPORARY_DIRECTORY/dist-b.json"
  cmp -s "$STATE/token-rates.json" "$REPO/.gaia/scripts/token-rates.json"
}

# ---------- UAT-003 ----------

@test "UAT-003: an adopter-edited row is never replaced; the printed and ledger dollars use the edited input" {
  make_repo "$REPO"
  seed_state
  jq_edit "$STATE/token-rates.json" '.models["claude-opus-5-5"][0].input = 3'
  jq '.models["claude-opus-5-5"][0].input = 6' "$FIXTURES/dist-a.json" >"$TEMPORARY_DIRECTORY/dist-b.json"
  set_distributed_table "$REPO" "$TEMPORARY_DIRECTORY/dist-b.json"

  tally "$REPO" ratesopus55

  [ "$(jq -r '.models["claude-opus-5-5"][0].input' "$STATE/token-rates.json")" = "3" ]
  # opus-5-5 edited to input 3, 1M tokens: 1e6 * 3 / 1e6 = 3.00 (not 6.00)
  assert_priced 3
}

# ---------- UAT-004 ----------

@test "UAT-004: an adopter-added model is kept and a new distributed model is added" {
  make_repo "$REPO"
  seed_state
  jq_edit "$STATE/token-rates.json" '.models["claude-private-1"] = [{"input": 12, "output": 60}]'
  jq '.models["claude-opus-6"] = [{"input": 7, "output": 35}]' "$FIXTURES/dist-a.json" >"$TEMPORARY_DIRECTORY/dist-b.json"
  set_distributed_table "$REPO" "$TEMPORARY_DIRECTORY/dist-b.json"

  tally "$REPO" ratessonnet5

  [ "$TALLY_EXIT_STATUS" -eq 0 ]
  jq -e '.models["claude-private-1"] == [{"input": 12, "output": 60}]' "$STATE/token-rates.json" >/dev/null
  model_rows_equal "$STATE/token-rates.json" claude-opus-6 "$TEMPORARY_DIRECTORY/dist-b.json"
}

# ---------- UAT-005 ----------

# feed_state <local-input>: local and base hold a feed-written opus-6 row (the
# provenance mark on both), the byte copy is the older dist-a. The base row is
# always input 7; the local row is <local-input>.
feed_state() {
  local local_input="$1"
  mkdir -p "$STATE"
  jq '.models["claude-opus-6"] = [{"input": 7, "output": 35, "source": "feed"}]' "$FIXTURES/dist-a.json" >"$TEMPORARY_DIRECTORY/base.json"
  jq --argjson input_rate "$local_input" '.models["claude-opus-6"] = [{"input": $input_rate, "output": 35, "source": "feed"}]' "$FIXTURES/dist-a.json" >"$TEMPORARY_DIRECTORY/local.json"
  cp "$TEMPORARY_DIRECTORY/local.json" "$STATE/token-rates.json"
  cp "$TEMPORARY_DIRECTORY/base.json" "$STATE/token-rates.base.json"
  cp "$FIXTURES/dist-a.json" "$STATE/token-rates.dist.json"
  jq '.models["claude-opus-6"] = [{"input": 8, "output": 40}]' "$FIXTURES/dist-a.json" >"$TEMPORARY_DIRECTORY/dist-b.json"
  make_repo "$REPO" "$TEMPORARY_DIRECTORY/dist-b.json"
}

@test "UAT-005: an unedited feed-written row takes the distributed row and loses the provenance mark" {
  feed_state 7
  tally "$REPO" ratessonnet5
  [ "$TALLY_EXIT_STATUS" -eq 0 ]
  model_rows_equal "$STATE/token-rates.json" claude-opus-6 "$TEMPORARY_DIRECTORY/dist-b.json"
  jq -e '.models["claude-opus-6"] | all(has("source") | not)' "$STATE/token-rates.json" >/dev/null
}

@test "UAT-005: an adopter-edited feed-written row is left unchanged" {
  feed_state 11
  tally "$REPO" ratessonnet5
  [ "$TALLY_EXIT_STATUS" -eq 0 ]
  jq -e '.models["claude-opus-6"] == [{"input": 11, "output": 35, "source": "feed"}]' "$STATE/token-rates.json" >/dev/null
}

# ---------- UAT-011 ----------

@test "UAT-011: a provisioned linked worktree heals into main's one local table" {
  unset GAIA_RATES_STATE_DIRECTORY GAIA_RATES_FEED_DISABLE
  rates_stub_start_or_skip tls serve "$FIXTURES/feed-opus6.json"
  export GAIA_RATES_FEED_URL="$RATES_STUB_URL"
  local main="$TEMPORARY_DIRECTORY/main" worktree_path="$TEMPORARY_DIRECTORY/wt"
  make_repo "$main"
  mkdir -p "$main/.gaia/local"
  git -C "$main" worktree add -q "$worktree_path" -b feature
  # link-worktree.sh's result: the worktree's whole .gaia/local is one symlink.
  ln -s "$main/.gaia/local" "$worktree_path/.gaia/local"

  tally "$main" ratessonnet5
  [ "$TALLY_EXIT_STATUS" -eq 0 ]
  [ "$(rates_stub_count)" = "0" ]
  local main_before worktree_status_before
  main_before="$(git -C "$main" status --porcelain)"
  worktree_status_before="$(git -C "$worktree_path" status --porcelain)"

  tally "$worktree_path" ratesopus6
  # opus-6 healed at input 7: 1e6 * 7 / 1e6 = 7.00
  assert_priced 7
  [ "$(rates_stub_count)" = "1" ]

  local main_telemetry_directory worktree_telemetry_directory
  main_telemetry_directory="$(cd "$main/.gaia/local/telemetry" && pwd -P)"
  worktree_telemetry_directory="$(cd "$worktree_path/.gaia/local/telemetry" && pwd -P)"
  [ "$main_telemetry_directory" = "$worktree_telemetry_directory" ]
  jq -e '.models["claude-opus-6"][0].input == 7' "$main_telemetry_directory/token-rates.json" >/dev/null
  [ ! -e "$worktree_path/.gaia/local/telemetry/token-rates.json" ] || [ "$worktree_path/.gaia/local/telemetry/token-rates.json" -ef "$main_telemetry_directory/token-rates.json" ]
  [ "$(git -C "$main" status --porcelain)" = "$main_before" ]
  [ "$(git -C "$worktree_path" status --porcelain)" = "$worktree_status_before" ]
}

# ---------- UAT-012 ----------

@test "UAT-012: the roll-up prices a ledger row with a later-healed model from the local table" {
  make_repo "$REPO"
  mkdir -p "$STATE"
  jq '.models["claude-opus-6"] = [{"input": 7, "output": 35, "source": "feed"}]' "$FIXTURES/dist-a.json" >"$STATE/token-rates.json"
  cp "$STATE/token-rates.json" "$STATE/token-rates.base.json"
  cp "$FIXTURES/dist-a.json" "$STATE/token-rates.dist.json"

  rollup "$REPO" "$FIXTURES/ledger-opus6-haiku.jsonl"

  [ "$ROLLUP_EXIT_STATUS" -eq 0 ]
  # opus-6 7.00 + haiku 1.00 = 8.00 (each 1M fresh input)
  grep -qF 'execute:   $8.00' "$TEMPORARY_DIRECTORY/r.out"
  grep -qF 'Total:     $8.00' "$TEMPORARY_DIRECTORY/r.out"
  grep -qF 'unavailable' "$TEMPORARY_DIRECTORY/r.out" && return 1
  grep -qF 'claude-opus-6' "$TEMPORARY_DIRECTORY/r.out" && return 1

  # Control: without the healed row the same run must name opus-6 and drop its
  # share, so the assertions above can fail.
  jq_edit "$STATE/token-rates.json" 'del(.models["claude-opus-6"])'
  rollup "$REPO" "$FIXTURES/ledger-opus6-haiku.jsonl"
  grep -qF 'lower bound: unpriced model(s) claude-opus-6' "$TEMPORARY_DIRECTORY/r.out"
  grep -qF 'execute:   $1.00' "$TEMPORARY_DIRECTORY/r.out"
}

# ---------- UAT-013 ----------

@test "UAT-013: --rate-table runs price from the file, make no request, and touch no state; the bare run heals once" {
  unset GAIA_RATES_FEED_DISABLE
  rates_stub_start_or_skip tls serve "$FIXTURES/feed-opus6.json"
  export GAIA_RATES_FEED_URL="$RATES_STUB_URL"
  make_repo "$REPO"
  seed_state
  [ "$(rates_stub_count)" = "0" ]
  local listing_before listing_after
  listing_before="$(state_listing "$STATE")"

  tally "$REPO" ratesopus6 --rate-table "$FIXTURES/override-opus6.json"
  # override: opus-6 at input 9: 1e6 * 9 / 1e6 = 9.00
  assert_priced 9
  rollup "$REPO" "$FIXTURES/ledger-opus6.jsonl" --rate-table "$FIXTURES/override-opus6.json"
  [ "$ROLLUP_EXIT_STATUS" -eq 0 ]
  grep -qF 'execute:   $9.00' "$TEMPORARY_DIRECTORY/r.out"
  grep -qF 'Total:     $9.00' "$TEMPORARY_DIRECTORY/r.out"

  [ "$(rates_stub_count)" = "0" ]
  listing_after="$(state_listing "$STATE")"
  [ "$listing_before" = "$listing_after" ]

  tally "$REPO" ratesopus6
  # healed from the stub at input 7: 7.00
  assert_priced 7
  [ "$(rates_stub_count)" = "1" ]
}

# ---------- UAT-014 ----------

# corrupt_case <content-printf-format>: preserve, re-seed, one stderr line, and
# a second corruption never overwrites the first preserved copy.
corrupt_case() {
  local content="$1" files first
  make_repo "$REPO"
  mkdir -p "$STATE"
  printf '%s' "$content" >"$STATE/token-rates.json"
  cp "$STATE/token-rates.json" "$TEMPORARY_DIRECTORY/corrupt-1.copy"
  printf '{"models":{"claude-stale":[{"input":99,"output":99}]}}' >"$STATE/token-rates.base.json"

  tally "$REPO" ratessonnet5

  assert_priced 2
  files=("$STATE"/token-rates.json.corrupt.*)
  [ "${#files[@]}" -eq 1 ]
  [ -e "${files[0]}" ]
  cmp -s "${files[0]}" "$TEMPORARY_DIRECTORY/corrupt-1.copy"
  [ "$(grep -cF -- "${files[0]}" "$TEMPORARY_DIRECTORY/t.err")" -eq 1 ]
  cmp -s "$STATE/token-rates.json" "$REPO/.gaia/scripts/token-rates.json"
  jq -e --slurpfile distributed_table "$REPO/.gaia/scripts/token-rates.json" '.models == $distributed_table[0].models' "$STATE/token-rates.base.json" >/dev/null

  # A second corruption gets its own copy; the first stays byte-identical.
  first="${files[0]}"
  printf 'second corruption' >"$STATE/token-rates.json"
  tally "$REPO" ratessonnet5
  assert_priced 2
  files=("$STATE"/token-rates.json.corrupt.*)
  [ "${#files[@]}" -eq 2 ]
  cmp -s "$first" "$TEMPORARY_DIRECTORY/corrupt-1.copy"
  [ "$(grep -c 'token-rates.json.corrupt.' "$TEMPORARY_DIRECTORY/t.err")" -eq 1 ]
}

@test "UAT-014: a zero-byte local table is preserved and re-seeded" {
  corrupt_case ''
}

@test "UAT-014: a local table that is not valid JSON is preserved and re-seeded" {
  corrupt_case 'this is not json {{{'
}

@test "UAT-014: a local table without a models object is preserved and re-seeded" {
  corrupt_case '{"cache_multipliers":{"read":0.1}}'
}

# ---------- UAT-015 ----------

@test "UAT-015: from a bare repository's linked worktree the run prices readonly, makes no request, writes no table" {
  unset GAIA_RATES_STATE_DIRECTORY GAIA_RATES_FEED_DISABLE
  rates_stub_start_or_skip tls serve "$FIXTURES/feed-opus6.json"
  export GAIA_RATES_FEED_URL="$RATES_STUB_URL"
  local source_repository="$TEMPORARY_DIRECTORY/src" bare="$TEMPORARY_DIRECTORY/bare.git" worktree_path="$TEMPORARY_DIRECTORY/bare-wt"
  make_repo "$source_repository"
  git clone -q --bare "$source_repository" "$bare"
  git -C "$bare" worktree add -q "$worktree_path" -b wt-branch
  # Preconditions that make the case real: the main-checkout resolver fails
  # while the worktree still has a top level and the distributed table.
  ( cd "$worktree_path" && bash -c 'source "$1/main-root-lib.sh"; gaia_resolve_main_root' _ "$REAL_SCRIPTS" ) >/dev/null 2>&1 && return 1
  [ -n "$(git -C "$worktree_path" rev-parse --show-toplevel)" ]
  [ -s "$worktree_path/.gaia/scripts/token-rates.json" ]

  tally "$worktree_path" ratesopus6haiku

  [ "$TALLY_EXIT_STATUS" -eq 0 ]
  # haiku only, input 1: 1e6 * 1 / 1e6 = 1.00; opus-6 is the lower bound
  grep -qF '$1.00' "$TEMPORARY_DIRECTORY/t.out"
  grep -qF '(lower bound: unpriced model(s) claude-opus-6)' "$TEMPORARY_DIRECTORY/t.out"
  [ "$(rates_stub_count)" = "0" ]
  [ ! -e "$worktree_path/.gaia/local" ]
  [ -z "$(find "$worktree_path" "$bare" -name 'token-rates*' -not -path "$worktree_path/.gaia/scripts/token-rates.json")" ]
}

# ---------- UAT-017 ----------

# uat017_files: the files the SPEC lists, one absolute path per line.
uat017_files() {
  local relative_path token_script
  for relative_path in "wiki/concepts/Token Cost Readout.md" "wiki/concepts/Cost Data Contract.md" \
    "wiki/concepts/GAIA Scripts.md" "wiki/concepts/Worktrees.md" "wiki/concepts/GAIA CLI.md" \
    "wiki/index.md" "CHANGELOG.md"; do
    printf '%s\n' "$REAL_ROOT/$relative_path"
  done
  for token_script in "$REAL_ROOT"/.gaia/scripts/token-*.sh; do
    printf '%s\n' "$token_script"
  done
}

# uat017_stale <files...>: every line that still states the rate table is
# resolved per tree via --show-toplevel, or that the committed table is what
# prices (file:line:text). Duplicates collapsed.
uat017_stale() {
  local checked_file
  # Per file, filtering the text only: a -H prefix would let a file NAME
  # containing "token-rates" satisfy the second regex.
  for checked_file in "$@"; do
    {
      grep -n -i -e '--show-toplevel' -- "$checked_file" | grep -i -E 'rate[ _]table|token-rates'
      grep -n -w -i -e 'committed' -- "$checked_file" | grep -i -E 'rate[ _]table|token-rates|committed table|rate card'
    } | sort -u | sed "s|^|$checked_file:|"
  done
}

# Each true survivor, read and judged, is one fixed substring of its line.
UAT017_ALLOW=(
  # Token Cost Readout: names the per-tree resolver only as the partial-update fallback.
  'survives only as the fallback for a partial update'
  # Cost Data Contract: the id equals the committed bytes when the machine's table matches.
  "which equal the committed table's bytes when the machine's table matches GAIA's"
  # Token Cost Readout: the id matches the committed table's id only when the merged result equals GAIA's.
  "so \`rate_table_id\` matches the committed table's id"
  # token-rates-local-lib.sh: the synced table is byte-identical to the committed id source.
  'equals the committed id'
)

# uat017_unallowed <stale-lines>: the lines no allowlist entry covers.
uat017_unallowed() {
  local line entry ok
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ok=0
    for entry in "${UAT017_ALLOW[@]}"; do
      case "$line" in *"$entry"*) ok=1 ;; esac
    done
    [ "$ok" -eq 1 ] || printf '%s\n' "$line"
  done <<<"$1"
}

@test "UAT-017: docs and comments no longer say the per-tree or committed table prices, and carry the new literals" {
  local files=() scanned_file
  while IFS= read -r scanned_file; do files+=("$scanned_file"); done < <(uat017_files)
  # 7 named files plus every token-*.sh; a short read would shrink the scan.
  local script_count
  script_count="$(find "$REAL_SCRIPTS" -maxdepth 1 -name 'token-*.sh' | wc -l | tr -d ' ')"
  [ "${#files[@]}" -eq "$((7 + script_count))" ]
  [ "$script_count" -ge 4 ]
  for scanned_file in "${files[@]}"; do
    [ -s "$scanned_file" ] || { echo "missing or empty: $scanned_file" >&2; return 1; }
  done

  # The scan can fail: a line stating the old rule is caught and not allowlisted.
  printf 'The committed table prices every run via --show-toplevel rate table.\n' >"$TEMPORARY_DIRECTORY/bad.md"
  [ -n "$(uat017_unallowed "$(uat017_stale "$TEMPORARY_DIRECTORY/bad.md")")" ]

  local stale left
  stale="$(uat017_stale "${files[@]}")"
  left="$(uat017_unallowed "$stale")"
  [ -z "$left" ] || { echo "stale lines:" >&2; echo "$left" >&2; return 1; }
  # Every allowlist entry still matches something: none is dead.
  local entry
  for entry in "${UAT017_ALLOW[@]}"; do
    case "$stale" in *"$entry"*) : ;; *) echo "dead allowlist entry: $entry" >&2; return 1 ;; esac
  done

  local readout="$REAL_ROOT/wiki/concepts/Token Cost Readout.md"
  grep -qF -- '.gaia/local/telemetry/token-rates.json' "$readout"
  grep -qF -- 'GAIA_RATES_FEED_DISABLE' "$readout"
  grep -qF -- 'GAIA_RATES_FEED_URL' "$readout"
  grep -qF -- 'https://raw.githubusercontent.com/gaia-react/gaia/main/.gaia/scripts/token-rates.json' "$readout"

  grep -F '| `rate_table_id`' "$REAL_ROOT/wiki/concepts/Cost Data Contract.md" | grep -qF 'The bytes of the table that priced the row'

  grep -qF -- 'GAIA_RATES_FEED_DISABLE' "$REAL_ROOT/wiki/concepts/GAIA CLI.md"

  local unreleased
  unreleased="$(awk '/^## \[Unreleased\]/{on=1; next} /^## \[/{on=0} on' "$REAL_ROOT/CHANGELOG.md")"
  [ -n "$unreleased" ]
  case "$unreleased" in *GAIA_RATES_FEED_DISABLE*) : ;; *) return 1 ;; esac
}

# ---------- UAT-025 ----------

@test "UAT-025: a model the new distributed table removes keeps its unedited local row" {
  make_repo "$REPO"
  seed_state
  jq 'del(.models["claude-haiku-4-5"])' "$FIXTURES/dist-a.json" >"$TEMPORARY_DIRECTORY/dist-b.json"
  set_distributed_table "$REPO" "$TEMPORARY_DIRECTORY/dist-b.json"

  tally "$REPO" ratessonnet5

  assert_priced 2
  model_rows_equal "$STATE/token-rates.json" claude-haiku-4-5 "$FIXTURES/dist-a.json"
}

# no_base_case <bytecopy: absent|old>: an edited row, no base, then a new
# distributed model.
no_base_case() {
  local copy="$1"
  make_repo "$REPO"
  mkdir -p "$STATE"
  jq '.models["claude-opus-5-5"][0].input = 3' "$FIXTURES/dist-a.json" >"$STATE/token-rates.json"
  cp "$STATE/token-rates.json" "$TEMPORARY_DIRECTORY/local-before.json"
  [ "$copy" = "old" ] && cp "$FIXTURES/dist-a.json" "$STATE/token-rates.dist.json"
  jq '.models["claude-opus-6"] = [{"input": 7, "output": 35}]' "$FIXTURES/dist-a.json" >"$TEMPORARY_DIRECTORY/dist-b.json"
  set_distributed_table "$REPO" "$TEMPORARY_DIRECTORY/dist-b.json"

  tally "$REPO" ratesopus55

  # the edited opus-5-5 row is kept: 1e6 * 3 / 1e6 = 3.00
  assert_priced 3
  jq -e --slurpfile other_table "$TEMPORARY_DIRECTORY/local-before.json" '(.models | del(.["claude-opus-6"])) == $other_table[0].models' "$STATE/token-rates.json" >/dev/null
  model_rows_equal "$STATE/token-rates.json" claude-opus-6 "$TEMPORARY_DIRECTORY/dist-b.json"
  [ -s "$STATE/token-rates.base.json" ]

  cp "$STATE/token-rates.json" "$TEMPORARY_DIRECTORY/local-after-1.json"
  tally "$REPO" ratesopus55
  cmp -s "$STATE/token-rates.json" "$TEMPORARY_DIRECTORY/local-after-1.json"
}

@test "UAT-025: an edited row with no recorded base and no byte copy is kept while a new model is added" {
  no_base_case absent
}

@test "UAT-025: an edited row with no recorded base and a byte copy of the older table is kept while a new model is added" {
  no_base_case old
}

# ---------- UAT-026 ----------

# cache_case <edited: yes|no>: the new distributed table changes read to 0.2.
cache_case() {
  local edited="$1"
  make_repo "$REPO"
  seed_state
  [ "$edited" = "yes" ] && jq_edit "$STATE/token-rates.json" '.cache_multipliers.read = 0.15'
  jq '.cache_multipliers.read = 0.2' "$FIXTURES/dist-a.json" >"$TEMPORARY_DIRECTORY/dist-b.json"
  set_distributed_table "$REPO" "$TEMPORARY_DIRECTORY/dist-b.json"

  tally "$REPO" ratessonnet5
  [ "$TALLY_EXIT_STATUS" -eq 0 ]
}

@test "UAT-026: unedited cache multipliers take the new distributed value" {
  cache_case no
  [ "$(jq -r '.cache_multipliers.read' "$STATE/token-rates.json")" = "0.2" ]
}

@test "UAT-026: edited cache multipliers are left unchanged" {
  cache_case yes
  jq -e '.cache_multipliers == {"read": 0.15, "write_5m": 1.25, "write_1h": 2.0}' "$STATE/token-rates.json" >/dev/null
}

# ---------- UAT-027 ----------

@test "UAT-027: alternating runs from a linked worktree and main never let a branch's table into the local table" {
  local main="$TEMPORARY_DIRECTORY/main" worktree_path="$TEMPORARY_DIRECTORY/wt" where
  make_repo "$main"
  git -C "$main" worktree add -q "$worktree_path" -b feature
  jq '.models["claude-sonnet-5"][0].input = 5' "$FIXTURES/dist-a.json" >"$worktree_path/.gaia/scripts/token-rates.json"
  git -C "$worktree_path" commit -q -am "branch changes the sonnet-5 row"
  cmp -s "$worktree_path/.gaia/scripts/token-rates.json" "$main/.gaia/scripts/token-rates.json" && return 1

  tally "$worktree_path" ratessonnet5
  # main's row, not the branch's: 1e6 * 2 / 1e6 = 2.00
  assert_priced 2
  cp "$STATE/token-rates.json" "$TEMPORARY_DIRECTORY/local-1.json"
  cp "$STATE/token-rates.base.json" "$TEMPORARY_DIRECTORY/base-1.json"

  for _ in 1 2 3; do
    for where in "$main" "$worktree_path"; do
      tally "$where" ratessonnet5
      assert_priced 2
      cmp -s "$STATE/token-rates.json" "$TEMPORARY_DIRECTORY/local-1.json"
      cmp -s "$STATE/token-rates.base.json" "$TEMPORARY_DIRECTORY/base-1.json"
      jq -e --slurpfile distributed_table "$main/.gaia/scripts/token-rates.json" '. == $distributed_table[0]' "$STATE/token-rates.json" >/dev/null
    done
  done

  tally "$worktree_path" ratessonnet5 --rate-table "$worktree_path/.gaia/scripts/token-rates.json"
  # the branch's row: 1e6 * 5 / 1e6 = 5.00
  assert_priced 5
  cmp -s "$STATE/token-rates.json" "$TEMPORARY_DIRECTORY/local-1.json"
}

# ---------- UAT-028 ----------

@test "UAT-028: a sync interrupted after the local table landed completes on the next run, then stays put" {
  make_repo "$REPO"
  # New distributed table: sonnet-5 raised to 3, opus-6 added.
  jq '.models["claude-sonnet-5"][0].input = 3 | .models["claude-opus-6"] = [{"input": 7, "output": 35}]' "$FIXTURES/dist-a.json" >"$TEMPORARY_DIRECTORY/dist-b.json"
  set_distributed_table "$REPO" "$TEMPORARY_DIRECTORY/dist-b.json"
  mkdir -p "$STATE"
  # On disk: the merged local table (haiku edited to 1.5) was renamed into
  # place, but the base and the byte copy are still the old table's.
  jq '.models["claude-haiku-4-5"][0].input = 1.5' "$TEMPORARY_DIRECTORY/dist-b.json" >"$STATE/token-rates.json"
  cp "$FIXTURES/dist-a.json" "$STATE/token-rates.base.json"
  cp "$FIXTURES/dist-a.json" "$STATE/token-rates.dist.json"

  tally "$REPO" ratessonnet5

  # sonnet-5 at the new input 3: 3.00
  assert_priced 3
  [ "$(jq -r '.models["claude-haiku-4-5"][0].input' "$STATE/token-rates.json")" = "1.5" ]
  model_rows_equal "$STATE/token-rates.json" claude-sonnet-5 "$TEMPORARY_DIRECTORY/dist-b.json"
  model_rows_equal "$STATE/token-rates.json" claude-opus-6 "$TEMPORARY_DIRECTORY/dist-b.json"
  jq -e --slurpfile distributed_table "$TEMPORARY_DIRECTORY/dist-b.json" '. == $distributed_table[0]' "$STATE/token-rates.base.json" >/dev/null
  cmp -s "$STATE/token-rates.dist.json" "$TEMPORARY_DIRECTORY/dist-b.json"

  cp "$STATE/token-rates.json" "$TEMPORARY_DIRECTORY/l1"
  cp "$STATE/token-rates.base.json" "$TEMPORARY_DIRECTORY/b1"
  cp "$STATE/token-rates.dist.json" "$TEMPORARY_DIRECTORY/c1"
  tally "$REPO" ratessonnet5
  assert_priced 3
  cmp -s "$STATE/token-rates.json" "$TEMPORARY_DIRECTORY/l1"
  cmp -s "$STATE/token-rates.base.json" "$TEMPORARY_DIRECTORY/b1"
  cmp -s "$STATE/token-rates.dist.json" "$TEMPORARY_DIRECTORY/c1"
}

# ---------- guard: the real checkout's local state is untouched ----------
# Keep this test last: it compares against the listing setup_file captured.

@test "the real checkout's token-rates files are byte-identical to before the suite" {
  local now
  now="$(real_listing "$REAL_ROOT")"
  [ "$now" = "$RATES_REAL_LISTING_BEFORE" ]
}
