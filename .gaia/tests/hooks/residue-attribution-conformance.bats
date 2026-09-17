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

  # Every unit beneath a waive-canonical heading is no longer recognized by the
  # mutant, so its tuples vanish from the mutant's output: the comparison MUST
  # fail. Which pull requests those are is derived from the oracle below rather
  # than listed here, so the corpus can grow without rotting a comment.
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
# ---------------------------------------------------------------------------
# SPEC-082 (task-conformance-suite.md): the frozen twelve-reader table
# (UAT-012) for the dedup key's path=... terminator, and the run-time
# three-prong derivation that must agree with it in both directions.
#
# WHY THIS EXISTS. Phase 2 moved twelve readers across four dialects (bash
# POSIX ERE, JavaScript, jq under Oniguruma and gojq, and the committed CLI
# bundle's copies of the JavaScript ones) to one rule: terminate the path on
# the key comment's own closer. Nothing in the tree shares a constant
# between them -- two are runnable prose in two different jq dialects and
# one is a bash ERE -- so this table, and the reconciliation that keeps it
# honest, is the only place that couples them.
# ---------------------------------------------------------------------------

# reader_table: id|file|subject|literal, one row per reader that terminates
# the dedup key's path=... field on the key comment's own closer. It is NOT
# every reader that parses that field: two readers deliberately stay on the
# pre-change `path=.+` and are held by non_movers() below, which is where to
# look before concluding this table is the whole set. `subject` is `line` or
# `body`; `literal` is the reader's exact post-change pattern text. Authored from running the
# three derivation prongs below and reading their output, not copied from
# the plan doc; the first SPEC-082 test below re-derives the set at every
# run, comparing derived_file_counts against table_file_counts in both
# directions, so this table cannot drift from the tree in silence.
reader_table() {
  cat <<'TABLE'
1|.claude/hooks/audit-residual-shape-check.sh|line|<!-- gaia-debt-key: (v1 class=[^ ]+ path=[^>]+ line=[0-9]+) -->
2|.gaia/cli/src/residue/key.ts|line|<!-- gaia-debt-key: (v1 class=[^ ]+ path=[^>]+ line=[0-9]+) -->
3|.gaia/cli/src/residue/key.ts|line|^v1 class=([^ ]+) path=([^>]+) line=(\d+)$
4|.gaia/cli/gaia|line|<!-- gaia-debt-key: (v1 class=[^ ]+ path=[^>]+ line=[0-9]+) -->
5|.gaia/cli/gaia|line|^v1 class=([^ ]+) path=([^>]+) line=(\d+)$
6|.claude/hooks/lib/audit-dispositions.sh|line|^v1 class=[^[:space:]]+ path=[^>]+ line=[0-9]+$
7|.claude/hooks/lib/audit-dispositions.sh|line|mw_path="${mw_path% line=*}"
8|wiki/concepts/PR Merge Workflow.md|line|<!-- gaia-debt-key: (?<key>v1 class=[^ ]+ path=(?<path>[^>]+) line=(?<line>[0-9]+)) -->
9|.gaia/cli/src/residue/key.ts|body|<!-- gaia-debt-key:[^>]*?path=([^>\n]+) line=
10|.gaia/cli/gaia|body|<!-- gaia-debt-key:[^>]*?path=([^>\n]+) line=
11|.gaia/scripts/debt-count-refresh.sh|body|<!-- gaia-debt-key:[^>]*?path=([^>\n]+) line=
12|.claude/skills/gaia/references/debt.md|body|<!-- gaia-debt-key: v1 class=(?<class>[^ ]+) path=(?<path>[^>\n]+) line=(?<line>[0-9]+) -->
TABLE
}

# The six directories a reader can live on (task-conformance-suite.md,
# "The scope, and the exclusions").
READER_SCOPE_DIRS=(
  ".claude/hooks/"
  ".claude/skills/"
  ".gaia/cli/src/residue/"
  ".gaia/cli/gaia"
  ".gaia/scripts/"
  "wiki/concepts/"
)

# The one exclusion that is load-bearing against READER_SCOPE_DIRS above:
# this directory sits NESTED inside the scoped .gaia/cli/src/residue/, and
# this suite's own sibling Deliverables 5 and 6 deliberately write the
# mutant literals `path=([^>]+) line=` and `path=[^ ]+` there. The other
# four entries the plan names as exclusions (this suite's own file,
# .gaia/tests/, .gaia/tests/fixtures/dedup-key-corpus/, .gaia/local/) name
# paths that were never inside READER_SCOPE_DIRS to begin with, so a
# pathspec exclude for them changes nothing; the exclusion-lift test below
# demonstrates that finding rather than asserting it.
NESTED_TEST_EXCLUSION=".gaia/cli/src/residue/__tests__/"

# Prong 1: the key literal, file-level locator only. Cannot separate row 6
# from row 7 inside one file, and most of what it returns is not a reader at
# all; it is a smoke check that the scope resolves to something, not a
# reconciliation. The two-way reconciliation below runs over prong 2 and
# prong 3, so a file prong 1 names is not thereby required to appear in
# reader_table or exclusion_table.
prong1_locator() {
  git -C "$REPO_ROOT" grep -n 'gaia-debt-key' -- "${READER_SCOPE_DIRS[@]}"
}

# Prong 2: the moved path patterns. The row producer. The optional group
# opener and optional newline exclusion are both load-bearing (proven by
# prong2_narrower_spelling below).
prong2_row_producer() {
  git -C "$REPO_ROOT" grep -nE 'path=(\(\?<path>|\()?\[\^>(\\n)?\]' \
    -- "${READER_SCOPE_DIRS[@]}" ":!$NESTED_TEST_EXCLUSION"
}

# The narrower spelling acceptance criterion 2a uses to prove prong 2's
# widening is load-bearing rather than incidental: it must match all
# LINE-scoped rows but miss every BODY-scoped one.
prong2_narrower_spelling() {
  git -C "$REPO_ROOT" grep -nE 'path=\[\^>\]|path=\(\[\^>\]|path=\(\?<path>\[\^>\]|path=\[\^>\\n\]' \
    -- "${READER_SCOPE_DIRS[@]}" ":!$NESTED_TEST_EXCLUSION"
}

# Prong 3: row 7. A pair of parameter expansions, invisible to prongs 1 and
# 2 in principle (not merely in this spelling), so it needs a locator keyed
# on its own text.
prong3_row7_locator() {
  git -C "$REPO_ROOT" grep -nF '${key#*path=}' -- "${READER_SCOPE_DIRS[@]}"
}

# derived_hits: "<file><TAB><content>", one per prong-2/prong-3 match. Row
# 7's derived content is its OWN locator line (line 501, `${key#*path=}`),
# not the table's row-7 literal (line 502, the OTHER expansion) -- the two
# sit on separate source lines by construction (task-conformance-suite.md,
# Deliverable 1, row 7's note), so reconciliation is done at per-file
# granularity (derived_file_counts) rather than by matching literal text
# against a single hit line, and Deliverable 1's presence pass (below)
# separately confirms the table's own row-7 literal is really there.
derived_hits() {
  { prong2_row_producer; prong3_row7_locator; } | while IFS= read -r hit; do
    local file="${hit%%:*}" rest content
    rest="${hit#*:}"
    content="${rest#*:}"
    printf '%s\t%s\n' "$file" "$content"
  done
}

# derived_file_counts / table_file_counts: "<file><TAB><count>", sorted.
# File-granularity rather than per-literal correlation, so row 7's two-line
# shape (see derived_hits above) reconciles correctly: awk's field split is
# on a literal tab, so a file path carrying a space (row 8) is one field.
derived_file_counts() {
  derived_hits | awk -F'\t' '{count[$1]++} END {for (f in count) print f"\t"count[f]}' | sort
}

