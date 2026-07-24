#!/usr/bin/env bash
# shellcheck shell=bash
#
# Check the audit-key meter (`C4-01`/`C4-02`) cannot see on its own -- task
# 4.1, analysis/task-4.1-audit-key-design.md §5.2. The meter's fixtures prove
# that `gaia_audit_key` (`.gaia/scripts/audit-key-lib.sh`) itself partitions
# two worktrees correctly; they cannot prove the five Code Audit Team agent
# definitions that name a findings sidecar or the re-run ledger actually
# CALL it instead of hand-building the old collision-prone path. Without this
# check, prose drift back to a bare base-sha literal leaves a green meter
# over a broken writer -- the false-green shape this program cares most
# about.
#
# Over `.claude/agents/`, TWO assertions:
#
#   1. No bare `${BASE_SHA}.`/`${base}.` sidecar or ledger path literal
#      survives anywhere. That shell-interpolated shape (`${BASE_SHA}.<member
#      or nothing>.findings.json`, `${BASE_SHA}.rerun.json`, or the same with
#      `${base}`) is exactly the pre-4.1 collision this task removes: the raw
#      base sha (or a caller's lowercase alias for it) used as the whole key,
#      with no branch discriminator. `gaia_audit_key`'s own output variable
#      (conventionally `${AUDIT_KEY}`) is a different token, so a converted
#      caller never trips this pattern.
#   2. Every file that NAMES a findings sidecar or the re-run ledger (mentions
#      `findings.json` or `rerun.json` at all) also calls `gaia_audit_key`
#      somewhere in that same file. A file matching assertion 1's bad literal
#      also, by construction, fails to call `gaia_audit_key` for that path --
#      the two assertions catch the same defect from opposite ends: (1) is
#      "the wrong shape is absent", (2) is "the right call is present". A
#      file could in principle satisfy one without the other (e.g. it calls
#      `gaia_audit_key` for one path but still hand-builds a second, unrelated
#      one), which is why both run independently rather than one implying
#      the other.
#
# Dual-mode, mirroring check-resolver-singleton.sh: source it for
# gaia_check_audit_key_callers, or run it directly as a script (see
# "Executable entry" at the bottom).
#
# gaia_check_audit_key_callers <repo_root>
#   Runs `git -C <repo_root> grep` for both patterns across `.claude/agents/`
#   (recursive: the check names no exemption for a reference doc under an
#   agent's own subdirectory). Prints every match line, then one verdict line
#   per assertion. Returns 0 when BOTH assertions hold, 1 otherwise.
#   <repo_root> is a required parameter -- this check never derives it
#   itself (mirrors check-resolver-singleton.sh: a CI caller passes the plain
#   checkout root, a bats fixture passes a temp repo, so "would this literal
#   fail the check" is testable without touching real tracked source).
#
# GREEN against this repo's real `.claude/agents/`: all five Code Audit Team
# definitions derive their sidecar and ledger paths through `gaia_audit_key`.
# A red here means a definition has drifted back to hand-building a path from
# a bare base sha, which is the collision this key exists to remove.

# Assertion 1's bad-literal pattern: `${BASE_SHA}.` or `${base}.`, optionally
# followed by a member-name segment (`code-audit-frontend.`), then the
# sidecar or ledger filename.
GAIA_AUDIT_KEY_BAD_LITERAL_PATTERN='\$\{(BASE_SHA|base)\}\.([A-Za-z0-9_-]+\.)?(findings|rerun)\.json'

# Assertion 2's "names the artifact at all" net: deliberately looser than the
# bad-literal pattern above. A compliant file names these artifacts via
# `${AUDIT_KEY}`, never `${BASE_SHA}`/`${base}`, so a pattern scoped to the
# bad shape would never flag the converted (compliant) file and assertion 2
# would be vacuous once the prose lands.
GAIA_AUDIT_ARTIFACT_NAME_PATTERN='findings\.json|rerun\.json'

gaia_check_audit_key_callers() {
  local repo_root="${1:?gaia_check_audit_key_callers requires a repo_root argument}"
  local literal_failed=0 caller_failed=0

  # ---------- assertion 1: no bare literal survives ----------
  local literal_matches literal_count=0
  # git grep exits 1 when it finds nothing, a normal outcome here (no bad
  # literal), not a script error -- so it is not run under -e and its status
  # is captured explicitly via the variable assignment instead.
  literal_matches="$(git -C "$repo_root" grep -nIE "$GAIA_AUDIT_KEY_BAD_LITERAL_PATTERN" -- '.claude/agents/' 2>/dev/null)"
  if [ -n "$literal_matches" ]; then
    printf '%s\n' "$literal_matches"
    literal_count="$(printf '%s\n' "$literal_matches" | wc -l | tr -d ' ')"
    literal_failed=1
  fi
  printf 'bare BASE_SHA/base literal sidecar-or-ledger paths found: %s\n' "$literal_count"

  # ---------- assertion 2: every namer calls gaia_audit_key ----------
  local artifact_files f missing_count=0
  artifact_files="$(git -C "$repo_root" grep -lIE "$GAIA_AUDIT_ARTIFACT_NAME_PATTERN" -- '.claude/agents/' 2>/dev/null)"
  if [ -n "$artifact_files" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if ! git -C "$repo_root" grep -qF 'gaia_audit_key' -- "$f" 2>/dev/null; then
        printf 'names a sidecar/ledger but never calls gaia_audit_key: %s\n' "$f"
        missing_count=$((missing_count + 1))
        caller_failed=1
      fi
    done <<< "$artifact_files"
  fi
  printf 'agent files naming a sidecar/ledger without a gaia_audit_key call: %s\n' "$missing_count"

  [ "$literal_failed" -eq 0 ] && [ "$caller_failed" -eq 0 ]
}

# Executable entry.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  repo_root="${1:-}"
  if [ -z "$repo_root" ]; then
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
      printf 'check-audit-key-callers: not a git repository and no repo_root argument given\n' >&2
      exit 2
    }
  fi
  gaia_check_audit_key_callers "$repo_root"
  exit $?
fi
