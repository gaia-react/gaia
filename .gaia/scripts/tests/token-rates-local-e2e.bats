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

bats_require_minimum_version 1.5.0

setup_file() {
  local here
  here="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  RATES_REAL_LISTING_BEFORE="$(real_listing "$here")"
  export RATES_REAL_LISTING_BEFORE
}

setup() {
  # Isolate pricing from the developer's real rate table and the network.
  export GAIA_RATES_STATE_DIR="$BATS_TEST_TMPDIR/rates-state"
  export GAIA_RATES_FEED_DISABLE=1
  unset GAIA_RATES_FEED_URL
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REAL_SCRIPTS="$(cd "$TESTS_DIR/.." && pwd)"
  REAL_ROOT="$(cd "$TESTS_DIR/../../.." && pwd)"
  SCRIPTS="${RATES_E2E_SCRIPTS:-$REAL_SCRIPTS}"
  FIX="$TESTS_DIR/fixtures/rates-local"
  PROJECTS="$FIX/projects"
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  REPO="$TMP/repo"
  LEDGER="$TMP/ledger.jsonl"
  CACHE="$TMP/cache"
  mkdir -p "$CACHE"
  STATE="$GAIA_RATES_STATE_DIR"

  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"

  # shellcheck source=fixtures/rates-feed/stub-lib.sh
  source "$TESTS_DIR/fixtures/rates-feed/stub-lib.sh"
}

teardown() {
  rates_stub_stop
}

# ---------- helpers ----------

# sha_file <path>: the sha256 hex of a file's bytes.
sha_file() {
  local out
  if out="$(shasum -a 256 "$1" 2>/dev/null)"; then :; else out="$(sha256sum "$1")"; fi
  printf '%s' "${out%% *}"
}

# real_listing <repo_root>: name and checksum of every token-rates file (dot
# temp files included) under the real checkout's telemetry dir.
real_listing() {
  local dir="$1/.gaia/local/telemetry" f
  for f in "$dir"/token-rates* "$dir"/.token-rates*; do
    [ -f "$f" ] || continue
    printf '%s %s\n' "$(basename "$f")" "$(sha_file "$f")"
  done | sort
}