table_file_counts_from() {
  awk -F'|' '{count[$2]++} END {for (f in count) print f"\t"count[f]}' "$1" | sort
}

table_file_counts() {
  local tmp="$BATS_TEST_TMPDIR/reader-table-real.txt"
  reader_table > "$tmp"
  table_file_counts_from "$tmp"
}

# The exclusion table for acceptance criterion 2b: id|path|reason.
exclusion_table() {
  cat <<'TABLE'
this-suites-own-file|.gaia/tests/hooks/residue-attribution-conformance.bats|its TABLE heredoc holds all twelve post-change literals in the literal column
gaia-tests-dir|.gaia/tests/|every fixture and every sibling suite here carries key text, including deliberate mutant spellings
nested-cli-tests|.gaia/cli/src/residue/__tests__/|Deliverables 5 and 6 write scratch mutant literals here deliberately
dedup-key-corpus|.gaia/tests/fixtures/dedup-key-corpus/|Phase 1's README.md records the pre-change and post-change spellings verbatim
gaia-local|.gaia/local/|plan and working-state artifacts, including this plan, quote every literal in the set
TABLE
}

# non_movers: file|literal, every reader that parses the dedup key's path
# field and deliberately does NOT take the closer-terminated grammar. Prong 2
# greps for the post-change `[^>]` spellings, so a reader left on `path=.+` is
# invisible to the derivation by construction and can never appear in the
# symmetric difference. The anchor is what makes it survivable rather than
# safe: on a line carrying ONE key comment the trailing ` line=<int> -->`
# terminates the path on the closer, so the greedy `.+` has nowhere to run.
# On an unindented line carrying TWO, the anchored pattern still matches the
# whole line and `.+` runs straight across the first closer, which is the very
# splice class SPEC-082 exists to close. That splice is exercised only
# against other readers, by the suites driving the `two-keys-one-line.md`
# fixture (`git grep -ln two-keys-one-line -- '*.bats' '*.test.ts'` names
# them, so the set is counted at read time rather than cached here); none of
# them reaches these two patterns, so for them it stands open by the decision
# below rather than by coverage.
# The decision not to convert them does not rest on the splice being
# impossible: it rests on conversion narrowing a blocking pre-file guard,
# which SPEC-082 puts under `ask_first` with the default do not. The
# table exists so the omission is stated rather than silent, and so that a
# later edit to either reader reds here instead of passing unseen.
non_movers() {
  cat <<'TABLE'
.gaia/scripts/check-debt-issue-metadata.sh|^<!-- gaia-debt-key: v1 class=[^ ]+ path=.+ line=[0-9]+ -->$
.gaia/scripts/check-debt-issue-metadata.sh|s/^<!-- gaia-debt-key: v1 class=[^ ]+ path=(.+) line=[0-9]+ -->$/\1/p
TABLE
}

@test "SPEC-082: the two deliberate non-movers still carry their pre-change path grammar" {
  local file literal found=0
  while IFS='|' read -r file literal; do
    [ -n "$file" ] || continue
    found=$((found + 1))
    grep -qF -- "$literal" "$REPO_ROOT/$file" || {
      echo "non-mover missing from $file: $literal" >&2
      echo "either this reader took the closer-terminated grammar, in which case it belongs in reader_table and this row goes, or it drifted; neither may pass silently" >&2
      return 1
    }
  done < <(non_movers)
  [ "$found" -eq 2 ] || {
    echo "expected 2 non-mover rows, read $found" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Deliverable 1 / acceptance criteria 1-2b.
# ---------------------------------------------------------------------------

@test "SPEC-082: the three derivation prongs each do real work, and their combined output reconciles with the frozen table" {
  local prong1_out prong2_out prong3_out prong2_narrow_out

  prong1_out="$(prong1_locator)"
  echo "prong 1 (locator) output:" >&2
  printf '%s\n' "$prong1_out" >&2
  [ -n "$prong1_out" ] || { echo "prong 1 returned nothing; the scope is likely wrong" >&2; return 1; }

  prong2_out="$(prong2_row_producer)"
  echo "prong 2 (row producer) output:" >&2
  printf '%s\n' "$prong2_out" >&2
  local prong2_count
  prong2_count="$(printf '%s\n' "$prong2_out" | grep -c . || true)"
  [ "$prong2_count" -eq 11 ] || {
    echo "prong 2 returned $prong2_count matches, expected 11 (12 rows minus row 7, which only prong 3 sees)" >&2
    return 1
  }

  prong3_out="$(prong3_row7_locator)"
  echo "prong 3 (row 7 locator) output:" >&2
  printf '%s\n' "$prong3_out" >&2
  local prong3_count
  prong3_count="$(printf '%s\n' "$prong3_out" | grep -c . || true)"
  [ "$prong3_count" -eq 1 ] || {
    echo "prong 3 returned $prong3_count matches, expected exactly 1 (row 7)" >&2
    return 1
  }

  # 2a: the widened spelling is load-bearing. The narrower spelling must
  # match every LINE-scoped row that carries a pattern and miss all four
  # BODY-scoped rows (9, 10, 11, 12). The assertion below carries the
  # enumeration in its own failure message; do not restate it here, a
  # second copy is what drifts.
  prong2_narrow_out="$(prong2_narrower_spelling)"
  echo "prong 2's narrower spelling output (for comparison):" >&2
  printf '%s\n' "$prong2_narrow_out" >&2
  local narrow_count
  narrow_count="$(printf '%s\n' "$prong2_narrow_out" | grep -c . || true)"
  [ "$narrow_count" -eq 7 ] || {
    echo "the narrower spelling matched $narrow_count lines, expected 7 (the 7 LINE-scoped source lines: rows 1, 2, 3, 4, 5, 6, 8; row 7 is invisible to prong 2 regardless of spelling)" >&2
    return 1
  }
  printf '%s\n' "$prong2_narrow_out" | grep -qF 'path=[^>\n]' && {
    printf '%s\n' "the narrower spelling matched a body-scoped ([^>\\n]) literal; it should miss all four" >&2
    return 1
  }

  # Reconciliation, two-way, at file granularity (see derived_hits's own
  # comment for why file granularity rather than per-literal correlation).
  local derived table
  derived="$(derived_file_counts)"
  table="$(table_file_counts)"
  [ -n "$derived" ] || { echo "the derivation produced nothing" >&2; return 1; }
  [ -n "$table" ] || { echo "the table produced nothing" >&2; return 1; }

  local diff_out
  if ! diff_out="$(diff <(printf '%s\n' "$derived") <(printf '%s\n' "$table"))"; then
    echo "reader-set reconciliation disagrees; symmetric difference (derived vs table):" >&2
    echo "$diff_out" >&2
    return 1
  fi

  # Presence: every table row's literal appears byte for byte in its file.
  while IFS='|' read -r id file subject literal; do
    [ -n "$id" ] || continue
    grep -qF -- "$literal" "$REPO_ROOT/$file" || {
      echo "row $id: literal not found verbatim in $file: $literal" >&2
      return 1
    }
  done < <(reader_table)

  # Subject correctness: every line-subject row's literal contains [^>] and
  # not the newline exclusion; every body-subject row's literal contains
  # the newline exclusion. Row 7 is exempt (a parameter expansion, not a
  # pattern).
  while IFS='|' read -r id file subject literal; do
    [ -n "$id" ] || continue
    if [ "$id" = "7" ]; then
      continue
    fi
    case "$subject" in
      line)
        case "$literal" in
          *'[^>]'*) ;;
          *) echo "row $id: subject=line but literal carries no [^>]: $literal" >&2; return 1 ;;
        esac
        case "$literal" in
          *'[^>\n]'*) echo "row $id: subject=line but literal carries the newline exclusion: $literal" >&2; return 1 ;;
        esac
        ;;
      body)
        case "$literal" in
          *'[^>\n]'*) ;;
          *) echo "row $id: subject=body but literal carries no newline exclusion: $literal" >&2; return 1 ;;
        esac
        ;;
      *) echo "row $id: unrecognized subject '$subject'" >&2; return 1 ;;
    esac
  done < <(reader_table)

  # The version token, over the strict-gate-grammar rows only. Rows 7, 9,
  # 10, 11 are exempt by id (row 7: no grammar at all; rows 9-11: the
  # lenient grammar and its two mirrors, which carry no v1 token by design).
  while IFS='|' read -r id file subject literal; do
    [ -n "$id" ] || continue
    case "$id" in
      7|9|10|11) continue ;;
    esac
    case "$literal" in
      *v1*) ;;
      *) echo "row $id: strict-grammar row carries no v1 token: $literal" >&2; return 1 ;;
    esac
    case "$literal" in
      *v2*) echo "row $id: carries a v2 token: $literal" >&2; return 1 ;;
    esac
  done < <(reader_table)
}

