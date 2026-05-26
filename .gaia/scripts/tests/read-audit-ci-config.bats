#!/usr/bin/env bats
# Tests for `.gaia/scripts/read-audit-ci-config.sh`.
#
# The reader is consumed by the code-review-audit CI workflow as its
# first step: stdout is piped into `>> $GITHUB_OUTPUT`. Acceptance
# criteria for the contract live in
# `.gaia/local/plans/code-review-audit-ci/task-config-knobs.md` and the
# README's "Adopter config knobs (frozen)" section.
#
# Each test runs the script in an isolated `git init`'d temp dir so the
# script's `git rev-parse --show-toplevel` resolves to that fixture
# (and not the GAIA repo root, which already ships the default config).

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIR/../read-audit-ci-config.sh"
  [ -x "$SCRIPT" ] || skip "read-audit-ci-config.sh not executable"

  # Per-test sandbox: a fresh git repo so `git rev-parse --show-toplevel`
  # resolves inside the fixture tree, not the host repo.
  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SANDBOX/.gaia"
  ( cd "$SANDBOX" && git init --quiet )
}

# Run the script with cwd inside the sandbox so its
# `git rev-parse --show-toplevel` lookup hits the fixture.
run_in_sandbox() {
  ( cd "$SANDBOX" && "$SCRIPT" )
}

# write_config <yaml-body>
write_config() {
  printf '%s\n' "$1" > "$SANDBOX/.gaia/audit-ci.yml"
}

# Expected default block (one big string, deterministic order).
default_block() {
  printf 'gate_label=\nbudget_seconds=1800\nmax_turns=30\npush_fixes=true\n%s' \
    "$(default_retrigger_block)"
}

# The retrigger_workflows default uses GitHub Actions multiline-output
# heredoc syntax. Helper keeps the delimiter and default list in one place.
default_retrigger_block() {
  printf 'retrigger_workflows<<__GAIA_END__\nChromatic\nTests\n__GAIA_END__'
}

# --- 1. File missing → all defaults -----------------------------------------

@test "missing config file: all defaults emitted in order" {
  # No write_config — file does not exist.
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "$(default_block)" ]
}

# --- 2. Empty file → all defaults --------------------------------------------

@test "empty config file: all defaults" {
  : > "$SANDBOX/.gaia/audit-ci.yml"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "$(default_block)" ]
}

# --- 3. Comments-only file → all defaults ------------------------------------

@test "comments-only config: all defaults" {
  write_config "# only comments here
# nothing else"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "$(default_block)" ]
}

# --- 4. Each key absent (one at a time) → that key's default ----------------

@test "all keys present at defaults: output equals defaults" {
  write_config "gate_label: null
budget_seconds: 1800
max_turns: 30
push_fixes: true"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "$(default_block)" ]
}

# --- 5. gate_label: null variants → empty -----------------------------------

@test "gate_label: null lowercase → empty" {
  write_config "gate_label: null"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"gate_label="$'\n'* ]]
}

@test "gate_label: NULL uppercase → empty" {
  write_config "gate_label: NULL"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"gate_label="$'\n'* ]]
}

@test "gate_label: ~ (YAML null tilde) → empty" {
  write_config "gate_label: ~"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"gate_label="$'\n'* ]]
}

# --- 6. gate_label as quoted / unquoted string ------------------------------

@test "gate_label: \"ready-for-review\" (double-quoted) → ready-for-review" {
  write_config 'gate_label: "ready-for-review"'
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"gate_label=ready-for-review"$'\n'* ]]
}

@test "gate_label: 'ready-for-review' (single-quoted) → ready-for-review" {
  write_config "gate_label: 'ready-for-review'"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"gate_label=ready-for-review"$'\n'* ]]
}

@test "gate_label: ready-for-review (unquoted) → ready-for-review" {
  write_config "gate_label: ready-for-review"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"gate_label=ready-for-review"$'\n'* ]]
}

# --- 7. push_fixes booleans + aliases ---------------------------------------

@test "push_fixes: false → push_fixes=false" {
  write_config "push_fixes: false"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"push_fixes=false"$'\n'* ]]
}

@test "push_fixes: yes → push_fixes=true (alias normalized)" {
  write_config "push_fixes: yes"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"push_fixes=true"$'\n'* ]]
}

@test "push_fixes: NO → push_fixes=false (alias + case-insensitive)" {
  write_config "push_fixes: NO"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"push_fixes=false"$'\n'* ]]
}

@test "push_fixes: 0 → push_fixes=false" {
  write_config "push_fixes: 0"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"push_fixes=false"$'\n'* ]]
}

@test "push_fixes: bogus → default true + stderr warning" {
  write_config "push_fixes: maybe"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"push_fixes=true" ]]
  [[ "$output" == *"not a recognized boolean"* ]]
}

# --- 8. integer validation ---------------------------------------------------

@test "budget_seconds: 60 → budget_seconds=60" {
  write_config "budget_seconds: 60"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"budget_seconds=60"$'\n'* ]]
}

@test "budget_seconds: notanumber → default 1800 + stderr warning" {
  write_config "budget_seconds: notanumber"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"budget_seconds=1800"$'\n'* ]]
  [[ "$output" == *"not a non-negative integer"* ]]
}

@test "max_turns: 5 → max_turns=5" {
  write_config "max_turns: 5"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"max_turns=5"$'\n'* ]]
}

@test "max_turns: -1 (negative) → default 30 + stderr warning" {
  # The integer validator only accepts ^[0-9]+$ — `-1` contains a
  # non-digit and therefore falls back. Locking the contract.
  write_config "max_turns: -1"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"max_turns=30"$'\n'* ]]
  [[ "$output" == *"not a non-negative integer"* ]]
}

# --- 9. Unrecognized key ignored --------------------------------------------

