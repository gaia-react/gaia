#!/usr/bin/env bats
#
# Permanent guard that GAIA's Claude-on-GitHub-Actions automation layer stays
# removed (SPEC-091 UAT-001 and UAT-002).
#
#   UAT-002: no tracked file outside the allowlist names a removed token, and
#            every allowlist entry still matches a hit.
#   UAT-001: the committed CLI bundle rejects every removed verb with
#            `unknown_subcommand`, ships no workflow render templates, and the
#            PR-time bundle-freshness step is still wired.
#
# The matcher is one function over an explicit root and allowlist, so the real
# tree and the scratch trees that prove it can fail run the same code.

# bats file_tags=whole-tree

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  ALLOWLIST="$REPO_ROOT/.gaia/tests/fixtures/ci-automation-removed.allowlist"
  GAIA_BIN="$REPO_ROOT/.gaia/cli/gaia"
  TOKEN_PATTERN='gaia-ci|automation\.json|configure-automation|cron-decide|claude-code-action|wiki-drift-check|wiki-commit-nudge'
  FRESHNESS_STEP='run: bash .gaia/scripts/verify-cli-bundle-fresh.sh'
}

# Allowlist lines with comments and blanks dropped.
allowlist_entries() {
  grep -vE '^[[:space:]]*(#|$)' "$1" || true
}

# True when path $1 matches any entry (a literal path or a glob) read from $2.
path_is_allowlisted() {
  local path="$1" entry
  while IFS= read -r entry; do
    # shellcheck disable=SC2254
    case "$path" in
      $entry) return 0 ;;
    esac
  done < <(allowlist_entries "$2")
  return 1
}

# Print each tracked file under root $1 that names a removed token and matches
# no entry in allowlist $2.
unallowlisted_hits() {
  local root="$1" allowlist="$2" hit
  while IFS= read -r hit; do
    path_is_allowlisted "$hit" "$allowlist" || printf '%s\n' "$hit"
  done < <(git -C "$root" grep -l -E "$TOKEN_PATTERN" || true)
}

# Print each allowlist entry under root $1 that matches no hit.
unused_entries() {
  local root="$1" allowlist="$2" entry hit used
  while IFS= read -r entry; do
    used=0
    while IFS= read -r hit; do
      # shellcheck disable=SC2254
      case "$hit" in
        $entry) used=1 ;;
      esac
    done < <(git -C "$root" grep -l -E "$TOKEN_PATTERN" || true)
    [ "$used" -eq 1 ] || printf '%s\n' "$entry"
  done < <(allowlist_entries "$allowlist")
}

# The guard: exit 0 only when there is no offending hit and no unused entry.
guard_removed() {
  local root="$1" allowlist="$2" offenders unused
  offenders="$(unallowlisted_hits "$root" "$allowlist")"
  unused="$(unused_entries "$root" "$allowlist")"
  if [ -n "$offenders" ]; then
    printf 'not allowlisted:\n%s\n' "$offenders" >&2
  fi
  if [ -n "$unused" ]; then
    printf 'unused allowlist entries:\n%s\n' "$unused" >&2
  fi
  [ -z "$offenders" ] && [ -z "$unused" ]
}

# A scratch repo with one tracked file naming a removed token; the file is
# allowlisted only when $1 is "listed".
make_scratch_tree() {
  local mode="$1" token
  token="$(printf 'gaia%sci' -)"
  SCRATCH="$BATS_TEST_TMPDIR/scratch"
  mkdir -p "$SCRATCH"
  git -C "$SCRATCH" init -q
  printf 'uses the %s lane\n' "$token" >"$SCRATCH/offender.md"
  printf 'clean\n' >"$SCRATCH/clean.md"
  git -C "$SCRATCH" add offender.md clean.md
  SCRATCH_ALLOWLIST="$BATS_TEST_TMPDIR/scratch.allowlist"
  : >"$SCRATCH_ALLOWLIST"
  if [ "$mode" = listed ]; then
    printf 'offender.md\n' >"$SCRATCH_ALLOWLIST"
  fi
}