@test "SPEC-082 guard-must-fail: deleting a table row (a reader present in the tree, missing from the table) reds the reconciliation" {
  local mutant_table="$BATS_TEST_TMPDIR/table-missing-row3.txt"
  reader_table | grep -v '^3|' > "$mutant_table"

  local derived mutant
  derived="$(derived_file_counts)"
  mutant="$(table_file_counts_from "$mutant_table")"

  if diff <(printf '%s\n' "$derived") <(printf '%s\n' "$mutant") >/dev/null 2>&1; then
    echo "deleting row 3 (KEY_FIELD_PATTERNS.gate) from the table did not change the reconciliation; the guard cannot see a missing row" >&2
    return 1
  fi
  true
}

@test "SPEC-082 guard-must-fail: adding a table row for a file carrying no such literal reds the reconciliation" {
  local mutant_table="$BATS_TEST_TMPDIR/table-extra-row.txt"
  reader_table > "$mutant_table"
  printf '13|.gaia/scripts/debt-count-refresh.sh|line|this literal appears nowhere in the tree\n' >> "$mutant_table"

  local derived mutant
  derived="$(derived_file_counts)"
  mutant="$(table_file_counts_from "$mutant_table")"

  if diff <(printf '%s\n' "$derived") <(printf '%s\n' "$mutant") >/dev/null 2>&1; then
    echo "adding a bogus row to the table did not change the reconciliation; the guard cannot see an unbacked row" >&2
    return 1
  fi
  true
}

@test "SPEC-082 (criterion 2b): every exclusion is doing work -- lifting it picks up something that is not a reader" {
  local base_hits
  base_hits="$({ prong2_row_producer; prong3_row7_locator; } | wc -l | tr -d ' ')"

  local id extra_path reason lifted_hits
  while IFS='|' read -r id extra_path reason; do
    [ -n "$id" ] || continue
    if [ "$id" = "nested-cli-tests" ]; then
      # Load-bearing against READER_SCOPE_DIRS: lift by NOT excluding it
      # (it is already reachable by inclusion of .gaia/cli/src/residue/).
      lifted_hits="$(git -C "$REPO_ROOT" grep -nE 'path=(\(\?<path>|\()?\[\^>(\\n)?\]' -- "${READER_SCOPE_DIRS[@]}" | wc -l | tr -d ' ')"
      lifted_hits=$((lifted_hits + $(git -C "$REPO_ROOT" grep -cF '${key#*path=}' -- "${READER_SCOPE_DIRS[@]}" 2>/dev/null | awk -F: '{sum+=$2} END{print sum+0}')))
      [ "$lifted_hits" -gt "$base_hits" ] || {
        echo "lifting exclusion '$id' ($extra_path) did not pick up any new match; claimed reason: $reason" >&2
        return 1
      }
    elif [ "$id" = "gaia-local" ]; then
      # .gaia/local/ is gitignored (.gitignore:64), so a git-grep-based
      # derivation can never reach it regardless of scope: the pathspec
      # exclude is doubly inert here (outside READER_SCOPE_DIRS AND
      # unreachable by git grep at all). The git-grep invariance asserted
      # below is the half that holds on every checkout, so it is the half
      # that gates.
      #
      # The stated reason -- that there is pattern text under there for a
      # plain filesystem grep to see -- is a claim about untracked working
      # state, and this suite cannot turn that into a gate in either
      # direction. A fresh clone and every CI runner have no .gaia/local/ at
      # all, and on a checkout that has one its contents are whatever that
      # machine's tooling last wrote; this plan folder, the reason's own
      # example, is deleted at archive. Asserting presence would red on a
      # green tree over state the tree does not carry. So the substance is
      # confirmed opportunistically, where the directory exists.
      #
      # Both branches write a notice rather than failing, and those notices are
      # legible only to a reader who runs this suite with the output of passing
      # tests shown. bats discards them otherwise, so on CI they reach nobody.
      # That is the accepted shape: the branches exist so the arm does not
      # silently mean less than its name, and there is no channel from a
      # passing bats test to a CI log to put them on.
      #
      # THE PRESENT-BUT-EMPTY BRANCH MUST NOT FAIL, for exactly the reason the
      # paragraph above gives for not asserting presence. The directory's
      # existence says nothing about its contents: both are untracked working
      # state, and on a CI runner the directory is created by whichever sibling
      # suites happen to share this shard. `capture-red-observations.bats` is
      # one -- its header states that it runs its hook from the repo root and
      # writes the resolved, gitignored .gaia/local/red-ledger/ path -- and
      # nothing it writes there carries this pattern. Which suites share a
      # shard is decided by the weight-based partition in
      # .gaia/tests/bats-shards.sh, so it is re-derived whenever any suite in
      # the directory grows. A branch that reds on that is a gate on shard
      # assignment wearing this arm's name, and it reds a green tree.
      if [ -d "$REPO_ROOT/$extra_path" ]; then
        if grep -rlE 'path=(\(\?<path>|\()?\[\^>(\\n)?\]' "$REPO_ROOT/$extra_path" >/dev/null 2>&1; then
          echo "exclusion '$id': $extra_path carries the pattern text on this checkout, so the filesystem half of its reason is confirmed here" >&2
        else
          echo "exclusion '$id': $extra_path exists on this checkout but carries no pattern text a plain grep can see (untracked working state, whatever this machine's tooling last wrote), so the filesystem half of its reason is unconfirmed; the git-grep invariance below still gates" >&2
        fi
      else
        echo "exclusion '$id': $extra_path is absent on this checkout (untracked working state), so the filesystem half of its reason is unconfirmed; the git-grep invariance below still gates" >&2
      fi
      local prong2_baseline
      prong2_baseline="$(prong2_row_producer | wc -l | tr -d ' ')"
      lifted_hits="$(git -C "$REPO_ROOT" grep -nE 'path=(\(\?<path>|\()?\[\^>(\\n)?\]' -- "${READER_SCOPE_DIRS[@]}" ":!$NESTED_TEST_EXCLUSION" "$extra_path" 2>/dev/null | wc -l | tr -d ' ')"
      [ "$lifted_hits" -eq "$prong2_baseline" ] || {
        echo "exclusion '$id': expected git grep to see no change (gitignored), but prong-2 hit count moved from $prong2_baseline to $lifted_hits" >&2
        return 1
      }
    else
      lifted_hits="$(git -C "$REPO_ROOT" grep -nE 'path=(\(\?<path>|\()?\[\^>(\\n)?\]' -- "${READER_SCOPE_DIRS[@]}" ":!$NESTED_TEST_EXCLUSION" "$extra_path" | wc -l | tr -d ' ')"
      lifted_hits=$((lifted_hits + $(git -C "$REPO_ROOT" grep -cF '${key#*path=}' -- "${READER_SCOPE_DIRS[@]}" "$extra_path" 2>/dev/null | awk -F: '{sum+=$2} END{print sum+0}')))
      [ "$lifted_hits" -gt "$base_hits" ] || {
        echo "lifting exclusion '$id' ($extra_path) did not pick up any new match; claimed reason: $reason" >&2
        return 1
      }
    fi
  done < <(exclusion_table)
}
# ---------------------------------------------------------------------------
# Deliverable 2: per-row mutants. Eleven reverts (rows 1-6, 8-12) plus one
# corruption (row 7, which this SPEC leaves unchanged by construction, so a
# revert is a no-op that cannot red anything -- see row_seven_corrupted_literal).
# ---------------------------------------------------------------------------

