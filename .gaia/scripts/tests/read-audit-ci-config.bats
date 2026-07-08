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

  # The resolver skips the required-check confirmation under GitHub Actions,
  # so neutralize the ambient value: this suite runs IN CI, and every test
  # below asserts the local merge-path behavior (confirmation active) unless it
  # sets GITHUB_ACTIONS itself. The CI-context test sets it explicitly
  # per-invocation.
  unset GITHUB_ACTIONS
}

# Run the script with cwd inside the sandbox so its
# `git rev-parse --show-toplevel` lookup hits the fixture.
run_in_sandbox() {
  ( cd "$SANDBOX" && "$SCRIPT" )
}

# Run the resolve path. Args are passed through to the script (e.g.
# `--resolve-author alice`). PATH is restricted to system bins so the
# host's real `gh` is never picked up; tests that want a `gh` stub install
# one under "$SANDBOX/bin" via stub_gh_* and pass STUB_PATH=1.
#
# Usage: resolve_in_sandbox [STUB_PATH] -- <script-args...>
resolve_in_sandbox() {
  local path="/usr/bin:/bin"
  if [ "$1" = "STUB_PATH" ]; then
    path="$SANDBOX/bin:/usr/bin:/bin"
    shift
  fi
  ( cd "$SANDBOX" && PATH="$path" "$SCRIPT" "$@" )
}

# stub_gh_confirms: install a fake `gh` that reports GAIA-Audit as a
# registered required check and a valid repo slug. Lets a `local`
# resolution survive verification instead of failing closed.
stub_gh_confirms() {
  mkdir -p "$SANDBOX/bin"
  cat > "$SANDBOX/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ -n "${GH_LOG:-}" ] && echo "gh $*" >> "$GH_LOG"
case "$1" in
  repo) echo "owner/repo" ;;
  api) printf 'GAIA-Audit\n' ;;
esac
STUB
  chmod +x "$SANDBOX/bin/gh"
}

# stub_gh_recording: install a fake `gh` that only records its invocations
# (used to prove the ci path never calls the branch-protection API). Returns
# no contexts, so any `local` resolution would fail closed.
stub_gh_recording() {
  mkdir -p "$SANDBOX/bin"
  cat > "$SANDBOX/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ -n "${GH_LOG:-}" ] && echo "gh $*" >> "$GH_LOG"
case "$1" in
  repo) echo "owner/repo" ;;
esac
STUB
  chmod +x "$SANDBOX/bin/gh"
}

# write_config <yaml-body>
write_config() {
  printf '%s\n' "$1" > "$SANDBOX/.gaia/audit-ci.yml"
}

# Expected default block (one big string, deterministic order). The three
# per-author keys (default_mode/override_label/audit_authors) emit between
# push_fixes and the retrigger heredoc, matching the script's emit order.
default_block() {
  printf 'gate_label=\nbudget_seconds=1800\nmax_turns=30\npush_fixes=true\n%s\n%s' \
    "$(default_new_keys_block)" "$(default_retrigger_block)"
}

# The per-author key defaults, in emit order. Kept in one place so every
# exact-match assertion stays in sync with the script's contract.
default_new_keys_block() {
  printf 'default_mode=ci\noverride_label=run-audit\naudit_authors='
}

# The retrigger_workflows default uses GitHub Actions multiline-output
# heredoc syntax. Helper keeps the delimiter and default list in one place.
default_retrigger_block() {
  printf 'retrigger_workflows<<__GAIA_END__\nChromatic\nTests\n__GAIA_END__'
}

# --- 1. File missing → all defaults -----------------------------------------

@test "missing config file: all defaults emitted in order" {
  # No write_config; file does not exist.
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
  [[ "$output" == *"push_fixes=true"$'\n'* ]]
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
  # The integer validator only accepts ^[0-9]+$; `-1` contains a
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
$(default_new_keys_block)
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
$(default_new_keys_block)
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
$(default_new_keys_block)
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
$(default_new_keys_block)
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
$(default_new_keys_block)
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

@test "retrigger_workflows flow-style: multi-word names preserved" {
  write_config "retrigger_workflows: [Chromatic, Vitest and Playwright]"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"retrigger_workflows<<__GAIA_END__"$'\n'"Chromatic"$'\n'"Vitest and Playwright"$'\n'"__GAIA_END__"* ]]
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

