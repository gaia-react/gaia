#!/usr/bin/env bats
# audit-shell-member.bats: the adopter shell member's roster entry, its routing
# against the maintainer shell member, and the content of its definition.
#
# Routing is first-match, so the adopter entry sits after the maintainer-only
# block: this repository's own shell stays on the maintainer member, and an
# adopter clone (block stripped) routes the same paths to the adopter member.
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  SCOPE_LIBRARY="$REPO_ROOT/.claude/hooks/lib/audit-scope.sh"
  ROSTER="${SHELL_MEMBER_ROSTER:-$REPO_ROOT/.gaia/audit-ci.yml}"
  DEFINITION="${SHELL_MEMBER_DEFINITION:-$REPO_ROOT/.claude/agents/code-audit-shell.md}"
}

# owner_of <roster> <path>: the member the classifier assigns the path.
owner_of() {
  bash -c '
    . "$1" || exit 9
    audit_scope_init "$2" "$3" || exit 9
    printf "%s\n" "$4" | audit_owners_for_paths | cut -f2
  ' _ "$SCOPE_LIBRARY" "$REPO_ROOT" "$1" "$2"
}

# adopter_roster: prints the path of the roster with the maintainer-only block
# stripped, as an adopter clone carries it.
adopter_roster() {
  awk '
    index($0, "# gaia:maintainer-only:start") { inside = 1; next }
    index($0, "# gaia:maintainer-only:end") { inside = 0; next }
    !inside { print }
  ' "$ROSTER" > "$BATS_TEST_TMPDIR/adopter.yml"
  printf '%s\n' "$BATS_TEST_TMPDIR/adopter.yml"
}

@test "this repository's own shell routes to the maintainer shell member, never the adopter member" {
  local path owner
  for path in .gaia/tests/verify-harness.sh .gaia/scripts/tests/audit-scope-lib.bats .claude/hooks/audit-loop-bound.sh .githooks/pre-commit .claude/hooks/lib/audit-member-protocol.md .github/actions/x/run.sh; do
    owner="$(owner_of "$ROSTER" "$path")"
    [ "$owner" = code-audit-maintainer-shell ] || { echo "$path -> $owner" >&2; return 1; }
  done
}

@test "an adopter clone routes shell, bats, hooks, git hooks and composite-action scripts to the adopter shell member" {
  local roster path owner
  roster="$(adopter_roster)"
  for path in scripts/build.sh tests/shell/a.bats .claude/hooks/x.sh .githooks/pre-commit .github/actions/x/run.sh frontend/app/x.sh; do
    owner="$(owner_of "$roster" "$path")"
    [ "$owner" = code-audit-shell ] || { echo "$path -> $owner" >&2; return 1; }
  done
}

@test "the frontend member claims no composite-action script in either list" {
  local frontend
  frontend="$(awk '/^  - name: code-audit-frontend$/ { inside = 1; next } inside && /^  - name:/ { exit } inside { print }' "$ROSTER")"
  [ -n "$frontend" ]
  grep -qF '.github/actions/**/*.sh' <<<"$frontend" && return 1
  true
}

@test "the shell entry carries the release-skip key and the hook, git hook and bats hard-full globs" {
  local entry
  entry="$(awk '/^  - name: code-audit-shell$/ { inside = 1; print; next } inside && /^  - name:/ { exit } inside && /^[a-z]/ { exit } inside { print }' "$ROSTER")"
  [ -n "$entry" ]
  grep -qx '    skip_gaia_release_changes: true' <<<"$entry" || return 1
  grep -qx '    audience: adopter' <<<"$entry" || return 1
  grep -qF '".githooks/**"' <<<"$entry" || return 1
  grep -qF '"**/*.bats"' <<<"$entry" || return 1
}

@test "the definition is registered as audit machinery" {
  bash -c '. "$1/.claude/hooks/lib/audit-machinery.sh" && audit_path_is_machinery .claude/agents/code-audit-shell.md' _ "$REPO_ROOT"
}

