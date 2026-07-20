#!/bin/bash
# PreToolUse Bash hook: DENY `gh pr create` when a file this branch newly ships
# has no answer in the committed .gaia/manifest.json, so the maintainer learns
# it before pushing instead of after the "Distribution Audit" CI job goes red.
#
# This is a LOCAL PRE-FLIGHT for .github/workflows/distribution-audit-pr.yml and
# deliberately enforces the same rule in two places. That duplication is the
# point, not an oversight:
#
#   CI-only feedback is too late to be cheap. The CI job can only speak after a
#   push, a PR, and a runner boot; by then the maintainer has context-switched
#   away and pays a full round trip to answer a question the working tree could
#   have answered instantly. This is the same reasoning that makes the pre-merge
#   Code Audit Team default to a LOCAL producer rather than CI (see
#   wiki/concepts/PR Merge Workflow.md, "Marker-first"): the deterministic gate
#   stays authoritative in CI, and a local copy of it buys fast feedback.
#
#   CI remains the authority. This hook is advisory-in-effect: it fails open on
#   every uncertainty (see below), so it can only ever be a cheaper way to find
#   out what CI would have told you. It cannot pass something CI would fail,
#   because it never writes a marker or clears any gate; it only denies earlier.
#
# Recorded here rather than left implicit because an unexplained two-place rule
# reads to a later audit as accidental drift. See wiki/decisions/Deliberate
# Configuration Asymmetries.md for the sibling cases.
#
# WHY `gh pr create` AND NOT `git push`: push-time would catch this one round
# earlier, but it fires on every work-in-progress push to a branch that has no
# PR and may never get one, where an unanswered manifest entry is not yet a
# question anybody owes an answer to. PR-create is the first moment the shipping
# surface is actually being proposed, so it is the first moment the question is
# real.
#
# ADOPTER POSTURE: neither this script nor its registration reaches an adopter
# clone. The script is release-excluded, and it is registered only in
# .claude/settings.local.json, which is gitignored. Both halves are required and
# neither is sufficient alone:
#
#   - The script cannot ship. It names `.gaia/cli/gaia-maintainer` and
#     `.github/workflows/distribution-audit-pr.yml`, both release-excluded, and
#     `.claude/**` is in scope for the `maintainer-paths` and
#     `excluded-workflow-ref` leak-checks, so a shipped copy fails the release
#     build outright. Independently of that, an adopter-side agent reading it
#     would infer a release manifest, a distribution boundary, and a
#     /distribution-audit command that do not exist on their clone, and act on
#     that inference.
#
#   - The registration cannot live in .claude/settings.json. That file is
#     manifest class `shared` and reaches adopter clones, so a registration
#     there would point every adopter's PreToolUse/Bash chain at a file they do
#     not have. `json-strip` addresses object keys by dot-notation and cannot
#     remove one element from the hooks[] array, so there is no scrub path that
#     would let the registration ship and be stripped.
#
# The cost of that pairing is that the gate is maintainer-machine-local: it does
# not travel to another maintainer clone until the scrub engine can strip a
# single array element. The inertness guard below stays regardless, so a
# maintainer checkout with no built binary is also a clean no-op.
#
# FAIL-OPEN on every uncertainty: no maintainer binary (adopter clone), no jq,
# no git, an unresolvable base ref, a non-JSON report, or any exit >= 2 from the
# checker. The gate exists to save a round trip, never to block a maintainer out
# of their own PR; CI is the authority that actually fails the build.

# -e is intentionally omitted: we must not abort before writing the deny JSON.
# All error-prone commands are individually guarded (|| true, 2>/dev/null).
set -uo pipefail

input=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)
[ "$tool_name" = "Bash" ] || exit 0

# Avoid the name `command`: it would shadow bash's `command` builtin and break
# later `command -v ...` guards.
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)

# Match `gh pr create` only when it appears in command position: at the very
# start, or immediately after a shell separator. Mirrors the anchoring in
# pr-merge-audit-check.sh and audit-disposition-check.sh. This keeps mid-line
# mentions (`git commit -m "gh pr create"`, `echo "run gh pr create later"`)
# from tripping the gate.
#
# It does NOT exempt a heredoc body: newline is in the separator set, so a
# heredoc line that begins with `gh pr create` matches like a real invocation.
# That is a deliberate trade, not an oversight. Dropping newline would exempt
# heredocs but also stop matching the common multi-line shape
# (`git add -A\ngh pr create --fill`), which is a real invocation the gate must
# see. Telling the two apart needs shell parsing, and the failure it would
# prevent is a spurious deny on a fail-open advisory gate whose message names
# the remedy, so the cheap anchoring is the proportionate answer.
sep_re=$'(\\&\\&|;|\\|\\||\\||\n)[[:space:]]*gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)'
start_re='^[[:space:]]*gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)'
if [[ "$cmd" =~ $start_re ]]; then
  : # match at command start
elif [[ "$cmd" =~ $sep_re ]]; then
  : # match after a shell separator (incl. newline)
else
  exit 0
fi

# Repo-scope: a `gh pr create` aimed at a different repo has no bearing on this
# repo's distribution boundary, so allow it. Mirrors the sibling merge gates.
[ -f .claude/hooks/lib/repo-scope.sh ] && . .claude/hooks/lib/repo-scope.sh
if type cmd_targets_foreign_repo >/dev/null 2>&1 \
   && cmd_targets_foreign_repo "$cmd"; then
  exit 0
fi

# Adopter clone (or a maintainer checkout with no built binary): nothing to
# check. This is the inertness guard the ADOPTER POSTURE note above depends on.
maintainer_bin=".gaia/cli/gaia-maintainer"
[ -x "$maintainer_bin" ] || exit 0

command -v git >/dev/null 2>&1 || exit 0

