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

`.claude/hooks/issue-claim-release.sh` fires on a tool call whose **first** command is a `gh pr merge` naming this repository, and strips `in-progress` from every issue the merged pull request's body closes, matching GitHub's own closing keywords. It confirms the pull request actually reads `MERGED` before touching any label. A merge rejected by branch protection or a pending check leaves the work in flight, and releasing the claim on that rejection would hand a live ticket to a second worker while the first is still mid-review.

Every qualifier in that first sentence is a condition the release can fail, and each failure is silent: the merge lands, the issue closes, and the claim stays. Known limitations below enumerates them.

## Division of labor

`/gaia-debt` owns the claim, the race handling, and the stale-claim reconcile for `tech-debt` issues; see [[Audit Disposition and Debt Fix]] for how it claims each selected member before the security screen and before isolation. The always-on rule covers every other issue and does not duplicate any of that.

## Known limitations

Automatic release is the common path, not a guarantee. Seven shapes leave the claim set, and every one of them is released by hand. `.claude/rules/issue-claim.md` is the operational source, and carries the repair for each; this section is the concept-level census, and the two are meant to be readable side by side in the same order.

**A merge run anywhere but here.** GitHub's web interface, a plain terminal, another person, or automation reaches no hook at all, because no tool call fires. The claim stays exactly as it was.

**A pull request that closes nothing by keyword.** The release reads GitHub's closing keywords out of the pull request body. A merged pull request that only references an issue (`Refs #<n>`), or names none at all, leaves the claim set; a claimed issue needs a real closing reference to release automatically.

**A merge queued with `--auto`.** It lands server-side after the command returns. The hook requires `MERGED` at the moment it runs, sees an open pull request, and never runs again, because the merge that follows fires no tool call.

**A merge that is not the first command in its tool call.** The hook reads one tool call and requires the merge to lead it, so anything ahead of the merge releases nothing. It abstains rather than guessing, and the asymmetry is the point: an abstention costs a label removed by hand, while a guess costs a label stripped off an issue in this repository that the merge never closed. The same abstention covers the spellings it can only read approximately, a clustered single-dash shorthand and a `--repo` naming another repository or another host.

**A merge that names no pull request and deletes its branch.** `--delete-branch` checks out the default branch before the command returns, and the hook runs after that, so a merge carrying no pull-request number sends the hook to look up the current branch's pull request and find none. This is the shape the merge gate's own denial text offers as always readable, so the two guards pull in opposite directions here. Naming the number satisfies both.

**A controlled stop that abandons the work.** Stopping before the merge leaves the claim on an issue nobody is working; releasing it is part of stopping.

**A session that dies mid-fix.** Nothing reconciles a stale claim on a non-`tech-debt` issue. `/gaia-debt` reconciles its own claims; a claim left by any other work is released by hand.

See [[GitHub Labels]] for the registry entry and its color and axis.