# row_reverts: id|old_literal, the pre-change spelling for every row except
# row 7. Read off the actual Phase 2 commit's diff (07376e28), not
# reconstructed by inference.
row_reverts() {
  cat <<'TABLE'
1|<!-- gaia-debt-key: (v1 class=[^ ]+ path=[^ ]+ line=[0-9]+) -->
2|<!-- gaia-debt-key: (v1 class=[^ ]+ path=[^ ]+ line=[0-9]+) -->
3|^v1 class=([^ ]+) path=([^ ]+) line=(\d+)$
4|<!-- gaia-debt-key: (v1 class=[^ ]+ path=[^ ]+ line=[0-9]+) -->
5|^v1 class=([^ ]+) path=([^ ]+) line=(\d+)$
6|^v1 class=[^[:space:]]+ path=.+ line=[0-9]+$
8|<!-- gaia-debt-key: (?<key>v1 class=[^ ]+ path=(?<path>[^ ]+) line=(?<line>[0-9]+)) -->
9|<!-- gaia-debt-key:[^>]*?path=(.+?) line=
10|<!-- gaia-debt-key:[^>]*?path=(.+?) line=
11|<!-- gaia-debt-key:[^>]*?path=(.+?) line=
12|<!-- gaia-debt-key: v1 class=(?<class>[^ ]+) path=(?<path>.+) line=(?<line>[0-9]+) -->
TABLE
}

# Row 7 is unchanged by construction (`${mw_path% line=*}` cuts at the last
# ` line=` and is terminator-agnostic), so a revert is a no-op. Its mutant is
# instead an arbitrary corruption: shortest match to longest match.
row_seven_corrupted_literal() {
  printf '%s' 'mw_path="${mw_path%% line=*}"'
}

table_row_field() {
  local id="$1" field="$2"
  reader_table | awk -F'|' -v id="$id" -v f="$field" '$1==id{print $f}'
}

revert_literal_for() {
  local id="$1"
  row_reverts | awk -F'|' -v id="$id" '$1==id{print $2}'
}

# apply_literal_mutant REL_FILE ORIGINAL REPLACEMENT OUT_FILE: writes a
# mutated copy of REL_FILE (resolved under $REPO_ROOT) to OUT_FILE with the
# first (and only) occurrence of ORIGINAL replaced by REPLACEMENT. Node
# (already a hard dependency of this suite, via $GAIA_BIN) rather than sed
# or bash parameter expansion: both of those interpret regex/glob
# metacharacters in the search text, and every literal here IS a regex or a
# shell parameter expansion carrying exactly those metacharacters.
apply_literal_mutant() {
  local rel_file="$1" original="$2" replacement="$3" out_file="$4"
  mkdir -p "$(dirname "$out_file")"
  node -e '
    const fs = require("fs");
    const [srcPath, original, replacement, outPath] = process.argv.slice(1);
    const content = fs.readFileSync(srcPath, "utf8");
    const count = content.split(original).length - 1;
    if (count !== 1) {
      console.error(
        `apply_literal_mutant: literal occurs ${count} times in ${srcPath}, expected exactly 1`
      );
      process.exit(1);
    }
    const mutated = content.replace(original, replacement);
    fs.writeFileSync(outPath, mutated);
  ' "$REPO_ROOT/$rel_file" "$original" "$replacement" "$out_file"
}

@test "SPEC-082 (Deliverable 2, static): each single-row mutant makes that row's own presence assertion red, twelve rows" {
  local id file subject table_literal mutant_dest failures="" rows_checked=0
  local old_literal corrupted

  while IFS='|' read -r id file subject table_literal; do
    [ -n "$id" ] || continue
    rows_checked=$((rows_checked + 1))
    mutant_dest="$BATS_TEST_TMPDIR/static-row-${id}-$(basename "$file")"

    if [ "$id" = "7" ]; then
      corrupted="$(row_seven_corrupted_literal)"
      if ! apply_literal_mutant "$file" "$table_literal" "$corrupted" "$mutant_dest" 2>&2; then
        failures="$failures row-$id(apply-failed)"
        continue
      fi
    else
      old_literal="$(revert_literal_for "$id")"
      if [ -z "$old_literal" ]; then
        failures="$failures row-$id(no-revert-literal)"
        continue
      fi
      if ! apply_literal_mutant "$file" "$table_literal" "$old_literal" "$mutant_dest" 2>&2; then
        failures="$failures row-$id(apply-failed)"
        continue
      fi
    fi

    if grep -qF -- "$table_literal" "$mutant_dest"; then
      failures="$failures row-$id(did-not-red)"
    else
      echo "row $id ($file): static mutant reds" >&2
    fi
  done < <(reader_table)

  [ "$rows_checked" -eq 12 ] || {
    echo "expected to check 12 rows, checked $rows_checked" >&2
    return 1
  }

  [ -z "$failures" ] || {
    echo "the following rows did NOT red under their static mutant:$failures" >&2
    return 1
  }
}

@test "SPEC-082 (Deliverable 2, criterion 4): the all-rows-mutated run reds (RT-006's observe-against-the-unmodified-tree obligation)" {
  # Every row reverted (row 7 corrupted, since it has no revert) is the
  # unmodified tree by another name: rebuild every mutant file in one
  # scratch tree and confirm the reconciliation's own presence pass reds
  # against every one of them at once, not merely one at a time.
  local id file subject table_literal old_literal corrupted mutant_dest
  local any_still_present=""

  while IFS='|' read -r id file subject table_literal; do
    [ -n "$id" ] || continue
    mutant_dest="$BATS_TEST_TMPDIR/allrows-row-${id}-$(basename "$file")"

    if [ "$id" = "7" ]; then
      corrupted="$(row_seven_corrupted_literal)"
      apply_literal_mutant "$file" "$table_literal" "$corrupted" "$mutant_dest"
    else
      old_literal="$(revert_literal_for "$id")"
      apply_literal_mutant "$file" "$table_literal" "$old_literal" "$mutant_dest"
    fi

    if grep -qF -- "$table_literal" "$mutant_dest"; then
      any_still_present="$any_still_present row-$id"
    fi
  done < <(reader_table)

  echo "all-rows-mutated run: every row's post-change literal absent from its mutant (rows still carrying it:${any_still_present:- none})" >&2

  [ -z "$any_still_present" ] || {
    echo "rows still carrying the post-change literal after mutation:$any_still_present" >&2
    return 1
  }
}
# withoutGroups_bash: bash mirror of attribution.test.ts's withoutGroups
# helper (strips capture parentheses), used to demonstrate row 3's mutant
# textually without needing a TS runtime to import a scratch module copy.
withoutGroups_bash() {
  printf '%s' "$1" | tr -d '()'
}