deny() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

# Resolve the base ref the PR would target: an explicit --base/-B on the command
# line wins, otherwise the repo's default branch, otherwise main. Prefer the
# remote-tracking ref so the comparison matches what CI will see.
# The flag must sit at a word boundary, and `gh` is a pflag CLI, so all three
# shorthand forms are valid: `--base X`, `--base=X`, and for the single-letter
# alias also `-BX` with no separator at all. Two patterns rather than one,
# because the empty separator is only safe on the `-B` branch: allowing it on
# `--base` would make `--base-ref` match with `-ref` as the captured value.
#
# Parse only the text AFTER the matched `gh pr create`. A base flag belongs to
# that invocation, so an earlier command in the same chain must not donate one.
# This matters most for the no-separator shorthand: without the narrowing,
# `grep -B2 foo file && gh pr create --fill` captures `2` as the base ref.
# Narrowing is also why the `-B` empty separator is safe to allow at all.
cmd_tail="${cmd#*gh pr create}"
#
# KNOWN RESIDUAL, accepted: within that tail this is still a regex, not an
# argument parse, so a literal `--base <ref>` written inside this invocation's
# own `--body` prose still matches. Word-boundary anchoring does not help there,
# the body text has a space in front of the flag like a real argument does.
# Accepted because the gate is fail-open and advisory, and CI is the authority
# that catches what this misses. Be precise about the direction of that failure:
# a wrong base can under-report as easily as over-report. Resolving a narrower
# base than the real one shrinks the three-dot changed set and can miss a
# genuine offender, so the realistic worst case is a spurious allow, not only a
# spurious deny. What the residual cannot do is write a wrong answer anywhere;
# the hook never records a decision, it only declines to raise one.
base_long_re='(^|[[:space:]])--base([[:space:]]+|=)([^[:space:]]+)'
base_short_re='(^|[[:space:]])-B[[:space:]]*=?[[:space:]]*([^[:space:]]+)'
base_ref=""
if [[ "$cmd_tail" =~ $base_long_re ]]; then
  base_ref="${BASH_REMATCH[3]}"
elif [[ "$cmd_tail" =~ $base_short_re ]]; then
  base_ref="${BASH_REMATCH[2]}"
fi
if [ -n "$base_ref" ]; then
  # `--base "release/2.0"` captures the quotes literally; git would not resolve
  # them. Strip one balanced surrounding pair of either kind.
  base_ref="${base_ref%\"}"
  base_ref="${base_ref#\"}"
  base_ref="${base_ref%\'}"
  base_ref="${base_ref#\'}"
fi
if [ -z "$base_ref" ]; then
  base_ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's#^origin/##' || true)
fi
[ -n "$base_ref" ] || base_ref="main"

base_rev=""
for candidate in "origin/${base_ref}" "$base_ref"; do
  if git rev-parse --verify --quiet "$candidate" >/dev/null 2>&1; then
    base_rev="$candidate"
    break
  fi
done
# An unresolvable base means we cannot know this branch's own changed set.
[ -n "$base_rev" ] || exit 0

# Files this branch adds or modifies on the head side. Three-dot compares from
# the point HEAD diverged from base, so only this branch's own changes count.
# Deletions are excluded; even if one slipped through it could never intersect
# `missing`, which is built from a git ls-files walk of the head tree. Matches
# distribution-audit-pr.yml exactly so the two gates never disagree.
changed=$(git diff --name-only --diff-filter=ACMR "${base_rev}...HEAD" 2>/dev/null \
  | LC_ALL=C sort -u || true)
[ -n "$changed" ] || exit 0

# `--check` is read-only and exits non-zero on ANY drift (a pre-existing backlog
# included), so a non-zero exit is data, not failure. Exit >= 2 is a genuine
# git/filesystem failure: fail open rather than deny on a broken checker.
check_rc=0
check_json=$("$maintainer_bin" release manifest --check --json 2>/dev/null) || check_rc=$?
[ "$check_rc" -lt 2 ] || exit 0
printf '%s' "$check_json" | jq -e . >/dev/null 2>&1 || exit 0

# `missing` = every classified, non-excluded, tracked file the committed
# manifest has never acknowledged. Intersect with this branch's changed set so
# the gate holds the PR to exactly the shipping surface it introduces, never a
# backlog inherited from earlier merges.
missing=$(printf '%s' "$check_json" \
  | jq -r '(.missing // [])[].file' 2>/dev/null \
  | LC_ALL=C sort -u || true)
[ -n "$missing" ] || exit 0

offenders=$(LC_ALL=C comm -12 \
  <(printf '%s\n' "$missing") \
  <(printf '%s\n' "$changed") 2>/dev/null || true)
[ -n "$offenders" ] || exit 0

count=$(printf '%s\n' "$offenders" | grep -c '.' || true)
offender_list=$(printf '%s\n' "$offenders" | sed 's/^/  - /')

deny "Distribution pre-flight: ${count} newly-shipping file(s) on this branch have no answer in .gaia/manifest.json.

${offender_list}

Every file that would newly reach adopters needs an explicit ship-or-withhold decision before it lands. Pushing without one turns the 'Distribution Audit' CI job red after the fact; this catches it now, locally, with no network round trip.

To unblock:
  1. Run /distribution-audit and answer ship-or-withhold for each file above.
  2. Commit the regenerated .gaia/manifest.json (and .gaia/release-exclude for
     any withheld file) to this branch.
  3. Retry gh pr create.

Landing the manifest answer first also keeps HEAD stable through the later audit-marker handshake (see wiki/concepts/PR Merge Workflow.md, step 1).

This gate mirrors .github/workflows/distribution-audit-pr.yml deliberately; see this hook's header for why the rule is enforced in both places."
