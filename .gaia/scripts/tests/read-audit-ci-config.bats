#!/usr/bin/env bats
# Tests for `.gaia/scripts/read-audit-ci-config.sh`.
#
# The reader emits the local audit knobs (`push_fixes`, `retrigger_workflows`)
# and answers `--resolve-author` for the callers that ask who audits a PR.
# Every audit is local, so the resolver always answers `local`, whatever the
# file holds and whatever the environment says.
#
# Each test runs the script in an isolated `git init`'d temp dir so the
# script's `git rev-parse --show-toplevel` resolves to that fixture
# (and not the GAIA repo root, which already ships the default config).

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIR/../read-audit-ci-config.sh"
  [ -x "$SCRIPT" ] || skip "read-audit-ci-config.sh not executable"

  # An inherited git environment overrides directory-based discovery, so an
  # ambient GIT_DIR or GIT_WORK_TREE makes the sandbox's `git rev-parse
  # --show-toplevel` resolve the host repo instead.
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_CEILING_DIRECTORIES

  # Per-test sandbox: a fresh git repo so `git rev-parse --show-toplevel`
  # resolves inside the fixture tree, not the host repo.
  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SANDBOX/.gaia"
  ( cd "$SANDBOX" && git init --quiet )

  # GITHUB_ACTIONS has no bearing on resolved_mode. Neutralize the ambient
  # value, since this suite runs in CI; the invariance test sets it
  # explicitly to prove the claim.
  unset GITHUB_ACTIONS PR_IS_FORK OVERRIDE_LABEL_PRESENT
}

# Run the script with cwd inside the sandbox so its
# `git rev-parse --show-toplevel` lookup hits the fixture.
run_in_sandbox() {
  ( cd "$SANDBOX" && "$SCRIPT" )
}

# Run the resolve path. Args are passed through to the script (e.g.
# `--resolve-author alice`). PATH is restricted to system bins so the
# host's real `gh` is never picked up; tests that want a `gh` stub install
# one under "$SANDBOX/bin" via stub_gh_* and pass STUB_PATH.
#
# Usage: resolve_in_sandbox [STUB_PATH] <script-args...>
resolve_in_sandbox() {
  local path="/usr/bin:/bin"
  if [ "$1" = "STUB_PATH" ]; then
    path="$SANDBOX/bin:/usr/bin:/bin"
    shift
  fi
  ( cd "$SANDBOX" && PATH="$path" "$SCRIPT" "$@" )
}

# stub_gh_confirms: install a fake `gh` that reports GAIA-Audit as a
# registered required check and a valid repo slug.
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

