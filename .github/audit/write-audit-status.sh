#!/usr/bin/env bash
#
# Write the terminal GAIA-Audit commit status for one sha.
#
# THE FAIL-CLOSED RULE THIS FILE OWNS: never post a status, pending or success,
# on a digest we could not recompute, and never overwrite a live success we
# cannot see. It used to exist in five independent copies across
# .github/workflows/code-review-audit.yml -- one per terminal path -- so a
# correction landed on one and silently left the others stale, and because each
# copy guards a path a given PR may never exercise, the divergence survived CI
# indefinitely and surfaced as one status meaning different things depending on
# which path produced it (#1286). This script is the single copy.
#
# Usage:
#   write-audit-status.sh --sha <sha> --base <pr-base-sha> [--require-marker]
#                         [--success-post-non-fatal]
#   write-audit-status.sh --sha <sha> --force-pending <description>
#
# Two modes, because the five call sites are two shapes and pretending
# otherwise would mean a flag that turns off half the script:
#
#   GATED (--base)          Resolve the co-dispatched members CI cannot clear.
#                           Any pending member means `pending`; none means
#                           `success`. Four call sites.
#   STAND-DOWN (--force-pending)
#                           Never post success; post the given description as
#                           `pending`. The local-mode stand-down, where CI runs
#                           no audit at all, so there is nothing to clear.
#
# Modifiers, gated mode only. Both qualify the success path, which stand-down
# mode does not have, so passing either with --force-pending is refused rather
# than ignored:
#   --require-marker            Post nothing unless the frontend member's clean
#                               marker exists for the recomputed digest. The
#                               clean-no-push path's proven-clean check.
#   --success-post-non-fatal    Log instead of failing when the success POST is
#                               rejected. See "POST fatality" below.
#
# Step outputs. When $GITHUB_OUTPUT is set this writes `members_pending`,
# `success_stamped`, and (on a stand-down) `success_live` / `read_failed`, which
# the terminal comment step reads so it can never claim a stamp that did not
# happen. Callers with no `id:` simply have no one reading them.
#
# POST FATALITY IS A PARAMETER, NOT A POLICY, AND THAT IS DELIBERATE. The four
# success writers do not agree today and neither unification is behavior-
# preserving: the two skip paths' `success_stamped` ordering depends on a bare
# POST failing the step under `set -e`, while the clean-no-push path's
# non-fatality is half the fix for #726 (an HTTP 422 on an unpushed sha turning
# an otherwise clean audit red). Consolidating the writers must not silently
# pick a winner, so the divergence is carried as a flag and pinned per path by
# this repo's bats suites. Whether the four SHOULD agree is a real question and
# a separate one.
#
# Two suites cover this script: one drives it directly for its argument
# contract, and one executes all five call sites as the workflow runs them.

set -eu

usage() {
  echo "usage: write-audit-status.sh --sha <sha> (--base <sha> | --force-pending <desc>) [--require-marker] [--success-post-non-fatal]" >&2
}

sha=""
base=""
force_pending=""
have_base=0
have_force_pending=0
require_marker=0
success_post_non_fatal=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --sha)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      sha="$2"; shift 2 ;;
    --base)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      base="$2"; have_base=1; shift 2 ;;
    --force-pending)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      force_pending="$2"; have_force_pending=1; shift 2 ;;
    --require-marker)
      require_marker=1; shift ;;
    --success-post-non-fatal)
      success_post_non_fatal=1; shift ;;
    *)
      # STOP on an unrecognized argument rather than carrying on with a
      # half-understood invocation. This script decides whether a merge gate
      # opens; a typo'd flag must not silently become a different decision.
      echo "write-audit-status: unrecognized argument '$1'" >&2
      usage
      exit 2 ;;
  esac
done

# The two modes are exclusive and one is required. Exit 2, not 0: an
# ill-formed invocation is a bug in the workflow, and failing the step is the
# fail-closed answer (no status posted means the required check stays absent
# and the merge button stays shut).
if [ "$(( have_base + have_force_pending ))" -ne 1 ]; then
  echo "write-audit-status: exactly one of --base / --force-pending is required" >&2
  usage
  exit 2
fi

# An EMPTY --force-pending is not "stand down with no description", it is a
# stand-down that would fall through to the success branch and stamp the gate
# green. Refuse it rather than let a caller's unset variable open the gate.
if [ "$have_force_pending" -eq 1 ] && [ -z "$force_pending" ]; then
  echo "write-audit-status: --force-pending requires a non-empty description" >&2
  exit 2
fi

# Both modifiers qualify the SUCCESS path, and stand-down mode has none: it can
# only ever post pending. Accepting them there would be a well-spelled,
# meaningless combination sitting next to a parser that refuses a misspelled
# one, so refuse it on the same fail-closed grounds. This also keeps the flag
# space honest -- every combination the parser accepts is one a caller uses.
if [ "$have_force_pending" -eq 1 ] \
  && { [ "$require_marker" -eq 1 ] || [ "$success_post_non_fatal" -eq 1 ]; }; then
  echo "write-audit-status: --require-marker / --success-post-non-fatal qualify the success path and are meaningless with --force-pending" >&2
  exit 2
