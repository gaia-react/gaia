#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/check-audit-base-derivation.sh, the
# static check keeping the five Code Audit Team definitions on one review
# base. The behavioral suite next door
# (.gaia/scripts/tests/audit-base-agreement.bats) proves the five agree by
# executing their real snippets; this one proves the STATIC check that stops
# them drifting apart actually fires, which a green run can never show on
# its own.
#
# Every test except the two marked "real repo" drives the check against a
# FIXTURE tree it builds, never the real repo, so "would this shape fail the
# check" is answerable without doctoring tracked source.
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/check-audit-base-derivation.bats`.
#
# Assertion style follows .claude/rules/bats-assertions.md: non-final
# absence checks use a positive match for the bad case plus an explicit
# `return 1`, never `!`-negation; equality/numeric/empty checks use POSIX
# `[ ... ]`.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CHECK="$SCRIPT_DIR/check-audit-base-derivation.sh"
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  # shellcheck source=.gaia/scripts/check-audit-base-derivation.sh
  source "$CHECK"
  FIXTURE_REPOS=()
}

teardown() {
  local d
  for d in "${FIXTURE_REPOS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  return 0
}

make_fixture_repo() {
  local name="$1"
  local dir="$BATS_TEST_TMPDIR/$name"
  mkdir -p "$dir/.claude/agents"
  git init -q --initial-branch=main "$dir"
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name T
  git -C "$dir" config commit.gpgsign false
  FIXTURE_REPOS+=("$dir")
  printf '%s' "$dir"
}

write_agent_file() {
  local repo="$1" name="$2" content="$3"
  printf '%s' "$content" > "$repo/.claude/agents/$name"
}

commit_fixture_repo() {
  local repo="$1"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m fixture
}

# ---------- fixture content ----------

CONVERTED_OK='Agent prose.
```bash
FULL_BASE=$(git -C "$AUDIT_ROOT" merge-base HEAD "origin/${default_branch}" 2>/dev/null || true)
BASE_REF="$(cd "$AUDIT_ROOT" && .github/audit/resolve-audit-base.sh)"
BASE_SHA="$(git -C "$AUDIT_ROOT" merge-base "${BASE_REF}" HEAD 2>/dev/null || true)"
```
'

DRIFTED_BARE_MERGE_BASE='Agent prose.
```bash
BASE_SHA=$(git -C "$AUDIT_ROOT" merge-base HEAD "origin/${default_branch}" 2>/dev/null || true)
```
The base comes from .github/audit/resolve-audit-base.sh, or so this file claims.
'

DRIFTED_LOWERCASE_ALIAS='Agent prose.
```bash
base=$(git merge-base HEAD "origin/main")
```
Derived per .github/audit/resolve-audit-base.sh.
'

NAMES_BASE_SHA_NO_RESOLVER='Pass the same `BASE_SHA` you already resolved at the start of the run.
'

UNRELATED_FILE='This agent never resolves a review base at all.
'

FULL_BASE_ONLY='```bash
FULL_BASE=$(git -C "$AUDIT_ROOT" merge-base HEAD "origin/${default_branch}" 2>/dev/null || true)
```
'

# ---------- assertion 1: no bare-merge-base review derivation ----------

@test "fixture: a converted file (FULL_BASE plus a resolver-derived BASE_SHA) passes clean" {
  local repo
  repo="$(make_fixture_repo converted-ok)"
  write_agent_file "$repo" code-audit-maintainer-shell.md "$CONVERTED_OK"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 0 ]
  grep -qF "review bases derived by a bare merge-base against the default branch: 0" <<<"$output" || return 1
  grep -qF "agent files naming BASE_SHA without naming resolve-audit-base.sh: 0" <<<"$output" || return 1
}

@test "fixture: a BASE_SHA derived by a bare merge-base fails assertion 1" {
  local repo
  repo="$(make_fixture_repo drifted-bare)"
  write_agent_file "$repo" code-audit-maintainer-node.md "$DRIFTED_BARE_MERGE_BASE"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "code-audit-maintainer-node.md" <<<"$output" || return 1
  grep -qF "review bases derived by a bare merge-base against the default branch: 1" <<<"$output" || return 1
  # Assertion 2 is satisfied here (the file does name the resolver), so this
  # red is assertion 1's alone -- the two are independently reportable.
  grep -qF "agent files naming BASE_SHA without naming resolve-audit-base.sh: 0" <<<"$output" || return 1
}

@test "fixture: a lowercase alias for the same bare derivation fails assertion 1" {
  local repo
  repo="$(make_fixture_repo drifted-alias)"
  write_agent_file "$repo" code-audit-maintainer-prose.md "$DRIFTED_LOWERCASE_ALIAS"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "review bases derived by a bare merge-base against the default branch: 1" <<<"$output" || return 1
}

@test "fixture: the FULL_BASE self-skip derivation is exempt and never counted" {
  local repo
  repo="$(make_fixture_repo full-base-only)"
  write_agent_file "$repo" code-audit-github-workflows.md "$FULL_BASE_ONLY"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 0 ]
  grep -qF "review bases derived by a bare merge-base against the default branch: 0" <<<"$output" || return 1
}

# ---------- assertion 2: every BASE_SHA namer names the resolver ----------

@test "fixture: a file naming BASE_SHA without ever naming the resolver fails assertion 2" {
  local repo
  repo="$(make_fixture_repo names-base-no-resolver)"
  write_agent_file "$repo" some-agent.md "$NAMES_BASE_SHA_NO_RESOLVER"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "names BASE_SHA but never names resolve-audit-base.sh: .claude/agents/some-agent.md" <<<"$output" || return 1
  grep -qF "agent files naming BASE_SHA without naming resolve-audit-base.sh: 1" <<<"$output" || return 1
  # ...and assertion 1 stays clean, because dropping the reference removes a
  # line rather than adding a bad one. This is the case assertion 1 cannot
  # see, which is why both run.
  grep -qF "review bases derived by a bare merge-base against the default branch: 0" <<<"$output" || return 1
}

@test "fixture: a file that never names BASE_SHA is never required to name the resolver" {
  local repo
  repo="$(make_fixture_repo unrelated)"
  write_agent_file "$repo" unrelated.md "$UNRELATED_FILE"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 0 ]
  grep -qF "agent files naming BASE_SHA without naming resolve-audit-base.sh: 0" <<<"$output" || return 1
}

@test "fixture: multiple violations across files are all named, and the check still fails once" {
  local repo
  repo="$(make_fixture_repo multi)"
  write_agent_file "$repo" code-audit-maintainer-node.md "$DRIFTED_BARE_MERGE_BASE"
  write_agent_file "$repo" code-audit-maintainer-shell.md "$NAMES_BASE_SHA_NO_RESOLVER"
  write_agent_file "$repo" unrelated.md "$UNRELATED_FILE"
  commit_fixture_repo "$repo"
  run gaia_check_audit_base_derivation "$repo"
  [ "$status" -eq 1 ]
  grep -qF "code-audit-maintainer-node.md" <<<"$output" || return 1
  grep -qF "code-audit-maintainer-shell.md" <<<"$output" || return 1
  grep -qF "unrelated.md" <<<"$output" && return 1
  return 0
}

# ---------- real repo: the standing guarantee ----------

@test "real repo: every Code Audit Team definition resolves its review base through the resolver" {
  run gaia_check_audit_base_derivation "$REPO_ROOT"
  [ "$status" -eq 0 ]
  grep -qF "review bases derived by a bare merge-base against the default branch: 0" <<<"$output" || return 1
  grep -qF "agent files naming BASE_SHA without naming resolve-audit-base.sh: 0" <<<"$output" || return 1
}

@test "real repo: the guarantee above is not vacuous -- definitions do name BASE_SHA and do keep a FULL_BASE" {
  # Both verdicts are counts of violations, so a scan that saw no candidate
  # at all reports zero and passes. Pin both candidate sets as non-empty: the
  # BASE_SHA namers assertion 2 ranges over, and the exempted FULL_BASE
  # derivation assertion 1 must be deciding about rather than never meeting.
  run git -C "$REPO_ROOT" grep -lIF 'BASE_SHA' -- '.claude/agents/'
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  grep -qF "code-audit-frontend.md" <<<"$output" || return 1

  run git -C "$REPO_ROOT" grep -lIE '^FULL_BASE=' -- '.claude/agents/'
  [ "$status" -eq 0 ]
  grep -qF "code-audit-maintainer-shell.md" <<<"$output" || return 1
}

# ---------- structural ----------

@test "structural: check-audit-base-derivation.sh is executable" {
  [ -x "$CHECK" ]
}

@test "structural: sourcing the script defines gaia_check_audit_base_derivation with no side effects" {
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    type gaia_check_audit_base_derivation >/dev/null
    echo OK
  ' _ "$CHECK"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "structural: never invokes cd, per .claude/rules/shell-cwd.md" {
  code_lines="$(grep -vE '^[[:space:]]*#' "$CHECK")"
  grep -qE '(^|[^[:alnum:]_])cd([^[:alnum:]_]|$)' <<<"$code_lines" && return 1
  return 0
}

@test "structural: no hardcoded /Users or /home paths" {
  grep -E '/Users/|/home/' "$CHECK" && return 1
  return 0
}

@test "structural: shellcheck is clean" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not available"
  shellcheck "$CHECK"
}