# ===========================================================================
# Per-author audit-mode resolver: new keys, --resolve-author, precedence,
# normalization, required-check verification (fail-closed).
# ===========================================================================

# --- 24. New keys: absent → defaults in the emit-all path -------------------

@test "new keys: absent default_mode/override_label/audit_authors emit ci/run-audit/empty" {
  # No config file at all; the three new keys take their defaults.
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"default_mode=ci"$'\n'* ]]
  [[ "$output" == *"override_label=run-audit"$'\n'* ]]
  [[ "$output" == *"audit_authors="$'\n'* ]]
}

# --- 25. default_mode: explicit + off-coercion ------------------------------

@test "default_mode: explicit local emitted verbatim" {
  write_config "default_mode: local"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"default_mode=local"$'\n'* ]]
}

@test "default_mode: off coerces to ci when audit workflow present (warns)" {
  mkdir -p "$SANDBOX/.github/workflows"
  : > "$SANDBOX/.github/workflows/code-review-audit.yml"
  write_config "default_mode: off"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"default_mode=ci"$'\n'* ]]
  [[ "$output" == *"default_mode=off is not a valid audit mode"* ]]
  [[ "$output" == *"coercing to ci"* ]]
}

@test "default_mode: off coerces to local when audit workflow absent (warns)" {
  # No .github/workflows/code-review-audit.yml in the sandbox.
  write_config "default_mode: off"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"default_mode=local"$'\n'* ]]
  [[ "$output" == *"default_mode=off is not a valid audit mode"* ]]
  [[ "$output" == *"coercing to local"* ]]
}

# --- 26. Precedence rule 1: override label present --------------------------

@test "resolve-author: override present forces ci should_run true" {
  write_config "default_mode: local
audit_authors: \"alice=local\""
  run env OVERRIDE_LABEL_PRESENT=true bash -c '
    cd "$1" && PATH="/usr/bin:/bin" "$2" --resolve-author alice
  ' _ "$SANDBOX" "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolved_mode=ci"$'\n'* ]]
  [[ "$output" == *"should_run=true"$'\n'* ]]
}

# --- 27. Precedence rule 2: audit_authors hit wins over default_mode --------

@test "resolve-author: audit_authors hit wins over default_mode" {
  # alice resolves local (and survives the required-check stub) even though
  # default_mode is ci.
  stub_gh_confirms
  write_config "default_mode: ci
audit_authors: \"alice=local priya=ci\""
  run resolve_in_sandbox STUB_PATH --resolve-author alice
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolved_mode=local"$'\n'* ]]
  [[ "$output" == *"should_run=false"$'\n'* ]]
}

# --- 28. Precedence rule 3: fall back to default_mode ----------------------

@test "resolve-author: falls back to default_mode when author absent" {
  write_config "default_mode: ci
audit_authors: \"alice=local\""
  run resolve_in_sandbox --resolve-author stranger
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolved_mode=ci"$'\n'* ]]
  [[ "$output" == *"should_run=true"$'\n'* ]]
}

# --- 29. Duplicate logins: first match wins (no deadlock) ------------------

@test "resolve-author: duplicate logins, first match wins (no deadlock)" {
  # bob=local appears first; the scan must stop there (local), not bob=ci.
  stub_gh_confirms
  write_config "audit_authors: \"bob=local bob=ci\""
  run resolve_in_sandbox STUB_PATH --resolve-author bob
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolved_mode=local"$'\n'* ]]
}

# --- 30. Login comparison is case-insensitive ------------------------------

@test "resolve-author: login comparison is case-insensitive" {
  # StevenSacks (display casing) matches stevensacks=local. Use the
  # confirming stub so the match resolves to local rather than failing closed
  # (a fall-through to default_mode=ci would not prove the match).
  stub_gh_confirms
  write_config "default_mode: ci
audit_authors: \"stevensacks=local\""
  run resolve_in_sandbox STUB_PATH --resolve-author StevenSacks
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolved_mode=local"$'\n'* ]]
}