fi

# Publish a step output when running under Actions. No-op elsewhere, so the
# script is directly testable outside a runner.
emit() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s\n' "$1" >> "$GITHUB_OUTPUT"
  fi
}

# Decline to stamp, for a stated reason. Every fail-closed exit in this script
# is the same two facts -- say why, and record that nothing was stamped -- and
# writing them out per site is how one of them eventually drifts, which is the
# class of defect this file exists to remove. Exit 0, not non-zero: declining is
# a decision, not an error, and it already fails CLOSED because an absent
# required check blocks the merge just as a `pending` one does.
decline() {
  echo "code-review-audit: $1" >&2
  emit "success_stamped=false"
  exit 0
}

# ---------------------------------------------------------------------------
# 1. A usable target sha.
#
# Only the self-heal push path can arrive with an empty one: its sha comes from
# steps.push-fixes.outputs.audit_sha, which is unset when push-fixes resolved
# none. The other four take github.event.pull_request.head.sha, which the event
# always carries.
# ---------------------------------------------------------------------------
if [ -z "$sha" ]; then
  echo "code-review-audit: no audit_sha to stamp; skipping status." >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Which members CI cannot clear.
#
# Gate on the member SET, not on marker files: CI runs code-audit-frontend
# alone and every specialized member clears locally, so no maintainer marker
# can exist in this runner's workspace to look up. gate-pending-members.sh
# carries the full rationale and fails open, loudly, on an unusable resolver.
#
# The base is the FULL-PR base, never the incremental audit base: membership is
# a function of the whole PR diff (see that script's "Full-PR scope").
#
# Resolved before the digest so `members_pending` is published even when the
# digest recompute then fails -- the terminal comment step reads it, and the
# two skip paths already ordered it this way.
# ---------------------------------------------------------------------------
if [ "$have_base" -eq 1 ]; then
  pending="$(bash .github/audit/gate-pending-members.sh --base "$base")"
  emit "members_pending=${pending}"
  # The tree is a plain data field in the success description. Resolved here,
  # in the position the four gated callers already resolved it, so a bad sha
  # keeps failing the step exactly where it does today.
  tree_sha="$(git rev-parse "${sha}^{tree}")"
  ctx="members pending ${pending}"
else
  # Stand-down mode: pending by construction, so there is nothing to resolve
  # and no success description to build a tree for.
  pending="$force_pending"
  ctx="local mode"
fi

# ---------------------------------------------------------------------------
# 3. The frontend member's content digest (C1), recomputed for the exact sha
#    being stamped.
#
# FAIL CLOSED. The digest is the marker's identity: it keys the clean-marker
# lookup, it keys the non-clobber read, and it is what the success description
# vouches for. A status posted without it would vouch for content nothing
# verified.
# ---------------------------------------------------------------------------
if ! frontend_digest="$(bash .gaia/scripts/audit-member-digest.sh \
    --root "$(git rev-parse --show-toplevel)" --member code-audit-frontend \
    --ref "${sha}")"; then
  if [ "$have_base" -eq 1 ]; then
    decline "could not recompute the frontend digest for ${sha}; skipping status."
  else
    decline "could not recompute the frontend digest for ${sha}; standing down."
  fi
fi

# ---------------------------------------------------------------------------
# 4. Proven-clean guard, for the caller that has no push to prove it.
#
# The audit agent writes .gaia/local/audit/<digest>.ok ONLY when the review is
# clean, and never while findings remain. A dirty audit reaches the clean-no-push
# path too (it pushed nothing), so its absent marker is what keeps the merge
# blocked. Same artifact the merge hook trusts as its first accepted signal;
# gitignored, so it exists only in this runner's workspace and only for this run.
# ---------------------------------------------------------------------------
if [ "$require_marker" -eq 1 ]; then
  marker=".gaia/local/audit/${frontend_digest}.ok"
  if [ ! -f "$marker" ]; then
    decline "clean marker ${marker} absent; audit not proven clean, not stamping."
  fi
fi

