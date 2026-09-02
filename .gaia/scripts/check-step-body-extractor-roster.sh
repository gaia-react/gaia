#!/usr/bin/env bash
# shellcheck shell=bash
#
# Check -- the `extract_step_body` family over code-review-audit.yml is a
# DECLARED roster, not a grep recipe re-run by hand on every read.
#
# Over TRACKED SOURCE: enumerates every `.bats` file that could be extracting a
# step out of `.github/workflows/code-review-audit.yml`, and fails when one of
# them appears in neither table below. Several bats files each carry their own
# near-identical copy of a helper that pulls one step's `run:` body out of that
# workflow. bats defines no functions across files, so the copies are kept in
# agreement about what "extract the real step body" means by hand, and until
# this check existed the set was recovered by re-running a `git grep` literal
# that nothing asserted.
#
# WHY A LITERAL RECIPE WAS NOT ENOUGH, and what replaced it. The recipe keyed on
# the awk detector for the `run: |` block scalar. That literal is only correct
# against today's spellings: a copy is free to spell the detector any way awk
# accepts (`index($0, "run: |")`, the pipe matched through a variable), and such
# a copy is invisible to the recipe with nothing going red. Three successive
# audit rounds on the branch that introduced the recipe each recovered one more
# live member by hand-tuning the literal, and each round's literal was believed
# complete when it was written. So the criterion here is deliberately NOT the
# awk detector. It is the two things a copy cannot extract without: it has to
# NAME the workflow, and it has to key on the six-space step header that
# separates one step from the next.
#
# WHAT THIS BUYS, stated honestly. No textual criterion is complete against
# arbitrary awk, and this one does not claim to be. What changes is which gap is
# left. Before: any respelling of the block-scalar detector escaped. After: only
# a copy that reaches the workflow without naming it, or that finds step
# boundaries without the header literal, escapes -- a far narrower and more
# conspicuous thing to write. And the residual gap is the only one left: the two
# literals are load-bearing for the enumeration, so the criterion is stated here
# once instead of being re-derived per read.
#
# THE CANDIDATE SET IS A SUPERSET ON PURPOSE. It catches whole-BLOCK extractors
# and workflow-doctoring suites too, which are not the family. Narrowing the
# enumeration to exclude them would put the family/not-family judgment back into
# an undecidable text match, which is the defect. So the judgment is made once,
# by a human, and written down: a candidate is either a MEMBER or a NOT_MEMBER
# carrying its reason. A reader sees that each was considered rather than
# missed, which is the same shape `.gaia/tests/whole-tree-invariants.sh` uses
# for its own membership question.
#
# STALE ENTRIES FAIL TOO, in both tables. A roster that keeps naming a file that
# no longer extracts anything is the hand-maintained list this check replaced,
# so a listed path that is not a candidate fails as loudly as a candidate that
# is listed nowhere.
#
# Dual-mode, mirroring the repo's other check scripts: source it for
# gaia_check_step_body_extractor_roster, or run it directly.
#
# gaia_check_step_body_extractor_roster <repo_root>
#   Returns 0 when the candidate set and the two tables agree exactly, 1 on any
#   unregistered candidate or stale entry. <repo_root> is required -- this check
#   never derives it itself, so a bats fixture can point it at a temp repo and
#   prove it fails without touching real tracked source.

# The workflow the family is bound to. A copy over a different workflow answers
# to that workflow's shape and is free to diverge, so naming this file is half
# of what makes a candidate a candidate.
GAIA_SBX_WORKFLOW='code-review-audit.yml'

# The step-header literal, at the workflow's own step indentation. Every step
# extractor, body or block, has to find where one step ends and the next begins,
# and this is that boundary. Six spaces is the `steps:` list indentation in
# code-review-audit.yml; a copy keying on a different indentation is reading a
# differently-shaped file. It stops at the colon deliberately: a copy is free to
# anchor its own regex there rather than at the space after it, and that spelling
# is ordinary enough that including the space would leave a gap the WHAT THIS
# BUYS block above calls conspicuous when it would not be.
GAIA_SBX_STEP_HEADER='      - name:'

# The family: step-BODY extractors over code-review-audit.yml, which are the
# copies that must agree with one another about what the body is.
GAIA_SBX_MEMBERS='.gaia/scripts/tests/debt-origin-contract.bats
.github/audit/tests/ci-base-resolution.bats
.github/audit/tests/ci-guard-paths.bats
.github/audit/tests/ci-status-member-gate.bats
.github/audit/tests/ci-workflow-self-mod.bats
.github/audit/tests/cra-status-upsert.bats
.github/audit/tests/self-heal-scope-gate.bats'

