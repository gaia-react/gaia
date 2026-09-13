#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Conformance driver for UAT-012 (SPEC-081): the merge gate
# (.claude/hooks/audit-residual-shape-check.sh) and the residue tally
# (.gaia/cli/src/residue/attribution.ts, via `gaia residue-tally
# --attribute-only`) each re-implement the SAME heading/entry-unit/key
# attribution rule independently, one in bash, one in TypeScript. Nothing in
# the tree shares that logic between the two, so this suite is the guard that
# holds them together: it drives both over one shared fixture corpus
# (.gaia/tests/fixtures/residue-corpus/) and asserts they produce the same
# per-unit attribution, and that both agree with a hand-written oracle
# (expected-attribution.json).
#
# CANONICAL TUPLE FORM: "<unit_start_line>|<disposition>|<keyed>|<key>", one
# per entry unit beneath a canonical heading. `keyed` is 1 for both
# attribution.ts's `entries[]` (a unit whose key parses cleanly) and its
# `malformed[]` (a unit whose key matches the gate's grammar but fails field
# validation) -- the gate's own key regex has no field validation, so it
# scores both the same way (unit_keyed=1, key=<the matched inner text>). This
# is the Phase 1a carry-forward resolution: `entries` + `malformed` +
# `keyless` is a clean partition of entry units against the gate's one tuple
# per unit, with `malformed` sitting on the `keyed=1` side. `keyed` is 0 for
# `keyless[]`, with `key` reported as `-`.
#
# WHY A THREE-WAY COMPARISON, NOT TWO. Two implementations agreeing on
# nothing is also agreement: an empty tuple set diffs cleanly against another
# empty set. The hand-written oracle is what keeps this from passing over a
# vacuous corpus, per `.claude/rules/guards-must-fail.md`'s "assert the input
# set is non-empty and the expected size."

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABS="$HOOKS_SRC/audit-residual-shape-check.sh"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CORPUS_DIR="$REPO_ROOT/.gaia/tests/fixtures/residue-corpus"
  GAIA_BIN="$REPO_ROOT/.gaia/cli/gaia"

  [ -d "$CORPUS_DIR" ] || {
    echo "residue-attribution-conformance.bats: corpus dir missing: $CORPUS_DIR" >&2
    return 1
  }
  [ -x "$GAIA_BIN" ] || [ -f "$GAIA_BIN" ] || {
    echo "residue-attribution-conformance.bats: CLI bundle missing: $GAIA_BIN" >&2
    return 1
  }
}