@test "the definition carries the correctness core, scoped hook and bats lenses, and no maintainer-only content" {
  local topic
  [ -s "$DEFINITION" ] || return 1
  for topic in 'Quoting' 'set -euo pipefail' 'Fail-open vs. fail-closed' 'Bash 3.2' 'BSD-vs-GNU'; do
    grep -qF -- "$topic" "$DEFINITION" || { echo "missing: $topic" >&2; return 1; }
  done
  grep -qE '^## Conditional hook-contract lens' "$DEFINITION" || return 1
  grep -qF 'This lens activates only for hook scripts' "$DEFINITION" || return 1
  grep -qE '^## Conditional bats-suite lens' "$DEFINITION" || return 1
  grep -qF 'This lens activates only for `.bats` files' "$DEFINITION" || return 1
  for topic in 'Conditional declarative-surface lens' 'Triage threshold' 'harness-triage-threshold' '.gaia/tests/' 'bats5' 'shell-lint.sh' 'verify-harness' 'code-audit-maintainer-shell'; do
    grep -qF -- "$topic" "$DEFINITION" && { echo "forbidden: $topic" >&2; return 1; }
  done
  true
}

@test "the definition cites the shell testing page and the bats assertion rule" {
  grep -qF 'wiki/concepts/Shell Testing and CI.md' "$DEFINITION" || return 1
  grep -qF '.claude/rules/bats-assertions.md' "$DEFINITION" || return 1
  true
}

@test "the shell entry claims the Claude settings file and leaves it off the hard-full list" {
  local entry globs_block hard_full_block
  entry="$(awk '/^  - name: code-audit-shell$/ { inside = 1; print; next } inside && /^  - name:/ { exit } inside && /^[a-z]/ { exit } inside { print }' "$ROSTER")"
  [ -n "$entry" ]
  globs_block="$(awk '/^    globs:$/ { inside = 1; next } inside && /^    [a-z_]+:/ { exit } inside { print }' <<<"$entry")"
  hard_full_block="$(awk '/^    light_hard_full:$/ { inside = 1; next } inside && /^    [a-z_]+:/ { exit } inside { print }' <<<"$entry")"
  [ -n "$globs_block" ]
  [ -n "$hard_full_block" ]
  grep -qF '".claude/settings.json"' <<<"$globs_block" || return 1
  grep -qF '".claude/settings.json"' <<<"$hard_full_block" && return 1
  true
}

# settings_lens_complete FILE: succeeds when FILE carries the settings lens,
# wired into its Contents line and methodology, with the review requirements.
settings_lens_complete() {
  local file="$1" section topic
  grep -qE '^## Conditional settings lens' "$file" || return 1
  grep -qxF 'This lens activates only for `.claude/settings.json`.' "$file" || return 1
  grep -E '^Contents:' "$file" | grep -qF 'Conditional settings lens' || return 1
  grep -E '^[0-9]+\. ' "$file" | grep 'settings lens' | grep -qF '.claude/settings.json' || return 1
  section="$(awk '/^## Conditional settings lens/ { inside = 1; next } inside && /^## / { exit } inside { print }' "$file")"
  [ -n "$section" ] || return 1
  for topic in 'removes' 'weakens' 're-scopes' 'permissions.deny' 'permissions.ask' 'permissions.allow' 'hook registration' 'found none'; do
    grep -qF -- "$topic" <<<"$section" || return 1
  done
  return 0
}

@test "the definition carries the settings lens, its activation sentence, Contents entry and methodology step" {
  settings_lens_complete "$DEFINITION"
}

@test "guard can fail: a definition without the settings lens section fails the lens predicate" {
  local stripped="$BATS_TEST_TMPDIR/no-settings-lens.md"
  awk '/^## Conditional settings lens/ { skipping = 1; next } skipping && /^## / { skipping = 0 } !skipping { print }' "$DEFINITION" > "$stripped"
  cmp -s "$DEFINITION" "$stripped" && return 1
  run settings_lens_complete "$stripped"
  [ "$status" -ne 0 ]
}
