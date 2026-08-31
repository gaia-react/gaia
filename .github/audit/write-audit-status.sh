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
# which path produced it (gaia-react/gaia#1286). This script is the single copy.
#
# Usage:
#   write-audit-status.sh --sha <sha> --base <pr-base-sha> [--require-marker]
#   write-audit-status.sh --sha <sha> --force-pending <description>
#
# Two modes, because the call sites are two shapes and pretending
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
# Modifier, gated mode only. It qualifies the success path, which stand-down
# mode does not have, so passing it with --force-pending is refused rather than
# ignored:
#   --require-marker        Post nothing unless the frontend member's clean
#                           marker exists for the recomputed digest. The
#                           clean-no-push path's proven-clean check.
#
# Step outputs. When $GITHUB_OUTPUT is set this writes `members_pending`,
# `success_stamped`, `post_failed`, and, from the shared non-clobber read,
# `success_live` / `read_failed`, which the terminal comment steps read so they
# can never claim a stamp that did not happen. Callers with no `id:` simply have
# no one reading them.
#
# A REJECTED STATUS POST NEVER FAILS THE STEP, ON ANY PATH. The merge gate fails
# closed without help: nothing posted means the required GAIA-Audit context is
# absent, and an absent required check shuts the button exactly as a `pending`
# one does. So redding the job protects nothing, and it misattributes the
# failure -- the audit itself passed, and a red `code-review-audit` check says it
# did not. gaia-react/gaia#726 is the shape this prevents: an HTTP 422 on an
# unpushed sha turned an otherwise-clean audit red. Targeting the pushed head
# closed that particular 422, but a rate limit, a 5xx, or an auth blip rejects a
# POST the same way and is not closed by anything.
#
# The author's signal is `post_failed` instead, which the terminal comment steps
# report by name. That is the more diagnostic half of the trade: a red job buries
# its cause in a step log, and on the two skip paths it also SUPPRESSED the
# comment step, so the case most in need of an explanation produced none.
#
# `post_failed` covers BOTH posts, the success one and the pending one. It did
# not always: the pending POST swallowed its own rejection through a bare
# `|| true`, so on that path the comment steps read a non-empty `members_pending`
# and told the author the gate was pending when no pending status had been posted
# (gaia-react/gaia#1405). That was a wrong explanation rather than a wrong gate --
# it failed closed, and it self-healed once the dispatched members ran locally --
# but it is the same defect the ladders' SUCCESS_LIVE and READ_FAILED arms exist
# to prevent, so it gets the same answer.
#
# The two posts differ in what the author is then told, because IN GATED MODE a
# rejection on the PENDING path always co-occurs with a non-empty
# `members_pending`: that POST fires only under a non-empty `pending`, which
# gated mode has already published as `members_pending`. So the terminal ladders
# report the combined state in one sentence -- the members only a local run can
# clear, AND the rejection that means nothing was posted -- instead of picking
# one of the two facts.
#
# STAND-DOWN MODE IS THE EXCEPTION, and it is inert rather than handled. That
# mode never emits `members_pending` at all (there are no members to resolve),
# so a rejection there publishes `post_failed` beside an EMPTY one. No ladder
# ever sees that pair: the sole stand-down call site carries no `id:`, so
# nothing reads its outputs. The unqualified claim would be wrong; the gated
# qualification is what makes it true, and the missing `id:` is what makes the
# stand-down case harmless.
#
# Two suites cover this script: one drives it directly for its argument
# contract, and one executes every call site as the workflow runs them.

set -eu

usage() {
  echo "usage: write-audit-status.sh --sha <sha> (--base <sha> | --force-pending <desc>) [--require-marker]" >&2
}

sha=""
base=""
force_pending=""
have_base=0
have_force_pending=0
require_marker=0

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