# make_mutant_dir NAME: a fresh scratch directory under $BATS_TEST_TMPDIR
# holding a real copy of .claude/hooks/lib/ (unmodified). Precedent:
# audit-residual-shape-check.bats. The hook resolves its libraries off its
# own on-disk location rather than cwd, so a mutated copy dropped alone
# cannot find them and fails at the jq-availability guard before it ever
# reads the mutation.
make_mutant_dir() {
  local dir="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$dir/lib"
  cp "$HOOKS_SRC"/lib/*.sh "$dir/lib/"
  printf '%s' "$dir"
}

# install_gh_mock_ok BODY: puts a mock `gh` ahead of PATH whose `pr view`
# answers with BODY. This suite only needs the "ok" arm of the shared mock
# in audit-residual-shape-check.bats; a minimal local copy avoids depending
# on a fixture that lives in a sibling test file.
install_gh_mock_ok() {
  local content="$1"
  GH_BIN="$BATS_TEST_TMPDIR/gh-bin"
  mkdir -p "$GH_BIN"
  local body_file="$BATS_TEST_TMPDIR/gh-body.json"
  jq -n --arg b "$content" '{body: $b}' > "$body_file"
  cat > "$GH_BIN/gh" <<SH
#!/usr/bin/env bash
body_file="$body_file"
SH
  cat >> "$GH_BIN/gh" <<'SH'
case "$1 $2" in
  "pr view") cat "$body_file" ;;
esac
exit 0
SH
  chmod +x "$GH_BIN/gh"
}

# gate_tuples_for_hook HOOK OUT_FILE: for every pull-request body in
# $CORPUS_DIR/prs.json, drives HOOK through the real gh-mocked merge path
# with GAIA_AUDIT_RESIDUAL_DEBUG_EMIT pointed at a per-body scratch file, and
# appends every emitted line to OUT_FILE as "<pr_number>\t<tuple>". OUT_FILE
# is truncated first.
gate_tuples_for_hook() {
  local hook="$1" out="$2" pr_number body emit_file json
  : > "$out"

  while IFS= read -r pr_number; do
    body="$(jq -r --arg n "$pr_number" '.[] | select(.number==($n|tonumber)) | .body' "$CORPUS_DIR/prs.json")"
    install_gh_mock_ok "$body"
    emit_file="$BATS_TEST_TMPDIR/emit-${hook//\//_}-$pr_number.tsv"
    rm -f "$emit_file"
    json=$(jq -n --arg c "gh pr merge 123 --squash --delete-branch" '{tool_name: "Bash", tool_input: {command: $c}}')
    PATH="$GH_BIN:$PATH" GAIA_AUDIT_RESIDUAL_DEBUG_EMIT="$emit_file" \
      bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$hook" > /dev/null

    [ -f "$emit_file" ] || continue
    while IFS=$'\t' read -r _tag f1 f2 f3 f4; do
      [ -n "$_tag" ] || continue
      local line disp keyed key
      line="${f1#unit_start_line=}"
      disp="${f2#disposition=}"
      keyed="${f3#keyed=}"
      key="${f4#key=}"
      printf '%s\t%s|%s|%s|%s\n' "$pr_number" "$line" "$disp" "$keyed" "$key" >> "$out"
    done < "$emit_file"
  done < <(jq -r '.[].number' "$CORPUS_DIR/prs.json")
}

# tally_tuples_for_fixture_dir FIXTURE_DIR OUT_FILE: runs `gaia residue-tally
# --attribute-only` against FIXTURE_DIR and writes "<pr_number>\t<tuple>"
# lines to OUT_FILE, built from entries[], malformed[] (both keyed=1, per the
# header note above), and keyless[] (keyed=0, key=-).
tally_tuples_for_fixture_dir() {
  local fixture_dir="$1" out="$2" raw
  raw="$BATS_TEST_TMPDIR/tally-attribute-only.json"
  GAIA_RESIDUE_FIXTURE_DIR="$fixture_dir" node "$GAIA_BIN" residue-tally --attribute-only > "$raw"
  jq -r '
    .bodies[] | .pr_number as $n | (
      (.entries[]   | "\($n)\t\(.unit_start_line)|\(.disposition)|1|\(.raw_key)"),
      (.malformed[] | "\($n)\t\(.unit_start_line)|\(.disposition)|1|\(.raw_key)"),
      (.keyless[]   | "\($n)\t\(.unit_start_line)|\(.disposition)|0|-")
    )
  ' "$raw" > "$out"
}

# oracle_tuples_for_fixture_dir FIXTURE_DIR OUT_FILE: the hand-written
# oracle, converted to the same "<pr_number>\t<tuple>" line shape.
oracle_tuples_for_fixture_dir() {
  local fixture_dir="$1" out="$2"
  jq -r '.bodies[] | .pr_number as $n | .tuples[] | "\($n)\t\(.)"' \
    "$fixture_dir/expected-attribution.json" > "$out"
}

# assert_nonempty_matching_size FILE EXPECTED_COUNT: the guards-must-fail
# obligation -- assert the input set is non-empty AND the expected size
# before any content comparison runs.
assert_nonempty_matching_size() {
  local file="$1" expected="$2" actual
  actual="$(wc -l < "$file" | tr -d ' ')"
  [ "$actual" -gt 0 ] || return 1
  [ "$actual" -eq "$expected" ] || return 1
}

# ---------------------------------------------------------------------------
# Main conformance assertion (UAT-012, criteria 1-2).
# ---------------------------------------------------------------------------

@test "the gate and the tally agree on every fixture body's attribution, and both equal the hand-written oracle" {
  local oracle_sorted gate_sorted tally_sorted oracle_count

  oracle_tuples_for_fixture_dir "$CORPUS_DIR" "$BATS_TEST_TMPDIR/oracle-raw.txt"
  sort "$BATS_TEST_TMPDIR/oracle-raw.txt" > "$BATS_TEST_TMPDIR/oracle.sorted.txt"
  oracle_sorted="$BATS_TEST_TMPDIR/oracle.sorted.txt"
  oracle_count="$(wc -l < "$oracle_sorted" | tr -d ' ')"

  # The oracle itself must be non-empty: a size of 0 would make every
  # downstream size-equality check vacuously satisfiable.
  [ "$oracle_count" -gt 0 ] || return 1

  gate_tuples_for_hook "$HOOK_ABS" "$BATS_TEST_TMPDIR/gate-raw.txt"
  sort "$BATS_TEST_TMPDIR/gate-raw.txt" > "$BATS_TEST_TMPDIR/gate.sorted.txt"
  gate_sorted="$BATS_TEST_TMPDIR/gate.sorted.txt"

  tally_tuples_for_fixture_dir "$CORPUS_DIR" "$BATS_TEST_TMPDIR/tally-raw.txt"
  sort "$BATS_TEST_TMPDIR/tally-raw.txt" > "$BATS_TEST_TMPDIR/tally.sorted.txt"
  tally_sorted="$BATS_TEST_TMPDIR/tally.sorted.txt"

  # Size before content, per .claude/rules/guards-must-fail.md.
  assert_nonempty_matching_size "$gate_sorted" "$oracle_count" \
    || { echo "gate tuple count $(wc -l < "$gate_sorted") != oracle count $oracle_count" >&2; return 1; }
  assert_nonempty_matching_size "$tally_sorted" "$oracle_count" \
    || { echo "tally tuple count $(wc -l < "$tally_sorted") != oracle count $oracle_count" >&2; return 1; }

  diff "$gate_sorted" "$oracle_sorted" || { echo "gate diverges from the oracle (above)" >&2; return 1; }
  diff "$tally_sorted" "$oracle_sorted" || { echo "tally diverges from the oracle (above)" >&2; return 1; }
  diff "$gate_sorted" "$tally_sorted" || { echo "gate diverges from tally directly (above)" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# Guards-must-fail: an emptied corpus reds the non-empty/size assertion
# rather than passing over nothing (acceptance criterion 1).
# ---------------------------------------------------------------------------

@test "guard-must-fail: emptying the corpus in a scratch copy reds the non-empty tuple-set assertion" {
  local empty_dir="$BATS_TEST_TMPDIR/empty-corpus"
  mkdir -p "$empty_dir"
  printf '[]\n' > "$empty_dir/prs.json"
  printf '[]\n' > "$empty_dir/issues.json"
  printf '{}\n' > "$empty_dir/blobs.json"
  printf '{"bodies":[],"schema":"v1"}\n' > "$empty_dir/expected-attribution.json"

  oracle_tuples_for_fixture_dir "$empty_dir" "$BATS_TEST_TMPDIR/empty-oracle-raw.txt"
  local empty_count
  empty_count="$(wc -l < "$BATS_TEST_TMPDIR/empty-oracle-raw.txt" | tr -d ' ')"
  [ "$empty_count" -eq 0 ] || return 1

  # The guard: assert_nonempty_matching_size must itself fail on this input,
  # proving the size-before-content obligation is not vacuous.
  assert_nonempty_matching_size "$BATS_TEST_TMPDIR/empty-oracle-raw.txt" 0 && return 1
  true
}

# ---------------------------------------------------------------------------
# Mutation control, gate side (UAT-012's second clause; acceptance
# criterion 3). Runs against a scratch copy; the real hook is never touched.
# ---------------------------------------------------------------------------

@test "mutation control: mutating the gate's CANON_WAIVE recognizer in a scratch copy makes the comparison fail" {
  local dir mutant oracle_sorted mutant_sorted
  dir="$(make_mutant_dir mutant-canon-waive)"
  mutant="$dir/audit-residual-shape-check.sh"
  sed "s/^CANON_WAIVE='## Out-of-scope machinery findings (recorded, not filed)'\$/CANON_WAIVE='## MUTATED waive heading'/" \
    "$HOOK_ABS" > "$mutant"
  chmod +x "$mutant"
  # The substitution must have actually landed, or this control proves
  # nothing about the mutant and everything about a stale sed pattern.
  grep -qF "CANON_WAIVE='## MUTATED waive heading'" "$mutant" || return 1

  oracle_tuples_for_fixture_dir "$CORPUS_DIR" "$BATS_TEST_TMPDIR/mc-oracle-raw.txt"
  sort "$BATS_TEST_TMPDIR/mc-oracle-raw.txt" > "$BATS_TEST_TMPDIR/mc-oracle.sorted.txt"
  oracle_sorted="$BATS_TEST_TMPDIR/mc-oracle.sorted.txt"

  gate_tuples_for_hook "$mutant" "$BATS_TEST_TMPDIR/mc-mutant-raw.txt"
  sort "$BATS_TEST_TMPDIR/mc-mutant-raw.txt" > "$BATS_TEST_TMPDIR/mc-mutant.sorted.txt"
  mutant_sorted="$BATS_TEST_TMPDIR/mc-mutant.sorted.txt"

  # Every unit beneath a waive-canonical heading (PRs 2000, 2003, 3002, 3008,
  # 5002, 5004, 5006) is no longer recognized by the mutant, so its tuples
  # vanish from the mutant's output: the comparison MUST fail.
  if diff "$mutant_sorted" "$oracle_sorted" >/dev/null 2>&1; then
    echo "mutation control did not diverge: the CANON_WAIVE mutant still agrees with the oracle" >&2
    return 1
  fi

  # Name which side diverged: every waive-disposition tuple the oracle
  # carries must be absent from the mutant's output.
  grep -F '|waive|' "$oracle_sorted" > "$BATS_TEST_TMPDIR/mc-oracle-waive.txt"
  [ -s "$BATS_TEST_TMPDIR/mc-oracle-waive.txt" ] || return 1
  while IFS= read -r missing_tuple; do
    grep -qF "$missing_tuple" "$mutant_sorted" && {
      echo "expected waive tuple '$missing_tuple' to be MISSING from the mutant's output but it was present" >&2
      return 1
    }
  done < "$BATS_TEST_TMPDIR/mc-oracle-waive.txt"
  true
}
