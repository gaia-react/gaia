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
#      `findings.json` or `rerun.json` at all) also MENTIONS `gaia_audit_key`
#      somewhere in that same file. This is a token-presence net over the
#      whole file, not a call-shape check: the grep is a fixed-string match,
#      so descriptive prose satisfies it exactly as an executable call does.
#      That is deliberate. Only `code-audit-frontend.md` derives a path
#      itself; the other four definitions delegate keying to
#      `.gaia/scripts/audit-write-findings.sh` and name `gaia_audit_key` only
#      to say so, so a call-shape check would fail all four for correctly
#      delegating.
#
#      The two assertions are therefore not symmetric. (1) is the one that
#      bites: it rejects the literal encoding the collision. (2) corroborates:
#      a file naming the artifact also names the keying mechanism it depends
#      on, called or delegated. Drift back to a hand-built path trips (1)
#      outright; (2) catches the weaker case of a file that drops its
#      reference to the mechanism entirely. Both run independently rather
#      than one implying the other.
#
#      The two verdict lines (2) prints label the condition a `call` for
#      brevity; read it as the mention described here.
# gaia:maintainer-only:start
#      That wording is a pinned output contract, asserted verbatim by
#      `.gaia/scripts/tests/check-audit-key-callers.bats`.
# gaia:maintainer-only:end
#
# Dual-mode, like the repo's other check scripts: source it for
# gaia_check_audit_key_callers, or run it directly as a script (see
# "Executable entry" at the bottom).
#
# gaia_check_audit_key_callers <repo_root>
#   Runs `git -C <repo_root> grep` for both patterns across `.claude/agents/`
#   (recursive: the check names no exemption for a reference doc under an
#   agent's own subdirectory). Prints every match line, then one verdict line
#   per assertion. Returns 0 when BOTH assertions hold, 1 otherwise, and 2
#   when <repo_root> is not a git repository root and nothing was scanned.
#   <repo_root> is a required parameter -- this check never derives it
#   itself: a CI caller passes the plain checkout root, a bats fixture
#   passes a temp repo, so "would this literal fail the check" is testable
#   without touching real tracked source.
#
# GREEN against this repo's real `.claude/agents/`: `code-audit-frontend.md`
# derives its ledger path through `gaia_audit_key`, and the other four
# definitions reach the same key by delegating to the sidecar writer. A red
# here means a definition has drifted back to hand-building a path from a
# bare base sha, which is the collision this key exists to remove.

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

  # A `git grep` that cannot run returns nothing, which is byte-identical to
  # "scanned it, found no violations". Both assertions would then print 0 and
  # the function would report a clean tree it never read. The no-argument
  # path at the bottom of this file fails closed on exactly that silence; an
  # explicit argument pointing outside a repository needs this guard to do
  # the same.
  # Exit 2, distinct from assertion failure (1), so a caller can tell "the
  # check says no" from "the check could not run".
  # --show-prefix, not --git-dir: --git-dir succeeds from any path INSIDE a
  # repo, so a subdirectory passed as repo_root would clear the guard and
  # then scan a `.claude/agents/` that does not exist beneath it, returning
  # the same unscanned-tree 0/0 this guard exists to stop.
  #
  # --show-prefix answers both questions in one call and needs no `cd`
  # (.claude/rules/shell-cwd.md): it fails outright outside a repository, and
  # inside one it prints the path from the repo root down to the directory,
  # which is empty exactly at the root. Comparing paths textually would need
  # a subshell `cd` to resolve symlinks on both sides; this does not.
  # --is-inside-work-tree as well: --show-prefix exits 0 with empty output
  # inside a BARE repository and inside a `.git` directory, so either would
  # clear a prefix-only guard as a work-tree root, and the `git grep` below
  # would then fail for want of a work tree with its diagnostic swallowed by
  # the same 2>/dev/null -- the identical unscanned-tree 0/0. It reports
  # false for both shapes and true for a root, a linked worktree root, and a
  # symlink to one.
  #
  # The sibling gate script .gaia/scripts/check-audit-base-derivation.sh
  # carries the same guard over the same `.claude/agents/` scan; the two are
  # deliberately identical.
  local prefix
  if ! prefix="$(git -C "$repo_root" rev-parse --show-prefix 2>/dev/null)" || [ -n "$prefix" ] \
    || [ "$(git -C "$repo_root" rev-parse --is-inside-work-tree 2>/dev/null)" != true ]; then
    printf 'check-audit-key-callers: %s is not a git repository root; nothing was scanned\n' "$repo_root" >&2
    return 2
  fi

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