# The modifier qualifies the SUCCESS path, and stand-down mode has none: it can
# only ever post pending. Accepting it there would be a well-spelled,
# meaningless combination sitting next to a parser that refuses a misspelled
# one, so refuse it on the same fail-closed grounds. This also keeps the flag
# space honest -- every combination the parser accepts is one a caller uses.
if [ "$have_force_pending" -eq 1 ] && [ "$require_marker" -eq 1 ]; then
  echo "write-audit-status: --require-marker qualifies the success path and is meaningless with --force-pending" >&2
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
# 1b. The repo root, resolved ONCE, for every sibling this script reaches.
#
# Inline in a workflow `run:` body the CWD is the workspace root, so a bare
# `.github/audit/...` and a root-anchored one are the same path. Standalone they
# are not, and resolving the digest against `--show-toplevel` while looking its
# marker up relative to CWD would compute one tree's digest and read another
# tree's marker -- the same silent divergence between two copies of one fact
# that this file exists to remove, one level up. Same spelling the siblings use
# (gate-pending-members.sh, resolve-audit-base.sh).
#
# No guard on an empty result, deliberately. It stays byte-for-byte the current
# behavior: an empty root makes the sibling lookups miss and the digest
# recompute fail, so gated mode still reds the step and stand-down mode still
# reaches `decline`. A guard here would convert one of those into the other.
# ---------------------------------------------------------------------------
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"

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
  pending="$(bash "$repo_root/.github/audit/gate-pending-members.sh" --base "$base")"
  emit "members_pending=${pending}"
  # The tree is a plain data field in the success description. Resolved here,
  # in the position the gated callers already resolved it, so a bad sha
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
if ! frontend_digest="$(bash "$repo_root/.gaia/scripts/audit-member-digest.sh" \
    --root "$repo_root" --member code-audit-frontend \
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
  marker="$repo_root/.gaia/local/audit/${frontend_digest}.ok"
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
  bash "$repo_root/.github/audit/audit-success-present.sh" "${sha}" "${frontend_digest}" || _live=$?

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
  #
  # But not SILENT. `post_failed` is published here for the same reason the
  # success path publishes it: without it the terminal comment steps read a
  # non-empty `members_pending` and tell the author "GAIA-Audit is pending" about
  # a status that was never posted. The gate is shut either way, so this is a
  # wrong explanation rather than a wrong gate -- and a wrong explanation is
  # exactly what the SUCCESS_LIVE and READ_FAILED arms of those ladders already
  # exist to prevent, on claims those paths merely could not verify. This one is
  # known false, so the same rule applies with more force.
  #
  # IN GATED MODE it always co-occurs with a non-empty `members_pending`: this
  # branch runs only under a non-empty `pending`, and gated mode emitted
  # `members_pending` from that same value. So the ladders combine the two rather
  # than choosing between them, and hoisting their post_failed arm above
  # members_pending would discard the half only a LOCAL member run can act on.
  #
  # In STAND-DOWN mode `pending` is the forced description and `members_pending`
  # was never emitted, so this `post_failed` would stand alone. Nothing reads it:
  # that call site carries no `id:`. The emit is published either way rather than
  # gated on the mode, because a conditional emit would be a second rule to keep
  # in step with the one `id:` that decides whether anyone is listening.
  if ! gh api "repos/${GITHUB_REPOSITORY}/statuses/${sha}" \
      --method POST \
      --field state=pending \
      --field context=GAIA-Audit \
      --field description="${desc}"; then
    echo "code-review-audit: the pending GAIA-Audit status POST to ${sha} was rejected; nothing posted, and the merge gate stays shut. Run the dispatched member(s) locally to clear it." >&2
    emit "post_failed=true"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# 6. Nothing pending: stamp success.
#
# A MISSING .gaia/VERSION reaches here identically to an empty one: the shared
# normalizer answers "" for both by contract and exits 0, so neither shape trips
# `set -e` and both land on the guard below having posted NOTHING. The version
# this stamps is the same literal every reader compares against because both
# sides derive it here.
# ---------------------------------------------------------------------------
version_lib="$repo_root/.claude/hooks/lib/gaia-version.sh"
if [ -f "$version_lib" ]; then
  # shellcheck source=/dev/null
  . "$version_lib" 2>/dev/null || true
fi
if ! command -v gaia_read_version >/dev/null 2>&1; then
  decline "version normalizer unavailable (.claude/hooks/lib/gaia-version.sh); skipping status."
fi

version="$(gaia_read_version "$repo_root/.gaia/VERSION")"
if [ -z "$version" ]; then
  decline ".gaia/VERSION missing/empty; skipping status."
fi

if ! gh api "repos/${GITHUB_REPOSITORY}/statuses/${sha}" \
    --method POST \
    --field state=success \
    --field context=GAIA-Audit \
    --field description="${version} ${frontend_digest} ${tree_sha}"; then
  # `post_failed` distinguishes THIS no-stamp from the ones `decline` reports
  # above, and the two are different repairs: re-run the workflow to re-POST,
  # versus restore the .gaia/VERSION or the digest engine the earlier exits are
  # about. Emitted before decline so the more specific fact is available to a
  # reader that also sees `success_stamped=false`.
  emit "post_failed=true"
  decline "GAIA-Audit status POST to ${sha} was rejected; nothing stamped and the merge gate stays shut. Re-run this workflow, or run a local audit, to stamp it."
fi

# Last, so a POST that returned non-zero cannot reach it. The reject branch above
# publishes `success_stamped=false` explicitly through `decline` rather than
# leaning on this ordering, so the claim survives a reshape that moves it.
emit "success_stamped=true"