# stub_gh_ruleset_confirms: classic protection is unconfirmable (simulates a
# 404 on a ruleset-protected repo), but the ruleset endpoint
# (`rules/branches/<branch>`) reports GAIA-Audit as a required context.
stub_gh_ruleset_confirms() {
  mkdir -p "$SANDBOX/bin"
  cat > "$SANDBOX/bin/gh" <<'STUB'
#!/usr/bin/env bash
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
# endpoint reports a context set that does not include GAIA-Audit.
stub_gh_neither_confirms() {
  mkdir -p "$SANDBOX/bin"
  cat > "$SANDBOX/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  repo) echo "owner/repo" ;;
  api)
    case "$2" in
      */rules/branches/*) printf 'Tests\n' ;;
      *) exit 1 ;;
    esac
    ;;
esac
STUB
  chmod +x "$SANDBOX/bin/gh"
}

# write_config <yaml-body>
write_config() {
  printf '%s\n' "$1" > "$SANDBOX/.gaia/audit-ci.yml"
}

# Expected default block (deterministic order).
default_block() {
  printf 'push_fixes=true\n%s' "$(default_retrigger_block)"
}

# The retrigger_workflows default uses a multiline heredoc. Helper keeps the
# delimiter and default list in one place.
default_retrigger_block() {
  printf 'retrigger_workflows<<__GAIA_END__\nChromatic\nTests\n__GAIA_END__'
}

# --- 1. File missing, empty, or comments-only -> all defaults ----------------

@test "missing config file: all defaults emitted in order" {
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "$(default_block)" ]
}

@test "empty config file: all defaults" {
  : > "$SANDBOX/.gaia/audit-ci.yml"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "$(default_block)" ]
}

@test "comments-only config: all defaults" {
  write_config "# only comments here
# nothing else"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "$(default_block)" ]
}

@test "all keys present at defaults: output equals defaults" {
  write_config "push_fixes: true
retrigger_workflows:
  - Chromatic
  - Tests"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "$(default_block)" ]
}

# --- 2. push_fixes booleans + aliases ---------------------------------------

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

# --- 3. Unrecognized and legacy keys ignored --------------------------------

@test "unrecognized key in file: ignored, output unchanged" {
  write_config "futureknob: experimental
push_fixes: true"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "$(default_block)" ]
}

@test "legacy keys from an older file: ignored silently, output unchanged" {
  write_config "gate_label: ready-for-review
budget_seconds: 60
max_turns: 5
default_mode: ci
override_label: run-audit
audit_authors: \"bob=ci\"
push_fixes: true"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "$(default_block)" ]
}

@test "commented-out key falls through to default" {
  write_config "# push_fixes: false"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "$(default_block)" ]
}

@test "inline trailing comment stripped from value" {
  write_config "push_fixes: false   # advisory only"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"push_fixes=false"$'\n'* ]]
}

@test "stdout ends with a newline byte" {
  out="$BATS_TEST_TMPDIR/out"
  ( cd "$SANDBOX" && "$SCRIPT" ) > "$out"
  last_byte="$(tail -c 1 "$out" | od -An -c | tr -d ' ')"
  [ "$last_byte" = "\\n" ]
}

@test "output is push_fixes then the retrigger heredoc, regardless of file order" {
  write_config "retrigger_workflows:
  - Lint
push_fixes: false"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="push_fixes=false
retrigger_workflows<<__GAIA_END__
Lint
__GAIA_END__"
  [ "$output" = "$expected" ]
}

# --- 4. retrigger_workflows --------------------------------------------------

@test "retrigger_workflows block-style: items preserved in order, multi-word names allowed" {
  write_config "retrigger_workflows:
  - Chromatic
  - Vitest and Playwright
  - My Custom Lint"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  expected="push_fixes=true
retrigger_workflows<<__GAIA_END__
Chromatic
Vitest and Playwright
My Custom Lint
__GAIA_END__"
  [ "$output" = "$expected" ]
}

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

@test "retrigger_workflows: double-quoted and single-quoted entries unquoted" {
  write_config "retrigger_workflows:
  - \"Run Chromatic\"
  - 'Run Tests'"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"retrigger_workflows<<__GAIA_END__"$'\n'"Run Chromatic"$'\n'"Run Tests"$'\n'"__GAIA_END__"* ]]
}

@test "retrigger_workflows: scalar (non-list) value accepted as single item" {
  write_config "retrigger_workflows: Chromatic"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"retrigger_workflows<<__GAIA_END__"$'\n'"Chromatic"$'\n'"__GAIA_END__"* ]]
}

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

@test "retrigger_workflows: trailing # comments stripped from items" {
  write_config "retrigger_workflows:
  - Chromatic    # run on PRs only
  - Tests        # vitest + playwright"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"retrigger_workflows<<__GAIA_END__"$'\n'"Chromatic"$'\n'"Tests"$'\n'"__GAIA_END__"* ]]
}

@test "retrigger_workflows: blank lines and comment lines between items tolerated" {
  write_config "retrigger_workflows:
  - Chromatic

  # interlude
  - Tests"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"retrigger_workflows<<__GAIA_END__"$'\n'"Chromatic"$'\n'"Tests"$'\n'"__GAIA_END__"* ]]
}

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

# --- 5. Usage errors ---------------------------------------------------------

@test "unrecognized argument exits 2 with a usage error" {
  run resolve_in_sandbox --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unrecognized argument '--bogus'"* ]]
}

@test "--resolve-author without a login exits 2" {
  run resolve_in_sandbox --resolve-author
  [ "$status" -eq 2 ]
  [[ "$output" == *"--resolve-author requires a <login> argument"* ]]
}

# --- 6. --resolve-author always answers local (UAT-004, resolver half) -------

@test "resolve-author: no config file resolves local, should_run false, push_fixes true" {
  run resolve_in_sandbox --resolve-author anyone
  [ "$status" -eq 0 ]
  grep -qxF -- "resolved_mode=local" <<<"$output" || return 1
  grep -qxF -- "should_run=false" <<<"$output" || return 1
  grep -qxF -- "push_fixes=true" <<<"$output" || return 1
}

@test "resolve-author: output is exactly resolved_mode, should_run, push_fixes (no legacy keys echoed)" {
  write_config "push_fixes: false"
  run resolve_in_sandbox --resolve-author anyone
  [ "$status" -eq 0 ]
  stdout_only="$( cd "$SANDBOX" && PATH="/usr/bin:/bin" "$SCRIPT" --resolve-author anyone 2>/dev/null )"
  [ "$stdout_only" = "resolved_mode=local
should_run=false
push_fixes=false" ]
}

@test "resolve-author: fixture A, stale workflow file and no default_mode, resolves local even with fork and override env" {
  mkdir -p "$SANDBOX/.github/workflows"
  : > "$SANDBOX/.github/workflows/code-review-audit.yml"
  write_config "push_fixes: true"
  run env PR_IS_FORK=true OVERRIDE_LABEL_PRESENT=true bash -c '
    cd "$1" && PATH="/usr/bin:/bin" "$2" --resolve-author bob
  ' _ "$SANDBOX" "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qxF -- "resolved_mode=local" <<<"$output" || return 1
  grep -qxF -- "should_run=false" <<<"$output" || return 1
}

@test "resolve-author: fixture B, legacy default_mode ci plus author pin plus override label, resolves local even with fork and override env" {
  write_config "default_mode: ci
audit_authors: \"bob=ci\"
override_label: run-audit
push_fixes: true"
  run env PR_IS_FORK=true OVERRIDE_LABEL_PRESENT=true bash -c '
    cd "$1" && PATH="/usr/bin:/bin" "$2" --resolve-author bob
  ' _ "$SANDBOX" "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qxF -- "resolved_mode=local" <<<"$output" || return 1
  grep -qxF -- "should_run=false" <<<"$output" || return 1
}

@test "resolve-author: legacy keys and a stale workflow file raise no warning" {
  mkdir -p "$SANDBOX/.github/workflows"
  : > "$SANDBOX/.github/workflows/code-review-audit.yml"
  write_config "default_mode: remote
audit_authors: \"bob= =ci bare\"
push_fixes: true"
  stderr_only="$( cd "$SANDBOX" && PATH="/usr/bin:/bin" "$SCRIPT" --resolve-author bob 2>&1 >/dev/null )"
  # Only the advisory registration warning may appear; nothing about the
  # legacy keys.
  [[ "$stderr_only" != *"audit_authors"* ]]
  [[ "$stderr_only" != *"default_mode"* ]]
  [[ "$stderr_only" != *"coercing"* ]]
}

@test "resolve-author: push_fixes still parsed on the resolve path, so the parser was not short-circuited" {
  write_config "push_fixes: false"
  run resolve_in_sandbox --resolve-author anyone
  [ "$status" -eq 0 ]
  grep -qxF -- "push_fixes=false" <<<"$output" || return 1
  write_config "push_fixes: maybe"
  run resolve_in_sandbox --resolve-author anyone
  [ "$status" -eq 0 ]
  grep -qxF -- "push_fixes=true" <<<"$output" || return 1
  grep -qF -- "not a recognized boolean" <<<"$output" || return 1
}

@test "resolve-author: resolved_mode is the same whether GITHUB_ACTIONS is set or unset" {
  write_config "push_fixes: true"

  run env GITHUB_ACTIONS=true bash -c '
    cd "$1" && PATH="/usr/bin:/bin" "$2" --resolve-author stevensacks
  ' _ "$SANDBOX" "$SCRIPT"
  [ "$status" -eq 0 ]
  mode_actions="$(printf '%s\n' "$output" | grep '^resolved_mode=')"

  run env -u GITHUB_ACTIONS bash -c '
    cd "$1" && PATH="/usr/bin:/bin" "$2" --resolve-author stevensacks
  ' _ "$SANDBOX" "$SCRIPT"
  [ "$status" -eq 0 ]
  mode_no_actions="$(printf '%s\n' "$output" | grep '^resolved_mode=')"

  [ "$mode_actions" = "$mode_no_actions" ]
  [ "$mode_actions" = "resolved_mode=local" ]
}

@test "resolve-author: resolved_mode is independent of which files changed" {
  stub_gh_confirms
  write_config "push_fixes: true"

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

# --- 7. Required-check confirmation is advisory only -------------------------

@test "resolve-author: GAIA-Audit unconfirmable stays local, warns advisory-only" {
  # No gh on PATH (system bins only) → required_check_confirmed returns
  # non-zero. Confirmation warns naming both protection models it tried, and
  # never changes resolved_mode or should_run.
  run resolve_in_sandbox --resolve-author anyone
  [ "$status" -eq 0 ]
  grep -qF -- "resolved_mode=local" <<<"$output" || return 1
  grep -qF -- "should_run=false" <<<"$output" || return 1
  grep -qF -- "GAIA-Audit registration not confirmed" <<<"$output" || return 1
  grep -qF -- "classic branch protection" <<<"$output" || return 1
  grep -qF -- "repository ruleset" <<<"$output" || return 1
  grep -qF -- "fail-closed" <<<"$output" && return 1
  return 0
}

@test "resolve-author: classic branch protection confirming GAIA-Audit prints no warning" {
  stub_gh_confirms
  run resolve_in_sandbox STUB_PATH --resolve-author anyone
  [ "$status" -eq 0 ]
  grep -qF -- "resolved_mode=local" <<<"$output" || return 1
  grep -qF -- "registration not confirmed" <<<"$output" && return 1
  return 0
}

@test "resolve-author: classic protection unconfirmable, ruleset confirms GAIA-Audit prints no warning" {
  stub_gh_ruleset_confirms
  run resolve_in_sandbox STUB_PATH --resolve-author anyone
  [ "$status" -eq 0 ]
  grep -qF -- "resolved_mode=local" <<<"$output" || return 1
  grep -qF -- "registration not confirmed" <<<"$output" && return 1
  return 0
}

@test "resolve-author: neither classic nor ruleset confirms GAIA-Audit still stays local, warns advisory-only" {
  stub_gh_neither_confirms
  run resolve_in_sandbox STUB_PATH --resolve-author anyone
  [ "$status" -eq 0 ]
  grep -qF -- "resolved_mode=local" <<<"$output" || return 1
  grep -qF -- "GAIA-Audit registration not confirmed" <<<"$output" || return 1
  grep -qF -- "fail-closed" <<<"$output" && return 1
  return 0
}
