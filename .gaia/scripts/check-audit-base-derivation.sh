#!/usr/bin/env bash
# shellcheck shell=bash
#
# Keep the Code Audit Team's five members on ONE review base.
#
# `gaia_audit_key` (.gaia/scripts/audit-key-lib.sh) is
# `<base_sha>.<branch-slug>`, and co-dispatched members share a branch, so
# the findings sidecars and the shared re-run ledger land under one key
# exactly when the base shas agree. A member that derives its own base
# writes under a key no reader globs: `post-findings-block.sh` finds the
# other members' sidecars, silently misses that one, and posts a
# consolidated block short a whole member's findings with no error anywhere.
# That is the false-green shape this check exists to end -- nothing about it
# is visible in a passing run.
#
# The behavioral suite (.gaia/scripts/tests/audit-base-agreement.bats)
# proves the five agree TODAY by executing their real derivation snippets.
# It cannot stop tomorrow's edit from reintroducing a private derivation in
# a definition it does not happen to exercise. This static check closes that
# gap the way check-audit-key-callers.sh closes the matching one for the
# key itself.
#
# Over `.claude/agents/`, TWO assertions:
#
#   1. No REVIEW base is derived by a bare `merge-base ... origin/...`. The
#      review base must come from `.github/audit/resolve-audit-base.sh`,
#      which anchors on the newest ancestor carrying a clean audit signal
#      under the current .gaia/VERSION and resets to full scope on a
#      machinery change. A bare merge-base against the default branch is the
#      pre-fix derivation: it never moves across fix rounds, so the member
#      re-reviews the whole PR every round AND keys its artifacts to a base
#      no other consumer uses.
#
#      One bare merge-base is legitimate and is deliberately exempted by
#      NAME: `FULL_BASE`, the whole-PR fork point each specialist keeps for
#      its SELF-SKIP arm. Self-skip is a membership decision, and membership
#      is resolved over the whole PR diff (.gaia/scripts/resolve-audit-members.sh,
#      and the "Full-PR scope (load-bearing)" note in
#      .github/audit/gate-pending-members.sh). A member that self-skipped on
#      the increment could write no marker while membership still demanded
#      one, deadlocking the merge. So the exemption is not a loophole in
#      this check; it is the other half of the design, and the variable name
#      is what tells the two apart. The assignment that owns a `merge-base`
#      call is the nearest `IDENT=` to its left, and only `FULL_BASE` is
#      allowed to own one that names `origin/`.
#
#   2. Every file that NAMES `BASE_SHA` also names `resolve-audit-base.sh`.
#      A token-presence net over the whole file, not a call-shape check: the
#      grep is a fixed-string match, so the sentence explaining where the
#      base comes from satisfies it exactly as the executable line does.
#      That is deliberate, and it is the same shape (and the same reasoning)
#      as assertion 2 of check-audit-key-callers.sh.
#
#      The two assertions are not symmetric. (1) rejects the specific bad
#      derivation. (2) catches the weaker case of a definition that keeps
#      talking about `BASE_SHA` while dropping every reference to where the
#      base comes from -- prose drift that (1) cannot see because it removes
#      a line rather than adding one. Both run independently.
#
# Comment lines are NOT stripped from either scan, unlike
# check-main-root-derivation.sh, which scans executable source where a
# commented-out shape cannot run. These are agent definitions: the file IS
# the instruction, and a "commented-out" derivation in one is still a line a
# model can follow. A comment that spells the bad shape reds this check on
# purpose.
#
# Dual-mode, like the repo's other check scripts: source it for
# gaia_check_audit_base_derivation, or run it directly as a script (see
# "Executable entry" at the bottom).
#
# gaia_check_audit_base_derivation <repo_root>
#   Runs `git -C <repo_root> grep` over `.claude/agents/` (recursive) for
#   both assertions. Prints every match line, then one verdict line per
#   assertion. Returns 0 when BOTH assertions hold, 1 otherwise.
#   <repo_root> is a required parameter -- this check never derives it
#   itself: a CI caller passes the plain checkout root, a bats fixture
#   passes a temp repo, so "would this literal fail the check" is testable
#   without touching real tracked source.
#
# GREEN against this repo's real `.claude/agents/`: all five definitions
# resolve their review base through the resolver, and the only bare
# merge-base left is each specialist's `FULL_BASE`.