# state_listing <dir>: name + checksum of every file in a state dir except the
# ledger.
state_listing() {
  local dir="$1" f
  for f in "$dir"/* "$dir"/.[!.]*; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "cost.jsonl" ] && continue
    printf '%s %s\n' "$(basename "$f")" "$(sha_file "$f")"
  done | sort
}

# mk_repo <dir> [dist]: a temp git repo with the repository's real .gitignore
# and a committed distributed table at .gaia/scripts/token-rates.json.
mk_repo() {
  local dir="$1" dist="${2:-$FIX/dist-a.json}"
  mkdir -p "$dir/.gaia/scripts"
  git init -q "$dir"
  cp "$REAL_ROOT/.gitignore" "$dir/.gitignore"
  cp "$dist" "$dir/.gaia/scripts/token-rates.json"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m init
}

# jq_edit <file> <jq args...>: rewrite a JSON file in place.
jq_edit() {
  local f="$1"
  shift
  jq "$@" "$f" >"$f.new" && mv "$f.new" "$f"
}

# set_dist <repo> <file>: replace the repo's distributed table's bytes.
set_dist() {
  cp "$2" "$1/.gaia/scripts/token-rates.json"
}

# tally <repo> <session-id> [extra args]: the real tally, cwd in the repo.
# Sets T_RC; stdout in $TMP/t.out, stderr in $TMP/t.err.
tally() {
  local repo="$1" sid="$2"
  shift 2
  T_RC=0
  (
    cd "$repo" &&
      bash "$SCRIPTS/token-tally.sh" --action command --command gaia-audit \
        --session-id "$sid" --projects-root "$PROJECTS" --ledger "$LEDGER" \
        --cache-dir "$CACHE" "$@"
  ) >"$TMP/t.out" 2>"$TMP/t.err" || T_RC=$?
}

# rollup <repo> <ledger> [extra args]: the real roll-up, cwd in the repo.
# Sets R_RC; stdout in $TMP/r.out, stderr in $TMP/r.err.
rollup() {
  local repo="$1" ledger="$2"
  shift 2
  R_RC=0
  (
    cd "$repo" &&
      bash "$SCRIPTS/token-rollup.sh" --spec-id SPEC-860 --ledger "$ledger" "$@"
  ) >"$TMP/r.out" 2>"$TMP/r.err" || R_RC=$?
}

last_row() { tail -n 1 "$LEDGER"; }

# assert_priced <dollars>: the last tally was a priced command line worth
# exactly <dollars> (a hand-computed figure, printed and in the ledger row).
assert_priced() {
  local want="$1" printed
  [ "$T_RC" -eq 0 ] || { echo "tally exited $T_RC: $(cat "$TMP/t.err")" >&2; return 1; }
  printed="$(cat "$TMP/t.out")"
  case "$printed" in
    *"\$$(printf '%.2f' "$want")"*) : ;;
    *) echo "printed line lacks \$$want: $printed" >&2; return 1 ;;
  esac
  case "$printed" in *unavailable*) echo "line says unavailable: $printed" >&2; return 1 ;; esac
  case "$printed" in *"lower bound"*) echo "line carries a lower-bound marker: $printed" >&2; return 1 ;; esac
  last_row | jq -e --argjson d "$want" '(.dollars != null) and (.dollars > 0) and ((.dollars - $d | fabs) < 0.000001) and (has("unpriced") | not)' >/dev/null
}

# table_id <file>: sha256:<first 16 hex of the file's sha256>.
table_id() {
  printf 'sha256:%s' "$(sha_file "$1" | cut -c1-16)"
}

# seed_state: a first run that seeds the local table from the repo's dist.
seed_state() {
  tally "$REPO" ratessonnet5
  [ "$T_RC" -eq 0 ]
  [ -s "$STATE/token-rates.json" ]
}

# model_eq <table> <model> <other-table>: the model's rows are JSON-equal.
model_eq() {
  jq -e --arg m "$2" --slurpfile o "$3" '.models[$m] == $o[0].models[$m]' "$1" >/dev/null
}

# ---------- UAT-001 ----------

@test "UAT-001: a first run seeds the local table byte-identical to the distributed table, priced, nothing in git" {
  unset GAIA_RATES_STATE_DIR
  mk_repo "$REPO"
  local before untracked f
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
  while IFS= read -r -d '' f; do
    untracked=$((untracked + 1))
  done < <(git -C "$REPO" ls-files -z --others --exclude-standard)
  [ "$untracked" -eq 0 ]
}

# ---------- UAT-002 ----------

@test "UAT-002: an unedited row byte-identical to its base takes the new distributed row; the table then equals the distributed file" {
  mk_repo "$REPO"
  seed_state
  jq '.models["claude-sonnet-5"][0].input = 3' "$FIX/dist-a.json" >"$TMP/dist-b.json"
  set_dist "$REPO" "$TMP/dist-b.json"

  tally "$REPO" ratessonnet5

  # sonnet-5 now input 3: 1e6 * 3 / 1e6 = 3.00
  assert_priced 3
  model_eq "$STATE/token-rates.json" claude-sonnet-5 "$TMP/dist-b.json"
  model_eq "$STATE/token-rates.base.json" claude-sonnet-5 "$TMP/dist-b.json"
  cmp -s "$STATE/token-rates.json" "$REPO/.gaia/scripts/token-rates.json"
}

@test "UAT-002: an unedited row differing from its base only in key order and whitespace also takes the new row" {
  mk_repo "$REPO"
  seed_state
  # Same value, keys reordered, tab-indented. The base file is left untouched.
  jq --tab '.models["claude-sonnet-5"] = [{"output": 10, "input": 2}]' "$STATE/token-rates.json" >"$TMP/reordered.json"
  cp "$TMP/reordered.json" "$STATE/token-rates.json"
  jq '.models["claude-sonnet-5"][0].input = 3' "$FIX/dist-a.json" >"$TMP/dist-b.json"
  set_dist "$REPO" "$TMP/dist-b.json"

  tally "$REPO" ratessonnet5

  assert_priced 3
  model_eq "$STATE/token-rates.json" claude-sonnet-5 "$TMP/dist-b.json"
  model_eq "$STATE/token-rates.base.json" claude-sonnet-5 "$TMP/dist-b.json"
  cmp -s "$STATE/token-rates.json" "$REPO/.gaia/scripts/token-rates.json"
}

# ---------- UAT-003 ----------

@test "UAT-003: an adopter-edited row is never replaced; the printed and ledger dollars use the edited input" {
  mk_repo "$REPO"
  seed_state
  jq_edit "$STATE/token-rates.json" '.models["claude-opus-5-5"][0].input = 3'
  jq '.models["claude-opus-5-5"][0].input = 6' "$FIX/dist-a.json" >"$TMP/dist-b.json"
  set_dist "$REPO" "$TMP/dist-b.json"

  tally "$REPO" ratesopus55

  [ "$(jq -r '.models["claude-opus-5-5"][0].input' "$STATE/token-rates.json")" = "3" ]
  # opus-5-5 edited to input 3, 1M tokens: 1e6 * 3 / 1e6 = 3.00 (not 6.00)
  assert_priced 3
}

# ---------- UAT-004 ----------

@test "UAT-004: an adopter-added model is kept and a new distributed model is added" {
  mk_repo "$REPO"
  seed_state
  jq_edit "$STATE/token-rates.json" '.models["claude-private-1"] = [{"input": 12, "output": 60}]'
  jq '.models["claude-opus-6"] = [{"input": 7, "output": 35}]' "$FIX/dist-a.json" >"$TMP/dist-b.json"
  set_dist "$REPO" "$TMP/dist-b.json"

  tally "$REPO" ratessonnet5

  [ "$T_RC" -eq 0 ]
  jq -e '.models["claude-private-1"] == [{"input": 12, "output": 60}]' "$STATE/token-rates.json" >/dev/null
  model_eq "$STATE/token-rates.json" claude-opus-6 "$TMP/dist-b.json"
}

# ---------- UAT-005 ----------

# feed_state <local-input>: local and base hold a feed-written opus-6 row (the
# provenance mark on both), the byte copy is the older dist-a. The base row is
# always input 7; the local row is <local-input>.
feed_state() {
  local local_input="$1"
  mkdir -p "$STATE"
  jq '.models["claude-opus-6"] = [{"input": 7, "output": 35, "source": "feed"}]' "$FIX/dist-a.json" >"$TMP/base.json"
  jq --argjson i "$local_input" '.models["claude-opus-6"] = [{"input": $i, "output": 35, "source": "feed"}]' "$FIX/dist-a.json" >"$TMP/local.json"
  cp "$TMP/local.json" "$STATE/token-rates.json"
  cp "$TMP/base.json" "$STATE/token-rates.base.json"
  cp "$FIX/dist-a.json" "$STATE/token-rates.dist.json"
  jq '.models["claude-opus-6"] = [{"input": 8, "output": 40}]' "$FIX/dist-a.json" >"$TMP/dist-b.json"
  mk_repo "$REPO" "$TMP/dist-b.json"
}

@test "UAT-005: an unedited feed-written row takes the distributed row and loses the provenance mark" {
  feed_state 7
  tally "$REPO" ratessonnet5
  [ "$T_RC" -eq 0 ]
  model_eq "$STATE/token-rates.json" claude-opus-6 "$TMP/dist-b.json"
  jq -e '.models["claude-opus-6"] | all(has("source") | not)' "$STATE/token-rates.json" >/dev/null
}

@test "UAT-005: an adopter-edited feed-written row is left unchanged" {
  feed_state 11
  tally "$REPO" ratessonnet5
  [ "$T_RC" -eq 0 ]
  jq -e '.models["claude-opus-6"] == [{"input": 11, "output": 35, "source": "feed"}]' "$STATE/token-rates.json" >/dev/null
}

# ---------- UAT-011 ----------

@test "UAT-011: a provisioned linked worktree heals into main's one local table" {
  unset GAIA_RATES_STATE_DIR GAIA_RATES_FEED_DISABLE
  rates_stub_start_or_skip tls serve "$FIX/feed-opus6.json"
  export GAIA_RATES_FEED_URL="$RATES_STUB_URL"
  local main="$TMP/main" wt="$TMP/wt"
  mk_repo "$main"
  mkdir -p "$main/.gaia/local"
  git -C "$main" worktree add -q "$wt" -b feature
  # link-worktree.sh's result: the worktree's whole .gaia/local is one symlink.
  ln -s "$main/.gaia/local" "$wt/.gaia/local"

  tally "$main" ratessonnet5
  [ "$T_RC" -eq 0 ]
  [ "$(rates_stub_count)" = "0" ]
  local main_before wt_before
  main_before="$(git -C "$main" status --porcelain)"
  wt_before="$(git -C "$wt" status --porcelain)"

  tally "$wt" ratesopus6
  # opus-6 healed at input 7: 1e6 * 7 / 1e6 = 7.00
  assert_priced 7
  [ "$(rates_stub_count)" = "1" ]

  local main_tel wt_tel
  main_tel="$(cd "$main/.gaia/local/telemetry" && pwd -P)"
  wt_tel="$(cd "$wt/.gaia/local/telemetry" && pwd -P)"
  [ "$main_tel" = "$wt_tel" ]
  jq -e '.models["claude-opus-6"][0].input == 7' "$main_tel/token-rates.json" >/dev/null
  [ ! -e "$wt/.gaia/local/telemetry/token-rates.json" ] || [ "$wt/.gaia/local/telemetry/token-rates.json" -ef "$main_tel/token-rates.json" ]
  [ "$(git -C "$main" status --porcelain)" = "$main_before" ]
  [ "$(git -C "$wt" status --porcelain)" = "$wt_before" ]
}

# ---------- UAT-012 ----------

@test "UAT-012: the roll-up prices a ledger row with a later-healed model from the local table" {
  mk_repo "$REPO"
  mkdir -p "$STATE"
  jq '.models["claude-opus-6"] = [{"input": 7, "output": 35, "source": "feed"}]' "$FIX/dist-a.json" >"$STATE/token-rates.json"
  cp "$STATE/token-rates.json" "$STATE/token-rates.base.json"
  cp "$FIX/dist-a.json" "$STATE/token-rates.dist.json"

  rollup "$REPO" "$FIX/ledger-opus6-haiku.jsonl"

  [ "$R_RC" -eq 0 ]
  # opus-6 7.00 + haiku 1.00 = 8.00 (each 1M fresh input)
  grep -qF 'execute:   $8.00' "$TMP/r.out"
  grep -qF 'Total:     $8.00' "$TMP/r.out"
  grep -qF 'unavailable' "$TMP/r.out" && return 1
  grep -qF 'claude-opus-6' "$TMP/r.out" && return 1

  # Control: without the healed row the same run must name opus-6 and drop its
  # share, so the assertions above can fail.
  jq_edit "$STATE/token-rates.json" 'del(.models["claude-opus-6"])'
  rollup "$REPO" "$FIX/ledger-opus6-haiku.jsonl"
  grep -qF 'lower bound: unpriced model(s) claude-opus-6' "$TMP/r.out"
  grep -qF 'execute:   $1.00' "$TMP/r.out"
}

# ---------- UAT-013 ----------

@test "UAT-013: --rate-table runs price from the file, make no request, and touch no state; the bare run heals once" {
  unset GAIA_RATES_FEED_DISABLE
  rates_stub_start_or_skip tls serve "$FIX/feed-opus6.json"
  export GAIA_RATES_FEED_URL="$RATES_STUB_URL"
  mk_repo "$REPO"
  seed_state
  [ "$(rates_stub_count)" = "0" ]
  local listing_before listing_after
  listing_before="$(state_listing "$STATE")"

  tally "$REPO" ratesopus6 --rate-table "$FIX/override-opus6.json"
  # override: opus-6 at input 9: 1e6 * 9 / 1e6 = 9.00
  assert_priced 9
  rollup "$REPO" "$FIX/ledger-opus6.jsonl" --rate-table "$FIX/override-opus6.json"
  [ "$R_RC" -eq 0 ]
  grep -qF 'execute:   $9.00' "$TMP/r.out"
  grep -qF 'Total:     $9.00' "$TMP/r.out"

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
  mk_repo "$REPO"
  mkdir -p "$STATE"
  printf '%s' "$content" >"$STATE/token-rates.json"
  cp "$STATE/token-rates.json" "$TMP/corrupt-1.copy"
  printf '{"models":{"claude-stale":[{"input":99,"output":99}]}}' >"$STATE/token-rates.base.json"

  tally "$REPO" ratessonnet5

  assert_priced 2
  files=("$STATE"/token-rates.json.corrupt.*)
  [ "${#files[@]}" -eq 1 ]
  [ -e "${files[0]}" ]
  cmp -s "${files[0]}" "$TMP/corrupt-1.copy"
  [ "$(grep -cF -- "${files[0]}" "$TMP/t.err")" -eq 1 ]
  cmp -s "$STATE/token-rates.json" "$REPO/.gaia/scripts/token-rates.json"
  jq -e --slurpfile d "$REPO/.gaia/scripts/token-rates.json" '.models == $d[0].models' "$STATE/token-rates.base.json" >/dev/null

  # A second corruption gets its own copy; the first stays byte-identical.
  first="${files[0]}"
  printf 'second corruption' >"$STATE/token-rates.json"
  tally "$REPO" ratessonnet5
  assert_priced 2
  files=("$STATE"/token-rates.json.corrupt.*)
  [ "${#files[@]}" -eq 2 ]
  cmp -s "$first" "$TMP/corrupt-1.copy"
  [ "$(grep -c 'token-rates.json.corrupt.' "$TMP/t.err")" -eq 1 ]
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
  unset GAIA_RATES_STATE_DIR GAIA_RATES_FEED_DISABLE
  rates_stub_start_or_skip tls serve "$FIX/feed-opus6.json"
  export GAIA_RATES_FEED_URL="$RATES_STUB_URL"
  local src="$TMP/src" bare="$TMP/bare.git" wt="$TMP/bare-wt"
  mk_repo "$src"
  git clone -q --bare "$src" "$bare"
  git -C "$bare" worktree add -q "$wt" -b wt-branch
  # Preconditions that make the case real: the main-checkout resolver fails
  # while the worktree still has a top level and the distributed table.
  ( cd "$wt" && bash -c 'source "$1/main-root-lib.sh"; gaia_resolve_main_root' _ "$REAL_SCRIPTS" ) >/dev/null 2>&1 && return 1
  [ -n "$(git -C "$wt" rev-parse --show-toplevel)" ]
  [ -s "$wt/.gaia/scripts/token-rates.json" ]

  tally "$wt" ratesopus6haiku

  [ "$T_RC" -eq 0 ]
  # haiku only, input 1: 1e6 * 1 / 1e6 = 1.00; opus-6 is the lower bound
  grep -qF '$1.00' "$TMP/t.out"
  grep -qF '(lower bound: unpriced model(s) claude-opus-6)' "$TMP/t.out"
  [ "$(rates_stub_count)" = "0" ]
  [ ! -e "$wt/.gaia/local" ]
  [ -z "$(find "$wt" "$bare" -name 'token-rates*' -not -path "$wt/.gaia/scripts/token-rates.json")" ]
}

# ---------- UAT-017 ----------

# uat017_files: the files the SPEC lists, one absolute path per line.
uat017_files() {
  local f
  for f in "wiki/concepts/Token Cost Readout.md" "wiki/concepts/Cost Data Contract.md" \
    "wiki/concepts/GAIA Scripts.md" "wiki/concepts/Worktrees.md" "wiki/concepts/GAIA CLI.md" \
    "wiki/index.md" ".gaia/cli/health/comprehensive/lenses/DIST.md" "CHANGELOG.md"; do
    printf '%s\n' "$REAL_ROOT/$f"
  done
  for f in "$REAL_ROOT"/.gaia/scripts/token-*.sh; do
    printf '%s\n' "$f"
  done
}

# uat017_stale <files...>: every line that still states the rate table is
# resolved per tree via --show-toplevel, or that the committed table is what
# prices (file:line:text). Duplicates collapsed.
uat017_stale() {
  local f
  # Per file, filtering the text only: a -H prefix would let a file NAME
  # containing "token-rates" satisfy the second regex.
  for f in "$@"; do
    {
      grep -n -i -e '--show-toplevel' -- "$f" | grep -i -E 'rate[ _]table|token-rates'
      grep -n -w -i -e 'committed' -- "$f" | grep -i -E 'rate[ _]table|token-rates|committed table|rate card'
    } | sort -u | sed "s|^|$f:|"
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
  local files=() f
  while IFS= read -r f; do files+=("$f"); done < <(uat017_files)
  # 8 named files plus every token-*.sh; a short read would shrink the scan.
  local n_sh
  n_sh="$(find "$REAL_SCRIPTS" -maxdepth 1 -name 'token-*.sh' | wc -l | tr -d ' ')"
  [ "${#files[@]}" -eq "$((8 + n_sh))" ]
  [ "$n_sh" -ge 4 ]
  for f in "${files[@]}"; do
    [ -s "$f" ] || { echo "missing or empty: $f" >&2; return 1; }
  done

  # The scan can fail: a line stating the old rule is caught and not allowlisted.
  printf 'The committed table prices every run via --show-toplevel rate table.\n' >"$TMP/bad.md"
  [ -n "$(uat017_unallowed "$(uat017_stale "$TMP/bad.md")")" ]

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
  grep -qF -- 'GAIA_RATES_FEED_DISABLE' "$REAL_ROOT/.gaia/cli/health/comprehensive/lenses/DIST.md"

  local unreleased
  unreleased="$(awk '/^## \[Unreleased\]/{on=1; next} /^## \[/{on=0} on' "$REAL_ROOT/CHANGELOG.md")"
  [ -n "$unreleased" ]
  case "$unreleased" in *GAIA_RATES_FEED_DISABLE*) : ;; *) return 1 ;; esac
}

# ---------- UAT-025 ----------

@test "UAT-025: a model the new distributed table removes keeps its unedited local row" {
  mk_repo "$REPO"
  seed_state
  jq 'del(.models["claude-haiku-4-5"])' "$FIX/dist-a.json" >"$TMP/dist-b.json"
  set_dist "$REPO" "$TMP/dist-b.json"

  tally "$REPO" ratessonnet5

  assert_priced 2
  model_eq "$STATE/token-rates.json" claude-haiku-4-5 "$FIX/dist-a.json"
}

# no_base_case <bytecopy: absent|old>: an edited row, no base, then a new
# distributed model.
no_base_case() {
  local copy="$1"
  mk_repo "$REPO"
  mkdir -p "$STATE"
  jq '.models["claude-opus-5-5"][0].input = 3' "$FIX/dist-a.json" >"$STATE/token-rates.json"
  cp "$STATE/token-rates.json" "$TMP/local-before.json"
  [ "$copy" = "old" ] && cp "$FIX/dist-a.json" "$STATE/token-rates.dist.json"
  jq '.models["claude-opus-6"] = [{"input": 7, "output": 35}]' "$FIX/dist-a.json" >"$TMP/dist-b.json"
  set_dist "$REPO" "$TMP/dist-b.json"

  tally "$REPO" ratesopus55

  # the edited opus-5-5 row is kept: 1e6 * 3 / 1e6 = 3.00
  assert_priced 3
  jq -e --slurpfile o "$TMP/local-before.json" '(.models | del(.["claude-opus-6"])) == $o[0].models' "$STATE/token-rates.json" >/dev/null
  model_eq "$STATE/token-rates.json" claude-opus-6 "$TMP/dist-b.json"
  [ -s "$STATE/token-rates.base.json" ]

  cp "$STATE/token-rates.json" "$TMP/local-after-1.json"
  tally "$REPO" ratesopus55
  cmp -s "$STATE/token-rates.json" "$TMP/local-after-1.json"
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
  mk_repo "$REPO"
  seed_state
  [ "$edited" = "yes" ] && jq_edit "$STATE/token-rates.json" '.cache_multipliers.read = 0.15'
  jq '.cache_multipliers.read = 0.2' "$FIX/dist-a.json" >"$TMP/dist-b.json"
  set_dist "$REPO" "$TMP/dist-b.json"

  tally "$REPO" ratessonnet5
  [ "$T_RC" -eq 0 ]
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
  local main="$TMP/main" wt="$TMP/wt" where
  mk_repo "$main"
  git -C "$main" worktree add -q "$wt" -b feature
  jq '.models["claude-sonnet-5"][0].input = 5' "$FIX/dist-a.json" >"$wt/.gaia/scripts/token-rates.json"
  git -C "$wt" commit -q -am "branch changes the sonnet-5 row"
  cmp -s "$wt/.gaia/scripts/token-rates.json" "$main/.gaia/scripts/token-rates.json" && return 1

  tally "$wt" ratessonnet5
  # main's row, not the branch's: 1e6 * 2 / 1e6 = 2.00
  assert_priced 2
  cp "$STATE/token-rates.json" "$TMP/local-1.json"
  cp "$STATE/token-rates.base.json" "$TMP/base-1.json"

  for _ in 1 2 3; do
    for where in "$main" "$wt"; do
      tally "$where" ratessonnet5
      assert_priced 2
      cmp -s "$STATE/token-rates.json" "$TMP/local-1.json"
      cmp -s "$STATE/token-rates.base.json" "$TMP/base-1.json"
      jq -e --slurpfile d "$main/.gaia/scripts/token-rates.json" '. == $d[0]' "$STATE/token-rates.json" >/dev/null
    done
  done

  tally "$wt" ratessonnet5 --rate-table "$wt/.gaia/scripts/token-rates.json"
  # the branch's row: 1e6 * 5 / 1e6 = 5.00
  assert_priced 5
  cmp -s "$STATE/token-rates.json" "$TMP/local-1.json"
}

# ---------- UAT-028 ----------

@test "UAT-028: a sync interrupted after the local table landed completes on the next run, then stays put" {
  mk_repo "$REPO"
  # New distributed table: sonnet-5 raised to 3, opus-6 added.
  jq '.models["claude-sonnet-5"][0].input = 3 | .models["claude-opus-6"] = [{"input": 7, "output": 35}]' "$FIX/dist-a.json" >"$TMP/dist-b.json"
  set_dist "$REPO" "$TMP/dist-b.json"
  mkdir -p "$STATE"
  # On disk: the merged local table (haiku edited to 1.5) was renamed into
  # place, but the base and the byte copy are still the old table's.
  jq '.models["claude-haiku-4-5"][0].input = 1.5' "$TMP/dist-b.json" >"$STATE/token-rates.json"
  cp "$FIX/dist-a.json" "$STATE/token-rates.base.json"
  cp "$FIX/dist-a.json" "$STATE/token-rates.dist.json"

  tally "$REPO" ratessonnet5

  # sonnet-5 at the new input 3: 3.00
  assert_priced 3
  [ "$(jq -r '.models["claude-haiku-4-5"][0].input' "$STATE/token-rates.json")" = "1.5" ]
  model_eq "$STATE/token-rates.json" claude-sonnet-5 "$TMP/dist-b.json"
  model_eq "$STATE/token-rates.json" claude-opus-6 "$TMP/dist-b.json"
  jq -e --slurpfile d "$TMP/dist-b.json" '. == $d[0]' "$STATE/token-rates.base.json" >/dev/null
  cmp -s "$STATE/token-rates.dist.json" "$TMP/dist-b.json"

  cp "$STATE/token-rates.json" "$TMP/l1"
  cp "$STATE/token-rates.base.json" "$TMP/b1"
  cp "$STATE/token-rates.dist.json" "$TMP/c1"
  tally "$REPO" ratessonnet5
  assert_priced 3
  cmp -s "$STATE/token-rates.json" "$TMP/l1"
  cmp -s "$STATE/token-rates.base.json" "$TMP/b1"
  cmp -s "$STATE/token-rates.dist.json" "$TMP/c1"
}

# ---------- guard: the real checkout's local state is untouched ----------
# Keep this test last: it compares against the listing setup_file captured.

@test "the real checkout's token-rates files are byte-identical to before the suite" {
  local now
  now="$(real_listing "$REAL_ROOT")"
  [ "$now" = "$RATES_REAL_LISTING_BEFORE" ]
}