# ---------------------------------------------------------------------------
# 5. The pending POST, and the read that keeps it from clobbering a success.
#
# A GitHub commit status has NO compare-and-set: for a given context the newest
# write wins outright. CI runs the default member alone, so it cannot clear a
# co-dispatched specialized member and correctly declines to post success. But
# the LOCAL member-aware producer (.claude/hooks/post-audit-status.sh) posts
# `success` once EVERY dispatched member has cleared, and nothing sequences the
# two writers. An unconditional `pending` landing last overwrites a legitimate
# `success`: the required check reverts to pending, `gh pr merge` is rejected by
# branch protection, and nothing re-posts, so the gate stays shut until a human
# notices. Any PR whose dispatched set includes a member CI cannot run reaches
# this path, so it is a routine shape, not an edge case. The workflow also
# re-fires on labeled/unlabeled against the SAME head sha with no new push,
# which is how the local-mode stand-down hits it hardest.
#
# So: skip the pending POST when a GAIA-Audit `success` is already the LIVE
# status on this sha AND carries THIS EXACT FRONTEND DIGEST. Such a success
# means every dispatched member has already cleared this content. A success
# naming a DIFFERENT digest is correctly ignored (the digest is the marker's
# identity), and a sha nobody has cleared has no such success, so this fails
# closed in every direction.
#
# Residual race, deliberately accepted: if the local POST lands between this
# read and the write below, `pending` still wins and the gate stays shut until
# the producer is re-run. Sub-second, and it fails CLOSED.
#
# audit-success-present.sh owns the read: 0 = a success for this digest IS live,
# 1 = definitively not, 2 = could NOT ask. TEST FOR A DEFINITIVE 1, never for
# "not 0 and not 2". The exit space is OPEN -- 127 when the file is absent or
# unreadable, a signal death, some code a future version adds -- and each of
# those is MORE unanswerable than a 2, not less. Enumerating the stand-down
# codes lets every unenumerated one fall through to the POST, silently restoring
# the clobber on exactly the runs where the guard is broken. Inverting the test
# makes the stand-down the default and the POST the exception. Standing down
# still fails CLOSED: an absent required check blocks the merge just as a
# pending one does.
# ---------------------------------------------------------------------------
if [ -n "$pending" ]; then
  # Hoisted above the guard: this branch stamps no success on any exit below,
  # so `false` is honest for all of them. Under-claiming is the safe direction;
  # over-claiming a stamp is the failure this output exists to prevent.
  emit "success_stamped=false"

  _live=0
  bash .github/audit/audit-success-present.sh "${sha}" "${frontend_digest}" || _live=$?

  if [ "$_live" -eq 0 ]; then
    echo "code-review-audit: ${ctx}, but a GAIA-Audit success for frontend digest ${frontend_digest} is already live; not clobbering it with pending." >&2
    emit "success_live=true"
    exit 0
  fi
  if [ "$_live" -ne 1 ]; then
    echo "code-review-audit: ${ctx}, but the current GAIA-Audit status could not be read (guard exit ${_live}); standing down rather than risk clobbering a success we cannot see. The gate still fails closed." >&2
    emit "read_failed=true"
    exit 0
  fi

  if [ "$have_base" -eq 1 ]; then
    echo "code-review-audit: ${ctx}; posting pending, not success." >&2
    # GitHub caps a status description at 140 chars; truncate so a large roster
    # cannot 422 the POST.
    desc="$(printf 'members pending: %s' "$pending" | cut -c1-140)"
  else
    echo "code-review-audit: ${ctx}; posting pending." >&2
    # The stand-down's description deliberately carries NO
    # "<version> <digest> <tree>" cleared shape -- a fixed sentinel that cannot
    # match any real digest -- so even a state-blind reader cannot mistake it
    # for cleared. Defense in depth behind the state-aware readers.
    desc="$force_pending"
  fi

  # Non-fatal: if this POST fails no status lands, the required check stays
  # unfulfilled, and the button stays shut. Fail-safe in every direction, so a
  # transient API error must not also red the job.
  gh api "repos/${GITHUB_REPOSITORY}/statuses/${sha}" \
    --method POST \
    --field state=pending \
    --field context=GAIA-Audit \
    --field description="${desc}" || true
  exit 0
fi

# ---------------------------------------------------------------------------
# 6. Nothing pending: stamp success.
#
# A MISSING .gaia/VERSION reaches here identically to an empty one: the read is
# a PIPELINE, so a failed redirect still leaves awk exiting 0 on no input and
# the substitution yields "". Neither shape trips `set -e`, so both land on the
# guard below having posted NOTHING.
# ---------------------------------------------------------------------------
version="$(tr -d '\r' < .gaia/VERSION | awk 'NF{print; exit}')"
version="${version#"${version%%[![:space:]]*}"}"
version="${version%"${version##*[![:space:]]}"}"
if [ -z "$version" ]; then
  decline ".gaia/VERSION missing/empty; skipping status."
fi

if [ "$success_post_non_fatal" -eq 1 ]; then
  if ! gh api "repos/${GITHUB_REPOSITORY}/statuses/${sha}" \
      --method POST \
      --field state=success \
      --field context=GAIA-Audit \
      --field description="${version} ${frontend_digest} ${tree_sha}"; then
    decline "GAIA-Audit status POST to ${sha} failed (non-fatal); local merge path will re-stamp."
  fi
else
  gh api "repos/${GITHUB_REPOSITORY}/statuses/${sha}" \
    --method POST \
    --field state=success \
    --field context=GAIA-Audit \
    --field description="${version} ${frontend_digest} ${tree_sha}"
fi

# Last, so a POST that returned non-zero records as no-stamp: the bare `gh api`
# above fails the step under `set -e`, but an output written first would outlive
# a later reshape that tolerated the failure.
emit "success_stamped=true"