@test "SPEC-082 (Deliverable 2, criterion 5): row 3's mutant is discriminating -- the recognizer-parity test stays green while this suite reds" {
  local row3_literal row3_old row3_file row2_literal mutant_key_ts
  row3_literal="$(table_row_field 3 4)"
  row3_old="$(revert_literal_for 3)"
  row3_file="$(table_row_field 3 2)"
  row2_literal="$(table_row_field 2 4)"
  mutant_key_ts="$BATS_TEST_TMPDIR/row3-key.ts"

  apply_literal_mutant "$row3_file" "$row3_literal" "$row3_old" "$mutant_key_ts"

  # This suite's own presence assertion for row 3: reds.
  if grep -qF -- "$row3_literal" "$mutant_key_ts"; then
    echo "row 3's mutant did not red against this suite's own presence assertion" >&2
    return 1
  fi
  echo "row 3 mutant result: this suite's presence assertion REDS (KEY_FIELD_PATTERNS.gate's literal absent)" >&2

  # Row 2 (KEY_PATTERN) is the ONLY literal attribution.test.ts's
  # recognizer-parity test reads; a row-3-only mutation must leave it
  # untouched.
  grep -qF -- "$row2_literal" "$mutant_key_ts" || {
    echo "row 3's mutant unexpectedly disturbed row 2 (KEY_PATTERN); the mutant is not row-scoped" >&2
    return 1
  }

  # Reproduce the parity test's own comparison (withoutGroups on both
  # sides) over the untouched row-2 literal vs the gate's key_re.
  local gate_key_re left right
  gate_key_re="$(grep -oE "key_re='.*'" "$HOOK_ABS" | sed -E "s/^key_re='(.*)'\$/\1/")"
  left="$(withoutGroups_bash "$row2_literal")"
  right="$(withoutGroups_bash "$gate_key_re")"
  [ "$left" = "$right" ] || {
    echo "row 3 mutant result: the row-2/gate comparison is not equal; something else is wrong" >&2
    return 1
  }
  echo "row 3 mutant result: the recognizer-parity test (KEY_PATTERN vs the gate's key_re) stays GREEN, because it never reads KEY_FIELD_PATTERNS.gate -- this is the partial edit no other check in the tree can see" >&2
}

@test "SPEC-082 (Deliverable 2, criterion 6, line-scoped): the gate permits PR 3006's spaced path with the real key_re and denies it with row 1 reverted" {
  # Real (unmutated) gate.
  gate_tuples_for_hook "$HOOK_ABS" "$BATS_TEST_TMPDIR/behavior-real.txt"
  local real_line
  real_line="$(awk -F'\t' '$1==3006' "$BATS_TEST_TMPDIR/behavior-real.txt")"
  echo "unmutated gate, PR 3006 tuple: $real_line" >&2
  printf '%s\n' "$real_line" | grep -qF '|1|' || {
    echo "expected the unmutated gate to score PR 3006's residual keyed=1" >&2
    return 1
  }

  # Mutant: row 1's key_re reverted to the pre-change (space-terminated)
  # spelling.
  local dir mutant
  dir="$(make_mutant_dir mutant-row1-key-re)"
  mutant="$dir/audit-residual-shape-check.sh"
  apply_literal_mutant ".claude/hooks/audit-residual-shape-check.sh" \
    "$(table_row_field 1 4)" "$(revert_literal_for 1)" "$mutant"
  chmod +x "$mutant"

  gate_tuples_for_hook "$mutant" "$BATS_TEST_TMPDIR/behavior-mutant.txt"
  local mutant_line
  mutant_line="$(awk -F'\t' '$1==3006' "$BATS_TEST_TMPDIR/behavior-mutant.txt")"
  echo "row-1-reverted gate, PR 3006 tuple: ${mutant_line:-<none: the unit never matched the reverted key_re at all>}" >&2

  # A space-terminated key_re cannot match a path containing a space, so the
  # unit is keyless under the mutant (keyed=0), the mirror image of the
  # real gate's permit-and-keyed=1.
  if [ -n "$mutant_line" ]; then
    printf '%s\n' "$mutant_line" | grep -qF '|1|' && {
      echo "expected the row-1-reverted gate to NOT score PR 3006's residual keyed=1" >&2
      return 1
    }
  fi
  true
}

# extract_filer_jq_scan: the exact jq program text debt-count-refresh.sh
# runs, read at run time rather than transcribed, so this measures the
# shipped reader. Node (not sed) because the program string embeds nested
# single quotes' worth of shell-escaping risk that a portable sed capture
# cannot reliably reproduce.
extract_filer_jq_scan() {
  node -e '
    const fs = require("fs");
    const src = fs.readFileSync(process.argv[1], "utf8");
    const m = /jq -c '"'"'(.*?)'"'"' 2>\/dev\/null\)/.exec(src);
    if (!m) {
      console.error("extract_filer_jq_scan: no match in " + process.argv[1]);
      process.exit(1);
    }
    process.stdout.write(m[1]);
  ' "$REPO_ROOT/.gaia/scripts/debt-count-refresh.sh"
}

# mutate_string_literal CONTENT ORIGINAL REPLACEMENT: literal (non-regex,
# non-glob) substring replace of every occurrence, for mutating an
# already-captured string rather than a file.
mutate_string_literal() {
  node -e '
    const [content, original, replacement] = process.argv.slice(1);
    if (!content.includes(original)) {
      console.error("mutate_string_literal: original not found");
      process.exit(1);
    }
    process.stdout.write(content.split(original).join(replacement));
  ' "$1" "$2" "$3"
}

@test "SPEC-082 (Deliverable 2, criterion 6, body-scoped): the filer's jq scan yields both members with the real spelling and one spliced member with the newline exclusion stripped" {
  local filter mutated_filter body real_out mutant_out
  filter="$(extract_filer_jq_scan)"
  printf '%s\n' "$filter" | grep -qF -- "$(table_row_field 11 4)" || {
    echo "the extracted jq filter does not carry row 11's frozen literal; extraction or the reader moved" >&2
    return 1
  }

  mutated_filter="$(mutate_string_literal "$filter" '[^>\n]' '[^>]')"
  body="$(cat "$REPO_ROOT/.gaia/tests/fixtures/dedup-key-corpus/multiline-decoy-body.txt")"

  real_out="$(jq -n --arg b "$body" "[{body: \$b}] | $filter")"
  mutant_out="$(jq -n --arg b "$body" "[{body: \$b}] | $mutated_filter")"

  echo "unmutated filer scan over multiline-decoy-body.txt: $real_out" >&2
  echo "row-11-reverted-to-bare-[^>]+ filer scan over the same body: $mutant_out" >&2

  echo "$real_out" | jq -e '. == ["a.ts", "app/real.ts"]' >/dev/null || {
    echo "expected the unmutated scan to yield exactly [\"a.ts\", \"app/real.ts\"]" >&2
    return 1
  }
  local mutant_count
  mutant_count="$(echo "$mutant_out" | jq 'length')"
  [ "$mutant_count" -eq 1 ] || {
    echo "expected the mutant scan to yield exactly one spliced member, got $mutant_count" >&2
    return 1
  }
  echo "$mutant_out" | jq -e '.[0] | test("\n")' >/dev/null || {
    echo "expected the mutant's one member to contain a newline (the splice across the decoy line)" >&2
    return 1
  }
  echo "$mutant_out" | jq -e 'index("app/real.ts") == null' >/dev/null || {
    echo "expected the mutant's output to NOT contain app/real.ts as a member (it should be lost in the splice)" >&2
    return 1
  }
}
# ---------------------------------------------------------------------------
# Deliverable 3: no in-tree docstring still states that the gate refuses a
# path containing a space (UAT-012).
#
# A loose "space" + "path" + refusal-vocabulary proximity search was tried
# first and rejected: over the real scope it matched nine unrelated lines
# (whitespace tokenization in the env-read guards, `[[:space:]]` inside an
# unrelated ERE literally spelling "space", `.env`-boundary prose, git `-z`
# quoting prose, and a migration-procedure paragraph in file-tech-debt's
# SKILL.md that correctly narrates the OLD grammar in past tense as part of
# instructions for a FUTURE format change). None of those are the falsified
# claim this deliverable exists to catch, so the search is scoped to the
# specific phrasing this SPEC actually falsified (confirmed against the
# Phase 2 commit's diff, 07376e28) rather than a generic heuristic.
# ---------------------------------------------------------------------------

