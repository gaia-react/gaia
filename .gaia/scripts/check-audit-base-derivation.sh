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
#   1. No REVIEW base is derived by a bare `merge-base` against a branch.
#      The review base must come from `.github/audit/resolve-audit-base.sh`,
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
#      call is the nearest `IDENT=` to its left, and `FULL_BASE` is the only
#      name allowed to own a call that does not pass `BASE_REF`.
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

# Assertion 1's candidate shape: any assignment whose value reaches a
# `merge-base` call. Deliberately a wide net -- BOTH discriminations that
# narrow it run in awk below, where they are expressible and an ERE's are
# not.
#
# Enumerating the bad shapes here does not work, because the set is open.
# `origin/${default_branch}`, the bare `"${default_branch}"` fallback, and a
# literal `merge-base HEAD main` are three spellings of one drift, and the
# third defeats a branch-name literal in the pattern: `main` appears in the
# ordinary English of these files (`main-thread-authored` at
# code-audit-frontend.md:654), so an ERE carrying it reds a correct tree.
#
# So the check identifies the ONE shape that is right instead. A review base
# derived through the resolver always passes BASE_REF to its own merge-base
# call; every drifted spelling names a branch instead, and FULL_BASE names
# neither. That single positive rule covers every drift SPELLING without
# naming any of them, which is what the open set above defeats.
#
# It is not unconditional, in two ways.
#
# The candidate net still requires the literal `merge-base`, so a base
# derived some other way entirely (`BASE_SHA=$(git rev-parse
# "origin/${default_branch}")`) is never a candidate and this check does not
# see it.
#
# Nearer, and likelier: the two-step resolver shape survives verbatim while
# only BASE_REF's SOURCE changes, `BASE_REF="origin/${default_branch}"`
# feeding the same `merge-base "${BASE_REF}" HEAD`. Assertion 1 exempts that
# call correctly by its own rule, because BASE_REF genuinely is an argument
# to it; assertion 2 passes, because the file still names the resolver in
# its prose. The member has nonetheless reverted fully to the pre-fix bare
# derivation, and the charter sentence at the top of this file ("The review
# base must come from `.github/audit/resolve-audit-base.sh`") promises more
# than the assertion delivers.
#
# The behavioural suite next door covers both, by executing the real fences.
GAIA_AUDIT_BARE_MERGE_BASE_PATTERN='[A-Za-z_][A-Za-z0-9_]*=.*merge-base'

# Assertion 2's two fixed strings.
GAIA_AUDIT_BASE_VAR='BASE_SHA'
GAIA_AUDIT_BASE_RESOLVER='resolve-audit-base.sh'

