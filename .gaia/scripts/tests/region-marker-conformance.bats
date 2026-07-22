#!/usr/bin/env bats
# Cross-implementation conformance suite for the whole-line marker-pair
# parsers: `.gaia/cli/src/update/region-markers.ts` (TypeScript, the region
# oracle's parser), `.gaia/scripts/write-audit-remits.sh` (the writer), and
# `.gaia/scripts/verify-audit-roster.sh`'s `_verify_roster_read_regions` (the
# check). One fixture set drives all three REAL implementations, never a
# reimplementation of their `grep -cxF` counting: this suite is only a
# conformance test if it executes the scripts it binds against.
#
# Each fixture is a one-member roster (`code-audit-fixture`, default: true,
# globs `fixture/a/**` + `fixture/b/**`) plus that member's agent definition,
# written fresh into `$BATS_TEST_TMPDIR` for every probe so the writer's
# in-place rewrite of one probe's copy never contaminates another's.
#
# Assertion style follows .claude/rules/bats-assertions.md: POSIX `[ ]` for
# equality/status, `grep -qF` for substrings, explicit `return 1` branches.

setup() {
  THIS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  PROJECT_ROOT="$(git -C "$THIS_DIR" rev-parse --show-toplevel)"
  CLI_DIR="$PROJECT_ROOT/.gaia/cli"
  WRITER="$PROJECT_ROOT/.gaia/scripts/write-audit-remits.sh"
  CHECKER="$PROJECT_ROOT/.gaia/scripts/verify-audit-roster.sh"

  # This suite runs the real TypeScript parser through tsx, which needs the
  # CLI's node_modules. audit-ci-tests.yml runs `bats .gaia/scripts/tests/`
  # wholesale on a lean box that installs only `bats` and `python3-yaml`: no
  # actions/setup-node, no pnpm, no `pnpm install`. Skip cleanly there rather
  # than failing a required PR check for an environment this suite cannot
  # control. CI coverage comes from cli-tests.yml instead, which installs the
  # CLI's dependencies and runs this file by name, so the skip never hides the
  # binding: on that runner the guard is false and all six tests execute.
  [ -d "$CLI_DIR/node_modules" ] || skip "no node_modules on this runner"

  START_MARKER='<!-- gaia:audit-remit:start -->'
  END_MARKER='<!-- gaia:audit-remit:end -->'
}

teardown() {
  rm -rf "${BATS_TEST_TMPDIR:?}"/sandbox-*
}

# --- Sandbox + fixture helpers ----------------------------------------------

# Writes a fresh one-member roster + agent file under $BATS_TEST_TMPDIR and
# prints its path. $1 = unique suffix, $2 = the agent file's full body.
make_sandbox() {
  local suffix="$1" body="$2" dir
  dir="$BATS_TEST_TMPDIR/sandbox-$suffix"
  mkdir -p "$dir/.gaia" "$dir/.claude/agents"
  cat > "$dir/.gaia/audit-ci.yml" <<'YAML'
auditors:
  - name: code-audit-fixture
    globs:
      - "fixture/a/**"
      - "fixture/b/**"
    scope: adopter
    push_fixes: true
    default: true
YAML
  printf '%s\n' "$body" > "$dir/.claude/agents/code-audit-fixture.md"
  printf '%s' "$dir"
}

fixture_ok() {
  printf -- '---\nname: code-audit-fixture\n---\n\n## Remit and self-skip\n\n%s\n- `fixture/a/**`\n- `fixture/b/**`\n\nplaceholder sentence.\n%s\n\nTrailing content.\n' \
    "$START_MARKER" "$END_MARKER"
}

fixture_absent() {
  printf -- '---\nname: code-audit-fixture\n---\n\n## Remit and self-skip\n\nno markers at all here.\n'
}

fixture_dup_start() {
  printf -- '---\nname: code-audit-fixture\n---\n\n## Remit and self-skip\n\n%s\n- `fixture/a/**`\n%s\n- `fixture/b/**`\n%s\n' \
    "$START_MARKER" "$START_MARKER" "$END_MARKER"
}

fixture_unbalanced() {
  printf -- '---\nname: code-audit-fixture\n---\n\n## Remit and self-skip\n\n%s\n- `fixture/a/**`\n- `fixture/b/**`\n' \
    "$START_MARKER"
}

fixture_inverted() {
  printf -- '---\nname: code-audit-fixture\n---\n\n## Remit and self-skip\n\n%s\n- `fixture/a/**`\n- `fixture/b/**`\n\nplaceholder sentence.\n%s\n' \
    "$END_MARKER" "$START_MARKER"
}