FALSIFIED_DOCSTRING_SCOPE=(
  ".gaia/cli/src/residue/"
  ".claude/hooks/"
  ".gaia/scripts/debt-count-refresh.sh"
  ".claude/skills/"
  "wiki/"
)

# falsified_docstring_hits DIR...: the exact falsified phrase Phase 2 fixed
# in key.ts's parseKey, plus the narrower phrasing family it belongs to
# (the gate/parser refusing, denying, or rejecting a path because it
# contains a space).
falsified_docstring_hits() {
  {
    grep -rniF 'a path carrying a space is the usual cause' "$@" 2>/dev/null
    grep -rniE '(gate|parser|grammar) (refuses|denies|rejects).{0,40}space|space.{0,40}(is refused|is denied|is rejected|cannot be keyed)' "$@" 2>/dev/null
  } || true
}

@test "SPEC-082 (Deliverable 3): no scoped docstring still claims the gate refuses a spaced path" {
  local hits
  hits="$(falsified_docstring_hits \
    "${FALSIFIED_DOCSTRING_SCOPE[@]/#/$REPO_ROOT/}" \
    2>/dev/null | grep -v "/.gaia/tests/fixtures/dedup-key-corpus/\|/CHANGELOG.md\|/.gaia/tests/hooks/residue-attribution-conformance.bats" || true)"

  [ -z "$hits" ] || {
    echo "found a docstring that still reads as claiming the gate refuses a spaced path:" >&2
    echo "$hits" >&2
    return 1
  }
}

@test "SPEC-082 (Deliverable 3) guard-must-fail: reinstating the falsified sentence in a scratch copy reds the assertion" {
  local scratch="$BATS_TEST_TMPDIR/key-with-falsified-sentence.ts"
  cp "$REPO_ROOT/.gaia/cli/src/residue/key.ts" "$scratch"
  printf '\n// key does not match the gate grammar; a path carrying a space is the usual cause\n' >> "$scratch"

  local hits
  hits="$(falsified_docstring_hits "$scratch")"

  [ -n "$hits" ] || {
    echo "reinstating the falsified sentence did not trip the assertion; it is vacuous" >&2
    return 1
  }
  echo "guard-can-fail proof: the reinstated sentence trips the assertion: $hits" >&2
}
# ---------------------------------------------------------------------------
# Deliverable 4 (AUDIT finding MIG-006): the invariant the filer scan's
# lazy-to-greedy swap rests on, asserted as a property over the committed
# corpus rather than an empirical byte-comparison against mutable live
# state.
#
# The discriminating token is ` line=`, not `path=`: the swap is
# lazy-to-greedy, so it changes where a match STOPS relative to the LAST
# ` line=` before the closer, not how many `path=` tokens a comment carries.
# ---------------------------------------------------------------------------

# ground_truth_inner_counts FILE: for each line, extracts the ground-truth
# inner key text (the LAST literal "<!-- gaia-debt-key:" occurrence through
# the first following " -->", the same rule Phase 1's capture-provenance
# script used) and prints "<line_eq_count><TAB><path_eq_count><TAB><line>".
# A line carrying no opener/closer pair at all (prose-only, or a pre-v1
# malformed key) prints 0\t0\t<line>.
ground_truth_inner_counts() {
  node -e '
    const fs = require("fs");
    const lines = fs.readFileSync(process.argv[1], "utf8").split("\n").filter((l) => l.length > 0);
    for (const line of lines) {
      const openerIdx = line.lastIndexOf("<!-- gaia-debt-key:");
      if (openerIdx === -1) { console.log("0\t0\t" + line); continue; }
      const afterOpener = openerIdx + "<!-- gaia-debt-key:".length;
      const closerIdx = line.indexOf(" -->", afterOpener);
      if (closerIdx === -1) { console.log("0\t0\t" + line); continue; }
      const inner = line.slice(afterOpener, closerIdx);
      const lineEq = (inner.match(/ line=/g) || []).length;
      const pathEq = (inner.match(/path=/g) || []).length;
      console.log(lineEq + "\t" + pathEq + "\t" + line);
    }
  ' "$1"
}

@test "SPEC-082 (Deliverable 4): the primary property -- no key comment in the committed corpus carries more than one ' line=' token" {
  local corpus="$REPO_ROOT/.gaia/tests/fixtures/dedup-key-corpus/recorded-keys.txt"
  [ -f "$corpus" ] || { echo "corpus missing: $corpus" >&2; return 1; }

  # Non-vacuity: report the input size before either property runs.
  local total
  total="$(wc -l < "$corpus" | tr -d ' ')"
  [ "$total" -gt 0 ] || { echo "recorded-keys.txt is empty" >&2; return 1; }
  echo "non-vacuity: recorded-keys.txt carries $total lines" >&2

  local line_eq path_eq content violations=""
  while IFS=$'\t' read -r line_eq path_eq content; do
    [ -n "$content" ] || continue
    if [ "$line_eq" -gt 1 ]; then
      violations="$violations
$content (line_eq=$line_eq)"
    fi
  done < <(ground_truth_inner_counts "$corpus")

  [ -z "$violations" ] || {
    echo "the following key comments carry more than one ' line=' token:" >&2
    printf '%s\n' "$violations" >&2
    return 1
  }
}

@test "SPEC-082 (Deliverable 4, secondary, kept): every key comment in the committed corpus carries exactly one 'path=' token" {
  local corpus="$REPO_ROOT/.gaia/tests/fixtures/dedup-key-corpus/recorded-keys.txt"
  local line_eq path_eq content violations=""

  while IFS=$'\t' read -r line_eq path_eq content; do
    [ -n "$content" ] || continue
    # Scoped to comments that carry the field at all: the 6 legitimate
    # corpus lines with no path=/line= token (prose-only mentions, and
    # pre-v1 malformed keys) are not key comments in the grammar's sense.
    if [ "$path_eq" -ge 1 ] && [ "$path_eq" -ne 1 ]; then
      violations="$violations
$content (path_eq=$path_eq)"
    fi
  done < <(ground_truth_inner_counts "$corpus")

  [ -z "$violations" ] || {
    echo "the following key comments carry other than exactly one 'path=' token:" >&2
    printf '%s\n' "$violations" >&2
    return 1
  }
}