# --- 31. Mode token normalization (case-fold + trim) -----------------------

@test "resolve-author: mode token CI / trailing space normalized to ci" {
  write_config "audit_authors: \"carol=CI \""
  run resolve_in_sandbox --resolve-author carol
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolved_mode=ci"$'\n'* ]]
  # ci resolution never warns about coercion.
  [[ "$output" != *"recognized audit mode"* ]]
}

# --- 32. Unknown mode coerced by workflow presence (warns) -----------------

@test "resolve-author: unknown mode remote coerced to valid non-off (warns)" {
  # Audit workflow present → remote coerces to ci (a valid non-off mode).
  mkdir -p "$SANDBOX/.github/workflows"
  : > "$SANDBOX/.github/workflows/code-review-audit.yml"
  write_config "audit_authors: \"dave=remote\""
  run resolve_in_sandbox --resolve-author dave
  [ "$status" -eq 0 ]
  [[ "$output" == *"is not a recognized audit mode"* ]]
  [[ "$output" == *"resolved_mode=ci"$'\n'* ]]
}

# --- 33. Malformed pairs skipped, valid one still resolves -----------------

@test "resolve-author: malformed pairs (bob= / =ci / bare) skipped with warning, not crash" {
  write_config "audit_authors: \"bob= =ci barebob eve=ci\""
  run resolve_in_sandbox --resolve-author eve
  [ "$status" -eq 0 ]
  [[ "$output" == *"is malformed (empty mode)"* ]]
  [[ "$output" == *"is malformed (empty login)"* ]]
  [[ "$output" == *"is malformed (no '='"* ]]
  [[ "$output" == *"resolved_mode=ci"$'\n'* ]]
  [[ "$output" == *"should_run=true"$'\n'* ]]
}

# --- 34. Required-check fail-closed (BLOCKER) ------------------------------

@test "resolve-author: local mode forces ci when GAIA-Audit required check unconfirmable (fail-closed)" {
  # No gh on PATH (system bins only) → required_check_confirmed returns
  # non-zero → a would-be local resolution is forced to ci.
  write_config "default_mode: local"
  run resolve_in_sandbox --resolve-author anyone
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolved_mode=ci"$'\n'* ]]
  [[ "$output" == *"should_run=true"$'\n'* ]]
  [[ "$output" == *"GAIA-Audit required check not confirmed"* ]]
  [[ "$output" == *"forcing ci (fail-closed)"* ]]
}

# --- 34b. CI context: local honored without the branch-protection re-check --

@test "resolve-author: CI context honors local without the required-check re-check" {
  # Under GitHub Actions the confirmation's branch-protection read is
  # un-runnable (GITHUB_TOKEN lacks admin; ruleset repos 404), so it is
  # skipped and the resolved local mode is honored -- otherwise every
  # local-mode author eats a redundant CI audit that duplicates the local run.
  # Mirrors convene's config (stevensacks pinned local). A recording stub
  # proves the branch-protection API is never hit.
  stub_gh_recording
  GH_LOG="$SANDBOX/gh.log"
  : > "$GH_LOG"
  write_config "default_mode: local
audit_authors: \"stevensacks=local\""
  run env GITHUB_ACTIONS=true GH_LOG="$GH_LOG" bash -c '
    cd "$1" && PATH="$1/bin:/usr/bin:/bin" "$2" --resolve-author stevensacks
  ' _ "$SANDBOX" "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolved_mode=local"$'\n'* ]]
  [[ "$output" == *"should_run=false"$'\n'* ]]
  [[ "$output" != *"fail-closed"* ]]
  [[ "$output" == *"CI context"* ]]
  # The branch-protection API was never called.
  run grep -F 'api repos/' "$GH_LOG"
  [ "$status" -ne 0 ]
}

# --- 35. ci resolution does not invoke branch-protection API ---------------