fixture_substring() {
  printf -- '---\nname: code-audit-fixture\n---\n\n## Remit and self-skip\n\nUse the `%s` marker to delimit it.\n' \
    "$START_MARKER"
}

# --- Probes ------------------------------------------------------------------

# Probe 1 (TypeScript): runs the real region-markers.ts module through tsx,
# never a reimplementation. Prints `kind` (and `/reason` when malformed).
ts_scan() {
  GAIA_FIXTURE_FILE="$1" GAIA_START_MARKER="$START_MARKER" GAIA_END_MARKER="$END_MARKER" \
    pnpm --silent -C "$CLI_DIR" exec tsx -e '
      import {scanRegion} from "./src/update/region-markers.js";
      import {readFileSync} from "node:fs";
      const source = readFileSync(process.env.GAIA_FIXTURE_FILE, "utf8");
      const scan = scanRegion(
        source,
        process.env.GAIA_START_MARKER,
        process.env.GAIA_END_MARKER
      );
      process.stdout.write(scan.kind + (scan.reason ? "/" + scan.reason : ""));
    '
}

# Probe 2 (writer): executes the real write-audit-remits.sh against the
# sandbox and classifies its outcome for the one member from what it actually
# did, never from a count computed here. $1 = sandbox dir.
classify_writer() {
  local dir="$1" out status
  out="$(bash "$WRITER" --root "$dir" --config "$dir/.gaia/audit-ci.yml" 2>&1)"
  status=$?
  if [ "$status" -ne 0 ]; then
    printf 'fail'
    return 0
  fi
  if grep -qF 'region inserted' <<<"$out"; then
    printf 'insert'
    return 0
  fi
  printf 'replace'
}

# Probe 3 (check): executes the real verify-audit-roster.sh against the
# sandbox and reads off the region-shape finding it emitted for the member,
# never a count computed here. $1 = sandbox dir. The two `unreadable-
# machinery-list` findings are sandbox noise (no .claude/hooks/lib/
# audit-machinery.sh or .gaia/scripts/audit-machinery-complete.sh in a bare
# fixture root) and are not asserted on; only the region-shape label is.
classify_check() {
  local dir="$1" out
  out="$(bash "$CHECKER" --root "$dir" --config "$dir/.gaia/audit-ci.yml" 2>&1)" || true
  if grep -qF 'FAIL missing-remit-region' <<<"$out"; then
    printf 'REGIONMISSING'
    return 0
  fi
  if grep -qF 'FAIL duplicate-remit-region' <<<"$out"; then
    printf 'REGIONDUP'
    return 0
  fi
  if grep -qF 'FAIL unbalanced-remit-region' <<<"$out"; then
    printf 'REGIONUNBALANCED'
    return 0
  fi
  if grep -qF 'FAIL reversed-remit-region' <<<"$out"; then
    printf 'REGIONREVERSED'
    return 0
  fi
  printf 'REGIONOK'
}

# ---------------------------------------------------------------------------
# ok: one start, one end, in order, two bullet lines between.
# ---------------------------------------------------------------------------

@test "ok fixture: TypeScript region, writer replace, check REGIONOK" {
  local body ts_dir writer_dir check_dir
  body="$(fixture_ok)"
  ts_dir="$(make_sandbox ok-ts "$body")"
  writer_dir="$(make_sandbox ok-writer "$body")"
  check_dir="$(make_sandbox ok-check "$body")"

  run ts_scan "$ts_dir/.claude/agents/code-audit-fixture.md"
  [ "$status" -eq 0 ]
  [ "$output" = "region" ]

  run classify_writer "$writer_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "replace" ]

  run classify_check "$check_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "REGIONOK" ]
}

# ---------------------------------------------------------------------------
# absent: no markers. Not a failure for any of the three: it is the expected
# pre-region adopter state, before the region is ever generated.
# ---------------------------------------------------------------------------