# Assertion 1's candidate shape: an assignment whose value reaches a
# `merge-base` call naming `origin/`. Deliberately loose -- the ownership
# test that decides which assignment it belongs to runs in awk below, where
# a "nearest identifier to the left" rule is expressible and an ERE's is
# not.
GAIA_AUDIT_BARE_MERGE_BASE_PATTERN='[A-Za-z_][A-Za-z0-9_]*=.*merge-base.*origin/'

# Assertion 2's two fixed strings.
GAIA_AUDIT_BASE_VAR='BASE_SHA'
GAIA_AUDIT_BASE_RESOLVER='resolve-audit-base.sh'

# _gaia_drop_full_base_matches: reads `file:line:content` lines on stdin (git
# grep's -n format) and keeps only those whose `merge-base` call is owned by
# an assignment OTHER than FULL_BASE. `sub` on a copy removes only the FIRST
# two colon-delimited fields, so a colon inside the content itself never
# shifts the boundary. The owning assignment is the LAST `IDENT=` occurring
# before `merge-base`, which is what "nearest to the left" means on one line.
_gaia_drop_full_base_matches() {
  awk '
    {
      content = $0
      sub(/^[^:]*:[^:]*:/, "", content)
      pos = index(content, "merge-base")
      if (pos == 0) next
      left = substr(content, 1, pos - 1)
      name = ""
      while (match(left, /[A-Za-z_][A-Za-z0-9_]*=/)) {
        name = substr(left, RSTART, RLENGTH - 1)
        left = substr(left, RSTART + RLENGTH)
      }
      if (name != "FULL_BASE") print
    }
  '
}

gaia_check_audit_base_derivation() {
  local repo_root="${1:?gaia_check_audit_base_derivation requires a repo_root argument}"
  local bare_failed=0 resolver_failed=0

  # ---------- assertion 1: no bare-merge-base review derivation ----------
  local candidates bare_matches bare_count=0
  # git grep exits 1 when it finds nothing, a normal outcome here, not a
  # script error -- so it is not run under -e and its status is captured
  # explicitly via the variable assignment instead.
  candidates="$(git -C "$repo_root" grep -nIE "$GAIA_AUDIT_BARE_MERGE_BASE_PATTERN" -- '.claude/agents/' 2>/dev/null)"
  bare_matches="$(printf '%s\n' "$candidates" | _gaia_drop_full_base_matches)"
  if [ -n "$bare_matches" ]; then
    printf '%s\n' "$bare_matches"
    bare_count="$(printf '%s\n' "$bare_matches" | wc -l | tr -d ' ')"
    bare_failed=1
  fi
  printf 'review bases derived by a bare merge-base against the default branch: %s\n' "$bare_count"

  # ---------- assertion 2: every BASE_SHA namer names the resolver ----------
  local base_files f missing_count=0
  base_files="$(git -C "$repo_root" grep -lIF "$GAIA_AUDIT_BASE_VAR" -- '.claude/agents/' 2>/dev/null)"
  if [ -n "$base_files" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if ! git -C "$repo_root" grep -qF "$GAIA_AUDIT_BASE_RESOLVER" -- "$f" 2>/dev/null; then
        printf 'names BASE_SHA but never names resolve-audit-base.sh: %s\n' "$f"
        missing_count=$((missing_count + 1))
        resolver_failed=1
      fi
    done <<< "$base_files"
  fi
  printf 'agent files naming BASE_SHA without naming resolve-audit-base.sh: %s\n' "$missing_count"

  [ "$bare_failed" -eq 0 ] && [ "$resolver_failed" -eq 0 ]
}

# Executable entry.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  repo_root="${1:-}"
  if [ -z "$repo_root" ]; then
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
      printf 'check-audit-base-derivation: not a git repository and no repo_root argument given\n' >&2
      exit 2
    }
  fi
  gaia_check_audit_base_derivation "$repo_root"
  exit $?
fi