@test "UAT-002: no tracked file outside the allowlist names a removed token, and no entry is unused" {
  run guard_removed "$REPO_ROOT" "$ALLOWLIST"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "UAT-002 can fail: a non-allowlisted file naming a removed token is flagged" {
  make_scratch_tree unlisted
  run guard_removed "$SCRATCH" "$SCRATCH_ALLOWLIST"
  [ "$status" -ne 0 ]
  [[ "$output" == *"offender.md"* ]]
}

@test "UAT-002 can fail: an allowlist entry that matches no hit is flagged" {
  make_scratch_tree listed
  printf 'never-matches.md\n' >>"$SCRATCH_ALLOWLIST"
  run guard_removed "$SCRATCH" "$SCRATCH_ALLOWLIST"
  [ "$status" -ne 0 ]
  [[ "$output" == *"never-matches.md"* ]]
}

@test "UAT-002: the matcher passes a scratch tree whose only hit is allowlisted" {
  make_scratch_tree listed
  run guard_removed "$SCRATCH" "$SCRATCH_ALLOWLIST"
  [ "$status" -eq 0 ]
}

@test "criterion 12: the removed docs-site page is linked only from allowlisted paths" {
  local link hit
  link="docs.gaiareact.com/maintenance/$(printf 'gaia%sci' -)"
  while IFS= read -r hit; do
    path_is_allowlisted "$hit" "$ALLOWLIST" || { echo "linked from $hit"; return 1; }
  done < <(git -C "$REPO_ROOT" grep -l -F -- "$link" || true)
  true
}

@test "UAT-001: the CLI templates ship no workflows directory and no claude-code-action file" {
  local action
  action="claude-code-$(printf 'action')"
  [ ! -e "$REPO_ROOT/.gaia/cli/templates/workflows" ]
  run grep -rlF -- "$action" "$REPO_ROOT/.gaia/cli/templates"
  [ "$status" -eq 1 ]
}

@test "UAT-001: every removed CLI verb exits non-zero with an unknown_subcommand code" {
  local verbs verb stderr_text
  verbs=(
    "automation read-config"
    "automation cron-decide wiki"
    "init configure-automation"
    "setup-ci status"
    "setup-ci check-drift"
    "setup-ci check-audit-drift"
    "setup-ci dismiss-personal"
    "setup-ci opt-out-team"
    "setup-ci verify-run"
    "setup-ci finalize"
    "setup-ci write-tool-mode"
    "wiki diff-size"
  )
  for verb in "${verbs[@]}"; do
    # shellcheck disable=SC2086
    if stderr_text="$("$GAIA_BIN" $verb 2>&1 >/dev/null)"; then
      echo "exited zero: $verb"
      return 1
    fi
    [[ "$stderr_text" == *'"code":"unknown_subcommand"'* ]] || { echo "no unknown_subcommand for: $verb ($stderr_text)"; return 1; }
  done
  true
}

@test "UAT-001 can fail: a kept CLI verb is accepted, so rejecting every verb would be caught" {
  local stderr_text
  stderr_text="$("$GAIA_BIN" setup-ci --help 2>&1 >/dev/null)" || return 1
  [[ "$stderr_text" != *'"code":"unknown_subcommand"'* ]]
}

@test "UAT-001: the PR-time bundle-freshness step is still wired into cli-tests" {
  grep -qF -- "$FRESHNESS_STEP" "$REPO_ROOT/.github/workflows/cli-tests.yml"
}

@test "UAT-001 can fail: the freshness-step check flags a workflow copy without it" {
  local scratch="$BATS_TEST_TMPDIR/cli-tests.yml"
  grep -vF -- "$FRESHNESS_STEP" "$REPO_ROOT/.github/workflows/cli-tests.yml" >"$scratch" || true
  run grep -qF -- "$FRESHNESS_STEP" "$scratch"
  [ "$status" -ne 0 ]
}