@test "SPEC-082 (Deliverable 4) guard-must-fail: a scratch line carrying two ' line=' tokens reds the primary property and leaves the secondary property green" {
  local scratch="$BATS_TEST_TMPDIR/two-line-eq-tokens.txt"
  printf '<!-- gaia-debt-key: v1 class=c path=app/a.ts line=1 line=2 -->\n' > "$scratch"

  local line_eq path_eq content
  IFS=$'\t' read -r line_eq path_eq content < <(ground_truth_inner_counts "$scratch")

  echo "scratch line: line_eq=$line_eq path_eq=$path_eq" >&2

  [ "$line_eq" -gt 1 ] || {
    echo "expected the scratch line to trip the primary (line_eq>1) property; it did not (line_eq=$line_eq)" >&2
    return 1
  }
  [ "$path_eq" -eq 1 ] || {
    echo "expected the scratch line's secondary (path_eq==1) property to stay green; it did not (path_eq=$path_eq)" >&2
    return 1
  }
  echo "guard-can-fail proof: primary property REDS (line_eq=2), secondary property stays GREEN (path_eq=1) -- confirming the primary property is the one that discriminates" >&2
}
# ---------------------------------------------------------------------------
# Deliverable 4a (UAT-003 arm a): when one line inside an open residual unit
# carries two wrapped keys, the gate's emitted key= field is byte-equal to
# the FIRST wrapped key on the line. The gate yields no path and no line of
# its own, so nothing else is asserted of it.
# ---------------------------------------------------------------------------

@test "SPEC-082 (Deliverable 4a / UAT-003 arm a): the gate's emitted key= is the FIRST wrapped key on a continuation line carrying two" {
  local fixture="$REPO_ROOT/.gaia/tests/fixtures/dedup-key-corpus/two-keys-one-line.md"
  [ -f "$fixture" ] || { echo "fixture missing: $fixture" >&2; return 1; }

  local content
  content="$(cat "$fixture")"
  install_gh_mock_ok "$content"

  local emit_file json
  emit_file="$BATS_TEST_TMPDIR/emit-two-keys.tsv"
  rm -f "$emit_file"
  json=$(jq -n --arg c "gh pr merge 9001 --squash --delete-branch" '{tool_name: "Bash", tool_input: {command: $c}}')
  PATH="$GH_BIN:$PATH" GAIA_AUDIT_RESIDUAL_DEBUG_EMIT="$emit_file" \
    bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$HOOK_ABS" > /dev/null

  [ -f "$emit_file" ] || { echo "the gate never wrote a debug emit for the two-keys fixture" >&2; return 1; }

  local emitted_key expected
  emitted_key="$(cut -f5 "$emit_file" | sed 's/^key=//' | head -1)"
  expected="v1 class=a path=wiki/concepts/PR Merge Workflow.md line=7"

  [ "$emitted_key" = "$expected" ] || {
    echo "expected the gate's emitted key= to equal the first wrapped key verbatim: got '$emitted_key', want '$expected'" >&2
    return 1
  }
}

@test "SPEC-082 (Deliverable 4a) guard-must-fail: a scratch gate with a greedy path group splices the key across both keys on the line" {
  local dir mutant
  dir="$(make_mutant_dir mutant-greedy-path-group)"
  mutant="$dir/audit-residual-shape-check.sh"
  apply_literal_mutant ".claude/hooks/audit-residual-shape-check.sh" \
    "$(table_row_field 1 4)" \
    '<!-- gaia-debt-key: (v1 class=[^ ]+ path=.+ line=[0-9]+) -->' \
    "$mutant"
  chmod +x "$mutant"

  local fixture="$REPO_ROOT/.gaia/tests/fixtures/dedup-key-corpus/two-keys-one-line.md"
  local content
  content="$(cat "$fixture")"
  install_gh_mock_ok "$content"

  local emit_file json
  emit_file="$BATS_TEST_TMPDIR/emit-two-keys-greedy.tsv"
  rm -f "$emit_file"
  json=$(jq -n --arg c "gh pr merge 9001 --squash --delete-branch" '{tool_name: "Bash", tool_input: {command: $c}}')
  PATH="$GH_BIN:$PATH" GAIA_AUDIT_RESIDUAL_DEBUG_EMIT="$emit_file" \
    bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$mutant" > /dev/null

  local emitted_key expected
  emitted_key="$(cut -f5 "$emit_file" | sed 's/^key=//' | head -1)"
  expected="v1 class=a path=wiki/concepts/PR Merge Workflow.md line=7"

  echo "greedy-path-group mutant emitted key=: $emitted_key" >&2

  [ "$emitted_key" != "$expected" ] || {
    echo "expected the greedy-path-group mutant to splice the key across both keys on the line; it did not" >&2
    return 1
  }
  printf '%s\n' "$emitted_key" | grep -qF 'wiki/concepts/Task Orchestration.md' || {
    echo "expected the spliced key to contain text from the SECOND key too" >&2
    return 1
  }
}
# ---------------------------------------------------------------------------
# Deliverable 4b (UAT-006, third arm): the filer's jq scan over #1250's
# committed recorded key. UAT-006 names three readers over this byte-copy;
# the TypeScript half (parseWrappedKeys, parseKey) is Deliverable 5 in
# uat-end-to-end.test.ts, and this is the third: jq rather than TypeScript.
# ---------------------------------------------------------------------------

@test "SPEC-082 (Deliverable 4b / UAT-006 third arm): the filer's jq scan yields the PR Merge Workflow path from #1250's recorded key" {
  local key_fixture="$REPO_ROOT/.gaia/tests/fixtures/dedup-key-corpus/issue-1250-key.txt"
  [ -f "$key_fixture" ] || { echo "fixture missing: $key_fixture" >&2; return 1; }

  local filter body result
  filter="$(extract_filer_jq_scan)"
  body="$(cat "$key_fixture")"
  result="$(jq -n --arg b "$body" "[{body: \$b}] | $filter")"

  echo "filer scan over #1250's recorded key: $result" >&2

  # Assert the path and nothing else: the scan's single capture group is the
  # path, and ` line=` is only its terminator, so no line number is yielded
  # at all -- not a gap in this test, a real asymmetry between the three
  # UAT-006 readers.
  echo "$result" | jq -e '. == ["wiki/concepts/PR Merge Workflow.md"]' >/dev/null || {
    echo "expected the filer scan to yield exactly [\"wiki/concepts/PR Merge Workflow.md\"]" >&2
    return 1
  }
}

@test "SPEC-082 (Deliverable 4b) contrast: the gate's pre-change line-scoped [^ ]+ yields nothing for the same key" {
  local key_fixture="$REPO_ROOT/.gaia/tests/fixtures/dedup-key-corpus/issue-1250-key.txt"
  local key old_gate_re

  key="$(cat "$key_fixture")"
  old_gate_re='<!-- gaia-debt-key: (v1 class=[^ ]+ path=[^ ]+ line=[0-9]+) -->'

  if printf '%s' "$key" | grep -qE -- "$old_gate_re"; then
    echo "expected the pre-change [^ ]+ spelling to yield NO match against a key whose path contains a space; it matched" >&2
    return 1
  fi
  echo "contrast confirmed: the gate's pre-change line-scoped [^ ]+ yields nothing for #1250's spaced path, where the filer scan (above) yields the path cleanly" >&2
}
# ---------------------------------------------------------------------------
# Deliverable 4c (UAT-009): classification.tsv's own properties. A committed
# table can contradict its own README with nothing red, so SPEC success
# criterion 2 (every recorded key parses after to the same path and line)
# rests on this case rather than on Phase 1's one-shot prose.
# ---------------------------------------------------------------------------