@test "resolve-author: ci resolution does not invoke branch-protection API" {
  # A recording gh stub logs every call. A ci resolution must never reach
  # the branch-protection API (no api call logged), and must not emit a
  # fail-closed warning (that path is local-only).
  stub_gh_recording
  GH_LOG="$SANDBOX/gh.log"
  : > "$GH_LOG"
  write_config "default_mode: ci"
  run env GH_LOG="$GH_LOG" bash -c '
    cd "$1" && PATH="$1/bin:/usr/bin:/bin" "$2" --resolve-author anyone
  ' _ "$SANDBOX" "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolved_mode=ci"$'\n'* ]]
  [[ "$output" != *"fail-closed"* ]]
  # No branch-protection API call was recorded.
  run grep -F 'api repos/' "$GH_LOG"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# required_check_confirmed: classic branch protection + ruleset fallback
# (UAT-007/008). Classic protection is unchanged; the ruleset branch is new
# and is only consulted when classic protection does not confirm.
# ===========================================================================

# stub_gh_ruleset_confirms: classic protection is unconfirmable (simulates a
# 404 on a ruleset-protected repo -- empty stdout, non-zero exit), but the
# ruleset endpoint (`rules/branches/<branch>`) reports GAIA-Audit as a
# required_status_checks context. Proves the fallback path (UAT-007).
stub_gh_ruleset_confirms() {
  mkdir -p "$SANDBOX/bin"
  cat > "$SANDBOX/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ -n "${GH_LOG:-}" ] && echo "gh $*" >> "$GH_LOG"
case "$1" in
  repo) echo "owner/repo" ;;
  api)
    case "$2" in
      */rules/branches/*) printf 'GAIA-Audit\n' ;;
      *) exit 1 ;;
    esac
    ;;
esac
STUB
  chmod +x "$SANDBOX/bin/gh"
}

# stub_gh_neither_confirms: classic protection unconfirmable AND the ruleset
# endpoint reports a required_status_checks context set that does not
# include GAIA-Audit (mirrors a real ruleset with sibling contexts but no
# GAIA-Audit registration yet).
stub_gh_neither_confirms() {
  mkdir -p "$SANDBOX/bin"
  cat > "$SANDBOX/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ -n "${GH_LOG:-}" ] && echo "gh $*" >> "$GH_LOG"
case "$1" in
  repo) echo "owner/repo" ;;
  api)
    case "$2" in
      */rules/branches/*) printf 'code-review-audit\n' ;;
      *) exit 1 ;;
    esac
    ;;
esac
STUB
  chmod +x "$SANDBOX/bin/gh"
}

# --- 43. Classic protection confirms GAIA-Audit ------------------------------

@test "resolve-author: classic branch protection confirming GAIA-Audit honors local" {
  stub_gh_confirms
  write_config "default_mode: local"
  run resolve_in_sandbox STUB_PATH --resolve-author anyone
  [ "$status" -eq 0 ]
  grep -qF -- "fail-closed" <<<"$output" && return 1
  grep -qF -- "resolved_mode=local" <<<"$output"
}

# --- 44. Classic unconfirmable, ruleset confirms GAIA-Audit (UAT-007) -------

@test "resolve-author: classic protection unconfirmable, ruleset confirms GAIA-Audit honors local" {
  stub_gh_ruleset_confirms
  write_config "default_mode: local"
  run resolve_in_sandbox STUB_PATH --resolve-author anyone
  [ "$status" -eq 0 ]
  grep -qF -- "fail-closed" <<<"$output" && return 1
  grep -qF -- "resolved_mode=local" <<<"$output"
}

# --- 45. Neither model confirms GAIA-Audit -> fail-closed to ci -------------

@test "resolve-author: neither classic nor ruleset confirms GAIA-Audit forces ci (fail-closed)" {
  stub_gh_neither_confirms
  write_config "default_mode: local"
  run resolve_in_sandbox STUB_PATH --resolve-author anyone
  [ "$status" -eq 0 ]
  grep -qF -- "resolved_mode=ci" <<<"$output" || return 1
  grep -qF -- "GAIA-Audit required check not confirmed" <<<"$output" || return 1
  grep -qF -- "forcing ci (fail-closed)" <<<"$output"
}

# --- 46. Team-wide mode invariance: resolved_mode ignores dispatch (UAT-003,
#          AUDIT COV-005) -----------------------------------------------------

@test "resolve-author: resolved_mode is independent of which files changed / auditors dispatched (team-wide mode)" {
  # Two repo states with entirely different changed surfaces (a frontend file
  # vs a maintainer-shell file) resolve the SAME author to the SAME mode. This
  # file's mode resolver reads only audit_authors/default_mode + the login --
  # it has no diff/dispatch awareness at all. resolve-audit-members.sh (the
  # dispatch resolver) is a fully separate script/contract; mode is
  # team-wide, never per-member.
  stub_gh_confirms
  write_config "default_mode: ci
audit_authors: \"alice=local\""

  mkdir -p "$SANDBOX/app"
  : > "$SANDBOX/app/Widget.tsx"
  run resolve_in_sandbox STUB_PATH --resolve-author alice
  [ "$status" -eq 0 ]
  mode_a="$(printf '%s\n' "$output" | grep '^resolved_mode=')"

  rm -f "$SANDBOX/app/Widget.tsx"
  mkdir -p "$SANDBOX/.gaia/scripts"
  : > "$SANDBOX/.gaia/scripts/some-other-script.sh"
  run resolve_in_sandbox STUB_PATH --resolve-author alice
  [ "$status" -eq 0 ]
  mode_b="$(printf '%s\n' "$output" | grep '^resolved_mode=')"

  [ "$mode_a" = "$mode_b" ]
  [ "$mode_a" = "resolved_mode=local" ]
}

# ===========================================================================
# Write-side round-trip: prove the reader parses exactly what the setup
# prompts write (default_mode/override_label via /setup-gaia; audit_authors
# via /setup-gaia through the append-audit-author.sh helper).
# ===========================================================================

# Install the append helper alongside the reader inside the sandbox's
# `.gaia/scripts/`, so the helper's sibling-script lookup finds the reader and
# its `git rev-parse` resolves the fixture's audit-ci.yml. Returns the helper
# path on stdout.
install_append_helper() {
  mkdir -p "$SANDBOX/.gaia/scripts"
  cp "$THIS_DIR/../read-audit-ci-config.sh" "$SANDBOX/.gaia/scripts/read-audit-ci-config.sh"
  cp "$THIS_DIR/../append-audit-author.sh" "$SANDBOX/.gaia/scripts/append-audit-author.sh"
  chmod +x "$SANDBOX/.gaia/scripts/read-audit-ci-config.sh" "$SANDBOX/.gaia/scripts/append-audit-author.sh"
  printf '%s\n' "$SANDBOX/.gaia/scripts/append-audit-author.sh"
}

# Run the append helper from inside the sandbox so its config-path lookup
# hits the fixture tree. Args pass through (e.g. `stevensacks local`).
append_in_sandbox() {
  ( cd "$SANDBOX" && "$SANDBOX/.gaia/scripts/append-audit-author.sh" "$@" )
}

# --- 36. audit_authors round-trip: two-developer string resolves each login --

@test "audit_authors append: two-developer string resolves each login" {
  # The append helper writes the exact format the resolver consumes. Append
  # two developers, then resolve each. stevensacks is local (survives the
  # required-check stub), priya is ci.
  install_append_helper >/dev/null
  stub_gh_confirms
  append_in_sandbox stevensacks local
  append_in_sandbox priya ci

  # The written value is the canonical space-separated pair string.
  [ "$(cat "$SANDBOX/.gaia/audit-ci.yml")" = 'audit_authors: "stevensacks=local priya=ci"' ]

  run resolve_in_sandbox STUB_PATH --resolve-author stevensacks
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolved_mode=local"$'\n'* ]]

  run resolve_in_sandbox STUB_PATH --resolve-author priya
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolved_mode=ci"$'\n'* ]]
}

# --- 37. default_mode local + override_label run-audit round-trip -----------

@test "default_mode local + override_label run-audit round-trip" {
  # /setup-gaia's team-policy prompt writes both keys; the argument-less
  # emit must read them back verbatim.
  write_config "default_mode: local
override_label: run-audit"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"default_mode=local"$'\n'* ]]
  [[ "$output" == *"override_label=run-audit"$'\n'* ]]
}

# --- 38. Append preserves existing entries (no clobber) ---------------------

@test "audit_authors append preserves existing entries" {
  # A developer appending their pair must not drop a teammate's entry.
  install_append_helper >/dev/null
  append_in_sandbox alice ci
  run append_in_sandbox bob local
  [ "$status" -eq 0 ]
  [ "$output" = "alice=ci bob=local" ]
  [ "$(cat "$SANDBOX/.gaia/audit-ci.yml")" = 'audit_authors: "alice=ci bob=local"' ]
}

# --- 39. Append preserves sibling keys when the file is populated ------------

@test "audit_authors append preserves sibling keys in a populated file" {
  # The team-policy keys and other knobs already present must survive the
  # in-place rewrite of the audit_authors line.
  install_append_helper >/dev/null
  cat > "$SANDBOX/.gaia/audit-ci.yml" <<'YAML'
gate_label: null
default_mode: local
override_label: run-audit
audit_authors: "alice=ci"
push_fixes: true
YAML
  run append_in_sandbox bob local
  [ "$status" -eq 0 ]
  [ "$output" = "alice=ci bob=local" ]
  # Sibling keys untouched; audit_authors rewritten in place.
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"default_mode=local"$'\n'* ]]
  [[ "$output" == *"override_label=run-audit"$'\n'* ]]
  [[ "$output" == *"push_fixes=true"$'\n'* ]]
  [[ "$output" == *"audit_authors=alice=ci bob=local"$'\n'* ]]
}

# --- 40. Append replaces a developer's own prior entry in place -------------

@test "audit_authors append replaces a re-running developer's own entry" {
  # A developer who re-runs /setup-gaia flips their own mode
  # rather than stacking a second pair; teammates' entries are preserved.
  install_append_helper >/dev/null
  append_in_sandbox stevensacks local
  append_in_sandbox priya ci
  run append_in_sandbox stevensacks ci
  [ "$status" -eq 0 ]
  # Own prior pair dropped, re-appended at the end; priya preserved.
  [ "$output" = "priya=ci stevensacks=ci" ]
}

# --- 41. Append usage error on missing arguments ---------------------------

@test "audit_authors append: missing arguments exit 2 with usage error" {
  install_append_helper >/dev/null
  run append_in_sandbox stevensacks
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: append-audit-author.sh <login> <mode>"* ]]
}

# --- 42. noglob guard: a glob char in audit_authors is not pathname-expanded -

@test "resolve-author: a glob char in audit_authors is not pathname-expanded" {
  # A would-be glob match sits in the resolver's cwd. Without the set -f guard,
  # `*=local` would expand to this filename and fabricate a realdev=local entry.
  : > "$SANDBOX/realdev=local"
  stub_gh_confirms
  write_config "default_mode: ci
audit_authors: \"*=local\""
  # With the guard the literal entry is login '*', which never matches realdev,
  # so realdev falls through to default_mode=ci rather than the glob-fabricated local.
  run resolve_in_sandbox STUB_PATH --resolve-author realdev
  [ "$status" -eq 0 ]
  [[ "$output" == *"resolved_mode=ci"$'\n'* ]]
}

@test "audit_authors append: a glob char in the existing value is not pathname-expanded" {
  # The worst case: without the set -f guard the helper globs the existing value
  # against the cwd and writes a corrupted audit_authors string back to the file.
  install_append_helper >/dev/null
  : > "$SANDBOX/evil=ci"
  printf '%s\n' 'audit_authors: "*=ci"' > "$SANDBOX/.gaia/audit-ci.yml"
  run append_in_sandbox newdev local
  [ "$status" -eq 0 ]
  # The literal '*=ci' entry survives; the cwd filename never leaks in.
  written="$(cat "$SANDBOX/.gaia/audit-ci.yml")"
  [[ "$written" == *'*=ci'* ]]
  [[ "$written" != *'evil'* ]]
}
