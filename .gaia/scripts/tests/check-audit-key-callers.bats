#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/check-audit-key-callers.sh -- the
# static caller check task 4.1 adds alongside `gaia_audit_key` itself
# (analysis/task-4.1-audit-key-design.md §5.2). The meter's fixtures
# (`C4-01`/`C4-02`) prove the FUNCTION partitions two worktrees; they cannot
# prove the five Code Audit Team agent definitions actually CALL it instead
# of hand-building the old collision-prone path. This check closes that gap
# over `.claude/agents/`.
#
# Every test below except the one marked "real repo" drives the check
# against a FIXTURE tree it builds, never the real repo: the real
# `.claude/agents/` definitions are mid-conversion by a parallel task and are
# EXPECTED to fail this check until that conversion lands (see the one real-
# repo test at the bottom, which documents that expected-red state rather
# than hiding it).
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/check-audit-key-callers.bats`.
#
# Assertion style note: per .claude/rules/bats-assertions.md, non-final
# absence checks use a positive match for the bad case plus an explicit
# `return 1`, never `!`-negation; equality/numeric/empty checks use POSIX
# `[ ... ]`, which fails correctly on every bash version.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CHECK="$SCRIPT_DIR/check-audit-key-callers.sh"
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  # shellcheck source=.gaia/scripts/check-audit-key-callers.sh
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

# make_fixture_repo <name>: a fresh git repo under BATS_TEST_TMPDIR with an
# empty .claude/agents/ directory. Returns the repo path on stdout; commits
# happen once the caller has written its fixture files (commit_fixture_repo).
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

# write_agent_file <repo> <basename> <content>
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
# The "converted" shape below calls gaia_audit_key inline rather than binding
# its result to a named variable first -- functionally equivalent to the
# real agent prose's "AUDIT_KEY=$(gaia_audit_key ...)" contract for what this
# check actually inspects (does the file call gaia_audit_key at all, and does
# a bare ${BASE_SHA}./${base}. literal survive), so the fixture proves the
# same thing without duplicating the real contract's exact variable name.

CONVERTED_OK='Some agent prose.
```bash
. .gaia/scripts/audit-key-lib.sh
SIDECAR=".gaia/local/audit/$(gaia_audit_key "$BASE_SHA").code-audit-frontend.findings.json"
LEDGER=".gaia/local/audit/$(gaia_audit_key "$BASE_SHA").rerun.json"
```
'

BAD_LEDGER_LITERAL='```bash
BASE_SHA="$(git merge-base "$BASE_REF" HEAD)"
LEDGER=".gaia/local/audit/${BASE_SHA}.rerun.json"
```
'

BAD_SIDECAR_LITERAL_BASE='Path: `.gaia/local/audit/${base}.code-audit-maintainer-prose.findings.json`
'

NAMES_LEDGER_NO_CALL='The re-run ledger lives at .gaia/local/audit/whatever.rerun.json, built elsewhere.
'

NAMES_FINDINGS_NO_CALL='The findings sidecar lives at .gaia/local/audit/whatever.findings.json, built elsewhere.
'

UNRELATED_FILE='This agent never touches an audit sidecar or the re-run ledger at all.
'

BAD_LITERAL_PLUS_CALL_ELSEWHERE='```bash
. .gaia/scripts/audit-key-lib.sh
SIDECAR=".gaia/local/audit/$(gaia_audit_key "$BASE_SHA").code-audit-frontend.findings.json"
LEDGER=".gaia/local/audit/${BASE_SHA}.rerun.json"
```
'

# ---------- assertion 1: bad literal ----------

@test "fixture: a converted file (calls gaia_audit_key, no bare literal) passes clean" {
  local repo
  repo="$(make_fixture_repo converted-ok)"
  write_agent_file "$repo" code-audit-frontend.md "$CONVERTED_OK"
  commit_fixture_repo "$repo"
  run gaia_check_audit_key_callers "$repo"
  [ "$status" -eq 0 ]
  grep -qF "bare BASE_SHA/base literal sidecar-or-ledger paths found: 0" <<<"$output" || return 1
  grep -qF "agent files naming a sidecar/ledger without a gaia_audit_key call: 0" <<<"$output" || return 1
}

@test "fixture: a bare \${BASE_SHA}.rerun.json ledger literal fails assertion 1" {
  local repo
  repo="$(make_fixture_repo bad-ledger)"
  write_agent_file "$repo" code-audit-frontend.md "$BAD_LEDGER_LITERAL"
  commit_fixture_repo "$repo"
  run gaia_check_audit_key_callers "$repo"
  [ "$status" -eq 1 ]
  grep -qF "code-audit-frontend.md" <<<"$output" || return 1
  grep -qF '${BASE_SHA}.rerun.json' <<<"$output" || return 1
  grep -qF "bare BASE_SHA/base literal sidecar-or-ledger paths found: 1" <<<"$output" || return 1
}

@test "fixture: a bare \${base}.<member>.findings.json literal (member name interposed) fails assertion 1" {
  local repo
  repo="$(make_fixture_repo bad-sidecar)"
  write_agent_file "$repo" code-audit-maintainer-prose.md "$BAD_SIDECAR_LITERAL_BASE"
  commit_fixture_repo "$repo"
  run gaia_check_audit_key_callers "$repo"
  [ "$status" -eq 1 ]
  grep -qF "code-audit-maintainer-prose.md" <<<"$output" || return 1
  grep -qF '${base}.code-audit-maintainer-prose.findings.json' <<<"$output" || return 1
}

@test "fixture: a leftover bad literal fails assertion 1 even when the file also calls gaia_audit_key elsewhere" {
  local repo
  repo="$(make_fixture_repo half-converted)"
  write_agent_file "$repo" code-audit-frontend.md "$BAD_LITERAL_PLUS_CALL_ELSEWHERE"
  commit_fixture_repo "$repo"
  run gaia_check_audit_key_callers "$repo"
  [ "$status" -eq 1 ]
  grep -qF '${BASE_SHA}.rerun.json' <<<"$output" || return 1
  # Assertion 2 passes for this file (it does call gaia_audit_key) -- only
  # assertion 1's count is nonzero.
  grep -qF "agent files naming a sidecar/ledger without a gaia_audit_key call: 0" <<<"$output" || return 1
  grep -qF "bare BASE_SHA/base literal sidecar-or-ledger paths found: 1" <<<"$output" || return 1
}

# ---------- assertion 2: every namer calls gaia_audit_key ----------

@test "fixture: a file naming the re-run ledger without ever calling gaia_audit_key fails assertion 2" {
  local repo
  repo="$(make_fixture_repo names-ledger-no-call)"
  write_agent_file "$repo" some-agent.md "$NAMES_LEDGER_NO_CALL"
  commit_fixture_repo "$repo"
  run gaia_check_audit_key_callers "$repo"
  [ "$status" -eq 1 ]
  grep -qF "names a sidecar/ledger but never calls gaia_audit_key: .claude/agents/some-agent.md" <<<"$output" || return 1
  grep -qF "agent files naming a sidecar/ledger without a gaia_audit_key call: 1" <<<"$output" || return 1
}

@test "fixture: a file naming a findings sidecar without ever calling gaia_audit_key fails assertion 2" {
  local repo
  repo="$(make_fixture_repo names-findings-no-call)"
  write_agent_file "$repo" some-agent.md "$NAMES_FINDINGS_NO_CALL"
  commit_fixture_repo "$repo"
  run gaia_check_audit_key_callers "$repo"
  [ "$status" -eq 1 ]
  grep -qF "names a sidecar/ledger but never calls gaia_audit_key: .claude/agents/some-agent.md" <<<"$output" || return 1
}

@test "fixture: a file that never names a sidecar or the ledger is never required to call gaia_audit_key" {
  local repo
  repo="$(make_fixture_repo unrelated)"
  write_agent_file "$repo" unrelated.md "$UNRELATED_FILE"
  commit_fixture_repo "$repo"
  run gaia_check_audit_key_callers "$repo"
  [ "$status" -eq 0 ]
  grep -qF "agent files naming a sidecar/ledger without a gaia_audit_key call: 0" <<<"$output" || return 1
}

@test "fixture: multiple violations across files are all named, and the check still fails once" {
  local repo
  repo="$(make_fixture_repo multi)"
  write_agent_file "$repo" code-audit-frontend.md "$BAD_LEDGER_LITERAL"
  write_agent_file "$repo" code-audit-maintainer-shell.md "$NAMES_FINDINGS_NO_CALL"
  write_agent_file "$repo" unrelated.md "$UNRELATED_FILE"
  commit_fixture_repo "$repo"
  run gaia_check_audit_key_callers "$repo"
  [ "$status" -eq 1 ]
  grep -qF "code-audit-frontend.md" <<<"$output" || return 1
  grep -qF "code-audit-maintainer-shell.md" <<<"$output" || return 1
  grep -qF "unrelated.md" <<<"$output" && return 1
  return 0
}

# ---------- real repo: the standing guarantee ----------

@test "real repo: every Code Audit Team definition derives its path through gaia_audit_key" {
  run gaia_check_audit_key_callers "$REPO_ROOT"
  [ "$status" -eq 0 ]
  grep -qF "bare BASE_SHA/base literal sidecar-or-ledger paths found: 0" <<<"$output" || return 1
  grep -qF "agent files naming a sidecar/ledger without a gaia_audit_key call: 0" <<<"$output" || return 1
}

@test "real repo: the guarantee above is not vacuous -- agent definitions do name these artifacts" {
  # Both of the check's verdicts are counts of violations, so a scan that saw
  # no candidate at all reports zero and passes. Pin the candidate set as
  # non-empty so a future move of the agent definitions out from under
  # `.claude/agents/` surfaces as a red here rather than as a silent green.
  run git -C "$REPO_ROOT" grep -lIE 'findings\.json|rerun\.json' -- '.claude/agents/'
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  grep -qF "code-audit-frontend.md" <<<"$output" || return 1
}

# ---------- structural ----------

@test "structural: check-audit-key-callers.sh is executable" {
  [ -x "$CHECK" ]
}

@test "structural: sourcing the script defines gaia_check_audit_key_callers with no side effects" {
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    type gaia_check_audit_key_callers >/dev/null
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
