# In-Progress Issue Claim

`in-progress` says a GitHub issue is being worked right now. It is not tech-debt-specific: it applies to every issue type, so two agents or two people never start the same ticket.

## Claim before isolation

Before cutting a branch or a worktree for work that closes a GitHub issue, read the issue's labels:

```bash
gh issue view <n> --json labels --jq '[.labels[].name]'
```

Already carrying `in-progress` means someone else holds it. Say so and pick different work rather than racing. Otherwise claim it, then proceed:

```bash
gh issue edit <n> --add-label in-progress
```

The window the claim exists to close is the one between picking the work and having a branch that names it, so claiming after isolation closes nothing.

## Release on merge, and on abandonment

`.claude/hooks/issue-claim-release.sh` strips the claim automatically from every issue a merged pull request closes by keyword, so that path needs nothing from you. Three paths do:

- **A pull request that does not close the issue with a keyword.** The hook reads GitHub's closing keywords out of the pull-request body, so a body that says `Refs #<n>`, or names no issue at all, releases nothing. Write a real closing reference (`Closes #<n>`) for any issue the branch claims, or strip the claim by hand after the merge.
- **A controlled stop that abandons the work**, before the pull request merges. Strip the claim yourself: `gh issue edit <n> --remove-label in-progress`.
- **A stale claim** left by a session that died. `/gaia-debt` reconciles its own `tech-debt` claims; nothing reconciles the rest, so release those by hand.

## Scope

`/gaia-debt` owns the claim for `tech-debt` issues, including the race handling and the stale-claim reconcile documented in `.claude/skills/gaia/references/debt.md`. Do not duplicate any of that here. This rule covers every other issue.