@test "unrecognized key in file: ignored, output unchanged" {
  write_config "futureknob: experimental
gate_label: null"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "$(default_block)" ]
}

# --- 10. Commented-out key falls through to default -------------------------

@test "commented-out key falls through to default" {
  write_config "# gate_label: ready-for-review
# push_fixes: false
budget_seconds: 60"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="gate_label=
budget_seconds=60
max_turns=30
push_fixes=true
$(default_retrigger_block)"
  [ "$output" = "$expected" ]
}

# --- 11. Inline trailing comments stripped from values ----------------------

@test "inline trailing comment stripped from value" {
  write_config "budget_seconds: 60   # one minute for fast tests"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"budget_seconds=60"$'\n'* ]]
}

# --- 12. Mixed override: some keys flipped, others fall through -------------

@test "mixed config: gate_label and max_turns set, others default" {
  write_config "# adopter tweaks
gate_label: ready-for-review
max_turns: 5
"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="gate_label=ready-for-review
budget_seconds=1800
max_turns=5
push_fixes=true
$(default_retrigger_block)"
  [ "$output" = "$expected" ]
}

# --- 13. File with comments + blanks + all four keys ------------------------

@test "fully populated file with comments and blank lines: all values pass through" {
  write_config "# header

gate_label: needs-review

# budget paragraph
budget_seconds: 600

max_turns: 10
push_fixes: false
"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="gate_label=needs-review
budget_seconds=600
max_turns=10
push_fixes=false
$(default_retrigger_block)"
  [ "$output" = "$expected" ]
}

# --- 14. Output ends with a newline (heredoc-friendly) ----------------------

@test "stdout ends with a newline byte" {
  out="$BATS_TEST_TMPDIR/out"
  ( cd "$SANDBOX" && "$SCRIPT" ) > "$out"
  last_byte="$(tail -c 1 "$out" | od -An -c | tr -d ' ')"
  [ "$last_byte" = "\\n" ]
}

# --- 15. Deterministic key order --------------------------------------------

@test "output order is gate_label, budget_seconds, max_turns, push_fixes regardless of file order" {
  write_config "push_fixes: false
max_turns: 5
budget_seconds: 60
gate_label: needs-review"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="gate_label=needs-review
budget_seconds=60
max_turns=5
push_fixes=false
$(default_retrigger_block)"
  [ "$output" = "$expected" ]
}

# --- 16. retrigger_workflows: block-style list parsed in order --------------

@test "retrigger_workflows block-style: items preserved in order, multi-word names allowed" {
  write_config "retrigger_workflows:
  - Chromatic
  - Vitest and Playwright
  - My Custom Lint"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="gate_label=
budget_seconds=1800
max_turns=30
push_fixes=true
retrigger_workflows<<__GAIA_END__
Chromatic
Vitest and Playwright
My Custom Lint
__GAIA_END__"
  [ "$output" = "$expected" ]
}

# --- 17. retrigger_workflows: flow-style list -------------------------------

@test "retrigger_workflows flow-style: [a, b, c] parsed and trimmed" {
  write_config "retrigger_workflows: [Chromatic, Tests, Lint]"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"retrigger_workflows<<__GAIA_END__"$'\n'"Chromatic"$'\n'"Tests"$'\n'"Lint"$'\n'"__GAIA_END__"* ]]
}

# --- 18. retrigger_workflows: quoted entries unquoted -----------------------

@test "retrigger_workflows: double-quoted and single-quoted entries unquoted" {
  write_config "retrigger_workflows:
  - \"Run Chromatic\"
  - 'Run Tests'"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"retrigger_workflows<<__GAIA_END__"$'\n'"Run Chromatic"$'\n'"Run Tests"$'\n'"__GAIA_END__"* ]]
}

# --- 19. retrigger_workflows: scalar accepted as single-item list -----------

@test "retrigger_workflows: scalar (non-list) value accepted as single item" {
  write_config "retrigger_workflows: Chromatic"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"retrigger_workflows<<__GAIA_END__"$'\n'"Chromatic"$'\n'"__GAIA_END__"* ]]
}

# --- 20. retrigger_workflows: null + empty fall back to default -------------

@test "retrigger_workflows: null with no items falls back to default" {
  write_config "retrigger_workflows: null"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"$(default_retrigger_block)"* ]]
}

@test "retrigger_workflows: empty value with no items falls back to default" {
  write_config "retrigger_workflows:"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"$(default_retrigger_block)"* ]]
}

# --- 21. retrigger_workflows: inline comments stripped from items -----------

@test "retrigger_workflows: trailing # comments stripped from items" {
  write_config "retrigger_workflows:
  - Chromatic    # run on PRs only
  - Tests        # vitest + playwright"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"retrigger_workflows<<__GAIA_END__"$'\n'"Chromatic"$'\n'"Tests"$'\n'"__GAIA_END__"* ]]
}

# --- 22. retrigger_workflows: blank lines + comments mid-list tolerated -----

@test "retrigger_workflows: blank lines and comment lines between items tolerated" {
  write_config "retrigger_workflows:
  - Chromatic

  # interlude
  - Tests"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"retrigger_workflows<<__GAIA_END__"$'\n'"Chromatic"$'\n'"Tests"$'\n'"__GAIA_END__"* ]]
}

# --- 23. retrigger_workflows: list ends at next top-level key ---------------

@test "retrigger_workflows: list terminates when next top-level key appears" {
  write_config "retrigger_workflows:
  - Chromatic
  - Tests
push_fixes: false"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"push_fixes=false"* ]]
  [[ "$output" == *"retrigger_workflows<<__GAIA_END__"$'\n'"Chromatic"$'\n'"Tests"$'\n'"__GAIA_END__"* ]]
}
