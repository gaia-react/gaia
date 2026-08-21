---
type: concept
status: active
created: 2026-08-21
updated: 2026-08-21
tags: [concept, github, workflow]
---

# Issue Claim

The `in-progress` label marks a GitHub issue as being worked right now. It spans every issue type, a bug, an enhancement, or a tech-debt drain, so two agents or two people never start the same ticket.

## Claim before isolation

Claiming happens before cutting a branch or a worktree, not after. The window the claim exists to close sits between picking the work and having a branch that names it; claiming later leaves that window open. `.claude/rules/issue-claim.md` covers the claim for any issue outside `/gaia-debt`'s own scope.

## Race behavior

An issue already carrying `in-progress` is held by someone else. The right move is to pick different work, not to race for it: the label is the coordination signal, and racing past it defeats the point of having one.

## Release

`.claude/hooks/issue-claim-release.sh` fires on `gh pr merge` and strips `in-progress` from every issue the merged pull request's body closes, matching GitHub's own closing keywords. It confirms the pull request actually reads `MERGED` before touching any label. A merge rejected by branch protection or a pending check leaves the work in flight, and releasing the claim on that rejection would hand a live ticket to a second worker while the first is still mid-review.

## Division of labor

`/gaia-debt` owns the claim, the race handling, and the stale-claim reconcile for `tech-debt` issues; see [[Audit Disposition and Debt Fix]] for how it claims each selected member before the security screen and before isolation. The always-on rule covers every other issue and does not duplicate any of that.

## Known limitations

The release reads GitHub's closing keywords out of the pull request body. A merged pull request that only references an issue (`Refs #<n>`), or names none at all, leaves the claim set; a claimed issue needs a real closing reference to release automatically.

Nothing reconciles a stale claim on a non-`tech-debt` issue after a session dies ungracefully. `/gaia-debt` reconciles its own claims; a claim left by any other work is released by hand.

See [[GitHub Labels]] for the registry entry and its color and axis.