# _gaia_drop_full_base_matches: reads `file:line:content` lines on stdin (git
# grep's -n format) and keeps only the lines that are actually violations,
# applying the two discriminations the ERE cannot express. A line survives
# when it carries at least one `merge-base` call that neither takes BASE_REF
# inside its own argument list (the resolver-derived shape this check
# requires) nor is owned by FULL_BASE (the self-skip base, deliberately
# exempt). Both tests are per CALL, never per line: "its own argument list"
# ends at the `)` that closes the call, so a BASE_REF named anywhere after
# that vouches for nothing.
#
# `sub` on a copy removes only the FIRST two colon-delimited fields, so a
# colon inside the content itself never shifts the boundary. The owning
# assignment is the LAST `IDENT=` occurring before a call, which is what
# "nearest to the left" means on one line.
#
# The name is narrower than the job: it predates the BASE_REF rule.
#
# EVERY `merge-base` on the line is tested, not just the first. The real
# FULL_BASE assignment already puts two on one line (the `origin/` form and
# its bare fallback, joined by `||`), so a rule keyed to the first
# occurrence alone would clear a whole line whose first call belongs to
# FULL_BASE and whose second belongs to something else.
_gaia_drop_full_base_matches() {
  awk '
    {
      content = $0
      sub(/^[^:]*:[^:]*:/, "", content)
      # `consumed` is how much of content `rest` starts past, so the prefix
      # handed to the ownership walk is always measured from column 1 of the
      # real line rather than from the current search window.
      consumed = 0
      rest = content
      while ((pos = index(rest, "merge-base")) > 0) {
        # Discrimination 1, the positive rule: a call taking BASE_REF as an
        # argument derives its base through the resolver, the shape this
        # check REQUIRES. That is what lets the ERE above stay a wide
        # `merge-base` net without every correct line becoming a violation.
        #
        # Scoped to THIS call'"'"'s own argument list, not the whole line and
        # not merely the text after it. A line-wide test is unsound for the
        # same reason the occurrence walk below exists: `BASE_REF=... ;
        # BASE_SHA=$(git merge-base HEAD origin/main)` would clear on the
        # mention alone, and so would a trailing `# was BASE_REF` comment.
        #
        # The stop set has to close the argument list, and `)` is what
        # actually does that: the call lives inside a `$( )`, so a BASE_REF
        # occurring AFTER the substitution ends is not an argument to it.
        # Without `)` a prose line like "was BASE_SHA=$(git merge-base HEAD
        # main), now BASE_REF" exempts itself. The backtick closes a markdown
        # code span, the same escape one sentence later. Neither character
        # can precede BASE_REF inside the canonical
        # `merge-base "${BASE_REF}" HEAD`.
        #
        # BASE_REF also has to be a WHOLE identifier on its LEFT edge. Matched
        # as a bare substring it is satisfied by the TAIL of a longer name, so
        # a drift routed through an alias exempts itself: `merge-base HEAD
        # "$GITHUB_BASE_REF"` names a branch, and that is an ordinary CI
        # variable rather than an invented one. The class closing the prefix
        # group is that boundary; `"${BASE_REF}"` and `"$BASE_REF"` clear it
        # on their `{` and `$`. The group is optional only so a token at
        # position 0 still matches.
        #
        # That boundary class subtracts the stop set as well, which is not
        # redundant with the run before it. A bare `[^A-Za-z0-9_]` is a
        # SUPERSET of the stop set, so the group could end ON a stop character
        # and hand the exemption straight back: `merge-base HEAD main)BASE_REF`
        # would clear on the `)` that closes the call, the one character the
        # stop set exists to treat as a wall. All six behave that way, so the
        # boundary atom excludes them too.
        #
        # The mirrored RIGHT edge (`${BASE_REF_OLD}`) is knowingly left open,
        # and not for want of a construct: `BASE_REF([^A-Za-z0-9_]|$)` is
        # plain ERE, and the alternation keeps a line that ENDS at the token
        # exempt. It is unused because no drift spelling builds a name by
        # SUFFIXING the token, where `GITHUB_BASE_REF` makes the prefix side
        # live, so the assertion would guard nothing.
        right = substr(content, consumed + pos + 10)
        if (right ~ /^([^|;&#)`]*[^A-Za-z0-9_|;&#)`])?BASE_REF/) {
          consumed += pos + 9
          rest = substr(content, consumed + 1)
          continue
        }
        left = substr(content, 1, consumed + pos - 1)
        name = ""
        while (match(left, /[A-Za-z_][A-Za-z0-9_]*=/)) {
          name = substr(left, RSTART, RLENGTH - 1)
          left = substr(left, RSTART + RLENGTH)
        }
        if (name != "FULL_BASE") { print; next }
        consumed += pos + 9
        rest = substr(content, consumed + 1)
      }
    }
  '
}

gaia_check_audit_base_derivation() {
  local repo_root="${1:?gaia_check_audit_base_derivation requires a repo_root argument}"
  local bare_failed=0 resolver_failed=0

  # A `git grep` that cannot run returns nothing, which is byte-identical to
  # "scanned it, found no violations". Both assertions would then print 0 and
  # the function would report a clean tree it never read. The no-argument
  # path at the bottom of this file already fails closed on this; an explicit
  # argument pointing outside a repository reached the same silence.
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
  local prefix
  if ! prefix="$(git -C "$repo_root" rev-parse --show-prefix 2>/dev/null)" || [ -n "$prefix" ] \
    || [ "$(git -C "$repo_root" rev-parse --is-inside-work-tree 2>/dev/null)" != true ]; then
    printf 'check-audit-base-derivation: %s is not a git repository root; nothing was scanned\n' "$repo_root" >&2
    return 2
  fi

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