# Deliberately NOT the family, `<path>|<reason>`. Each is a candidate by the
# criterion above and each answers no to "is this a step-body extractor over
# code-review-audit.yml", so the answer is written down rather than left as an
# omission this check could not tell from an oversight.
GAIA_SBX_NOT_MEMBERS='.gaia/scripts/tests/distribution-audit-pr-gate.bats|step-body extractor bound to distribution-audit-pr.yml; it names code-review-audit.yml only in prose, and a copy over a different workflow answers to that workflow shape
.github/audit/tests/ci-clean-no-push-status.bats|whole-BLOCK extractor: it keeps the step header line and the env: block undedented, so it answers to a different contract than the dedented run: body
.gaia/scripts/tests/retrigger-reachability.bats|authors its own fixture workflow; the step headers are content it writes into a temp tree, not an extraction from code-review-audit.yml
.gaia/tests/lib/audit-ci-shards.bats|doctors the workflow by replacing a step to build a mutant; it rewrites a step rather than extracting one'

# _gaia_sbx_candidates <repo_root>
# Prints every tracked `.bats` file carrying BOTH literals, sorted. git grep
# exits 1 when it matches nothing, which is a normal outcome here rather than a
# script error, so its status is not allowed to abort the caller.
_gaia_sbx_candidates() {
  local repo_root="$1" named headers
  named="$(git -C "$repo_root" grep -lF -e "$GAIA_SBX_WORKFLOW" -- '*.bats' 2>/dev/null | LC_ALL=C sort)"
  headers="$(git -C "$repo_root" grep -lF -e "$GAIA_SBX_STEP_HEADER" -- '*.bats' 2>/dev/null | LC_ALL=C sort)"
  [ -n "$named" ] && [ -n "$headers" ] || return 0
  comm -12 <(printf '%s\n' "$named") <(printf '%s\n' "$headers")
}

# _gaia_sbx_registered: every path in either table, sorted.
_gaia_sbx_registered() {
  {
    printf '%s\n' "$GAIA_SBX_MEMBERS"
    printf '%s\n' "$GAIA_SBX_NOT_MEMBERS" | sed 's/|.*//'
  } | sed '/^$/d' | LC_ALL=C sort
}

# The three verdict strings below are a pinned output contract, not free-form
# logging: .gaia/tests/lib/step-body-extractor-roster.bats matches each of them
# literally, so rewording one reds a file the editing diff does not touch. Same
# convention as check-audit-key-callers.sh and whole-tree-invariants.sh.
gaia_check_step_body_extractor_roster() {
  local repo_root="${1:?gaia_check_step_body_extractor_roster requires a repo_root argument}"
  local candidates registered unregistered stale failed=0

  candidates="$(_gaia_sbx_candidates "$repo_root")"
  registered="$(_gaia_sbx_registered)"

  unregistered="$(comm -23 <(printf '%s\n' "$candidates" | sed '/^$/d') <(printf '%s\n' "$registered"))"
  stale="$(comm -13 <(printf '%s\n' "$candidates" | sed '/^$/d') <(printf '%s\n' "$registered"))"

  if [ -n "$unregistered" ]; then
    failed=1
    printf 'unregistered step-extractor candidates (add each to GAIA_SBX_MEMBERS, or to GAIA_SBX_NOT_MEMBERS with its reason):\n' >&2
    printf '%s\n' "$unregistered" >&2
  fi

  if [ -n "$stale" ]; then
    failed=1
    printf 'stale roster entries (no longer a candidate; drop each from its table):\n' >&2
    printf '%s\n' "$stale" >&2
  fi

  printf 'step-body extractor roster over %s: %s candidate(s), %s registered\n' \
    "$GAIA_SBX_WORKFLOW" \
    "$(printf '%s\n' "$candidates" | sed '/^$/d' | wc -l | tr -d ' ')" \
    "$(printf '%s\n' "$registered" | wc -l | tr -d ' ')"

  return "$failed"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  repo_root="${1:-}"
  if [ -z "$repo_root" ]; then
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
      printf 'check-step-body-extractor-roster: not a git repository and no repo_root argument given\n' >&2
      exit 2
    }
  fi
  gaia_check_step_body_extractor_roster "$repo_root"
  exit $?
fi