@test "absent fixture: TypeScript absent, writer insert, check REGIONMISSING (not a failure)" {
  local body ts_dir writer_dir check_dir
  body="$(fixture_absent)"
  ts_dir="$(make_sandbox absent-ts "$body")"
  writer_dir="$(make_sandbox absent-writer "$body")"
  check_dir="$(make_sandbox absent-check "$body")"

  run ts_scan "$ts_dir/.claude/agents/code-audit-fixture.md"
  [ "$status" -eq 0 ]
  [ "$output" = "absent" ]

  # The writer's insert path succeeds (exit 0): a wholly absent region is its
  # normal case, not an error.
  run classify_writer "$writer_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "insert" ]

  # The check reports REGIONMISSING as a routine invariant finding (exit 1,
  # one finding block), never a usage error (exit 2) or a crash.
  run bash "$CHECKER" --root "$check_dir" --config "$check_dir/.gaia/audit-ci.yml"
  [ "$status" -eq 1 ]

  run classify_check "$check_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "REGIONMISSING" ]
}

# ---------------------------------------------------------------------------
# dup-start: two starts, one end.
# ---------------------------------------------------------------------------

@test "dup-start fixture: TypeScript duplicate-start, writer fail, check REGIONDUP" {
  local body ts_dir writer_dir check_dir
  body="$(fixture_dup_start)"
  ts_dir="$(make_sandbox dup-start-ts "$body")"
  writer_dir="$(make_sandbox dup-start-writer "$body")"
  check_dir="$(make_sandbox dup-start-check "$body")"

  run ts_scan "$ts_dir/.claude/agents/code-audit-fixture.md"
  [ "$status" -eq 0 ]
  [ "$output" = "malformed/duplicate-start" ]

  run classify_writer "$writer_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "fail" ]

  run classify_check "$check_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "REGIONDUP" ]
}

# ---------------------------------------------------------------------------
# unbalanced: one start, no end.
# ---------------------------------------------------------------------------

@test "unbalanced fixture: TypeScript unbalanced, writer fail, check REGIONUNBALANCED" {
  local body ts_dir writer_dir check_dir
  body="$(fixture_unbalanced)"
  ts_dir="$(make_sandbox unbalanced-ts "$body")"
  writer_dir="$(make_sandbox unbalanced-writer "$body")"
  check_dir="$(make_sandbox unbalanced-check "$body")"

  run ts_scan "$ts_dir/.claude/agents/code-audit-fixture.md"
  [ "$status" -eq 0 ]
  [ "$output" = "malformed/unbalanced" ]

  run classify_writer "$writer_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "fail" ]

  run classify_check "$check_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "REGIONUNBALANCED" ]
}

# ---------------------------------------------------------------------------
# substring: one line embedding the marker text inside longer prose, no real
# marker. All three see no region: the whole-line contract. A substring-
# matching implementation (marker-strip.ts's semantics) fails here.
# ---------------------------------------------------------------------------

@test "substring fixture: all three see no region (whole-line contract)" {
  local body ts_dir writer_dir check_dir
  body="$(fixture_substring)"
  ts_dir="$(make_sandbox substring-ts "$body")"
  writer_dir="$(make_sandbox substring-writer "$body")"
  check_dir="$(make_sandbox substring-check "$body")"

  run ts_scan "$ts_dir/.claude/agents/code-audit-fixture.md"
  [ "$status" -eq 0 ]
  [ "$output" = "absent" ]

  run classify_writer "$writer_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "insert" ]

  run classify_check "$check_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "REGIONMISSING" ]
}

# ---------------------------------------------------------------------------
# inverted: end line before start line.
#
# NOT a divergence. Both bash parsers already detect reversed marker order
# (write-audit-remits.sh's `reversed` check; verify-audit-roster.sh's
# start_line/end_line comparison, REGIONREVERSED) and refuse it exactly as
# the TypeScript parser does. All three implementations converge on treating
# an inverted pair as malformed; none judges by count alone.
# ---------------------------------------------------------------------------

@test "inverted fixture: all three reject the reversed pair (convergence, not divergence)" {
  local body ts_dir writer_dir check_dir before after
  body="$(fixture_inverted)"
  ts_dir="$(make_sandbox inverted-ts "$body")"
  writer_dir="$(make_sandbox inverted-writer "$body")"
  check_dir="$(make_sandbox inverted-check "$body")"

  run ts_scan "$ts_dir/.claude/agents/code-audit-fixture.md"
  [ "$status" -eq 0 ]
  [ "$output" = "malformed/inverted" ]

  before="$(cat "$writer_dir/.claude/agents/code-audit-fixture.md")"
  run classify_writer "$writer_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "fail" ]
  # The writer never deletes bytes outside a pair it can identify: a reversed
  # pair leaves the file byte-identical to before the run.
  after="$(cat "$writer_dir/.claude/agents/code-audit-fixture.md")"
  [ "$before" = "$after" ]

  run classify_check "$check_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "REGIONREVERSED" ]
}