CLASSIFICATION_TSV_HEADER_COLUMNS="key_line contains_gt line_eq_count path_eq_count gate_old_parses gate_new_parses gate_old_path gate_new_path gate_old_line gate_new_line waive_old_parses waive_new_parses waive_old_path waive_new_path lenient_old_parses lenient_new_parses lenient_old_path lenient_new_path"

# classification_group_violations TSV GROUP OLD_PARSES NEW_PARSES OLD_PATH NEW_PATH [OLD_LINE NEW_LINE]:
# for every row whose contains_gt is 0 and whose <group>_old_parses is 1,
# asserts <group>_new_parses is 1, <group>_new_path is byte-identical to
# <group>_old_path, and (gate only, when OLD_LINE/NEW_LINE are given) an
# equal <group>_new_line. One documented exception: the `lenient` group
# skips a key_line carrying more than one literal "<!-- gaia-debt-key:"
# occurrence -- the corpus README's "Finding 1" row, where the terminator
# change fixes a latent splice bug in the pre-change lenient reader rather
# than regressing it, so its path legitimately differs while both sides
# still parse. Prints one "<row>: <reason>" line per violation.
classification_group_violations() {
  local file="$1" group="$2" op="$3" np="$4" opath="$5" npath="$6" oline="${7:-0}" nline="${8:-0}"
  awk -F'\t' -v op="$op" -v np="$np" -v opath="$opath" -v npath="$npath" \
    -v oline="$oline" -v nline="$nline" -v group="$group" '
    NR==1 { next }
    {
      tmp = $1
      opens_two = (gsub(/<!-- gaia-debt-key:/, "X", tmp) > 1)
      contains_gt = $2
    }
    contains_gt == 0 && $(op) == 1 {
      if (group == "lenient" && opens_two) next
      if ($(np) != 1) { print NR": "group"_new_parses moved to "$(np)" (expected 1)"; next }
      if ($(opath) != $(npath)) { print NR": "group" path changed ("$(opath)" -> "$(npath)")"; next }
      if (oline != "0" && $(oline) != $(nline)) { print NR": "group" line changed ("$(oline)" -> "$(nline)")" }
    }
  ' "$file"
}

@test "SPEC-082 (Deliverable 4c / UAT-009): classification.tsv's own narrowing property holds per group (gate, waive, lenient)" {
  local tsv="$REPO_ROOT/.gaia/tests/fixtures/dedup-key-corpus/classification.tsv"
  [ -f "$tsv" ] || { echo "classification.tsv missing: $tsv" >&2; return 1; }

  # Non-vacuity: a non-empty row count, reported before the property runs.
  local row_count
  row_count="$(($(wc -l < "$tsv" | tr -d ' ') - 1))"
  [ "$row_count" -gt 0 ] || { echo "classification.tsv has no data rows" >&2; return 1; }
  echo "non-vacuity: classification.tsv carries $row_count data rows" >&2

  # Header presence: every column name this case reads must be in the
  # header, or a renamed column would red-lessly match nothing.
  local header missing=""
  header="$(head -1 "$tsv")"
  local col
  for col in $CLASSIFICATION_TSV_HEADER_COLUMNS; do
    printf '%s\n' "$header" | grep -qF -- "$col" || missing="$missing $col"
  done
  [ -z "$missing" ] || {
    echo "classification.tsv's header is missing expected column(s):$missing" >&2
    return 1
  }

  local violations
  violations="$( {
    classification_group_violations "$tsv" gate 5 6 7 8 9 10
    classification_group_violations "$tsv" waive 11 12 13 14
    classification_group_violations "$tsv" lenient 15 16 17 18
  } )"

  [ -z "$violations" ] || {
    echo "classification.tsv's own narrowing property does not hold:" >&2
    echo "$violations" >&2
    return 1
  }
}

@test "SPEC-082 (Deliverable 4c) guard-must-fail: corrupting one contains_gt=0 row to regress from parsing to not parsing reds the case, naming the row" {
  local real="$REPO_ROOT/.gaia/tests/fixtures/dedup-key-corpus/classification.tsv"
  local scratch="$BATS_TEST_TMPDIR/classification-corrupted.tsv"

  # Find the first contains_gt=0, gate_old_parses=1 row not exempted by the
  # Finding-1 carve-out, and flip its gate_new_parses to 0 in a scratch copy.
  local target_row
  target_row="$(awk -F'\t' 'NR>1 { tmp=$1; n=gsub(/<!-- gaia-debt-key:/, "X", tmp); if ($2==0 && $5==1 && n<=1) { print NR; exit } }' "$real")"
  [ -n "$target_row" ] || { echo "could not find a corruptible row to test against" >&2; return 1; }

  awk -F'\t' -v OFS='\t' -v target="$target_row" 'NR==target { $6=0 } { print }' "$real" > "$scratch"

  local violations
  violations="$(classification_group_violations "$scratch" gate 5 6 7 8 9 10)"

  echo "corrupted row $target_row, gate group result: ${violations:-<none: guard did not fire>}" >&2

  [ -n "$violations" ] || {
    echo "corrupting row $target_row's gate_new_parses did not red the case" >&2
    return 1
  }
  printf '%s\n' "$violations" | grep -qF "${target_row}:" || {
    echo "the reported violation does not name the corrupted row ($target_row)" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Plan-time finding #1 (README.md, "Plan-time findings the orchestrator must
# carry forward"), gate-side half. UAT-002 asserts a key carrying an
# embedded malformed tail (`path=app/a.ts line=1 line=2`) goes gate-keyed
# AND CLI-malformed[]. The TypeScript half of this pin (the CLI resolves it
# to the spliced path in entries[], not malformed[]) lives in
# uat-end-to-end.test.ts; this is the gate half: the gate permits the merge
# and scores the unit keyed=1, which is true and is the SPEC's real
# loosening.
# ---------------------------------------------------------------------------

@test "SPEC-082 plan-time finding #1 (gate half): the gate permits and scores keyed=1 a unit whose key carries an embedded malformed tail" {
  local body
  body=$'## Accepted residuals (recorded, not fixed)\n- MARKER_UAT002, an embedded malformed tail <!-- gaia-debt-key: v1 class=lint path=app/a.ts line=1 line=2 -->'
  install_gh_mock_ok "$body"

  local emit_file json
  emit_file="$BATS_TEST_TMPDIR/emit-uat002.tsv"
  rm -f "$emit_file"
  json=$(jq -n --arg c "gh pr merge 9002 --squash --delete-branch" '{tool_name: "Bash", tool_input: {command: $c}}')
  local status
  PATH="$GH_BIN:$PATH" GAIA_AUDIT_RESIDUAL_DEBUG_EMIT="$emit_file" \
    bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$HOOK_ABS" > /dev/null
  status=$?

  [ "$status" -eq 0 ] || {
    echo "expected the gate to permit the merge (exit 0), got exit $status" >&2
    return 1
  }

  [ -f "$emit_file" ] || { echo "the gate never wrote a debug emit" >&2; return 1; }

  local keyed key
  keyed="$(cut -f4 "$emit_file" | sed 's/^keyed=//' | head -1)"
  key="$(cut -f5 "$emit_file" | sed 's/^key=//' | head -1)"

  [ "$keyed" = "1" ] || {
    echo "expected keyed=1, got keyed=$keyed" >&2
    return 1
  }
  [ "$key" = "v1 class=lint path=app/a.ts line=1 line=2" ] || {
    echo "expected the emitted key= to be the full unparsed key text, got: $key" >&2
    return 1
  }
}
