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

## Release

`.claude/hooks/issue-claim-release.sh` releases the claim when a `gh pr merge <n>`, run as its own command in this session, lands a pull request whose body closes the issue by keyword (`Closes #<n>`); its header names the spellings it declines to read. Any other ending leaves the claim set, so strip it by hand: `gh issue edit <n> --remove-label in-progress`.

## Scope

`/gaia-debt` owns the claim for `tech-debt` issues, including the race handling and the stale-claim reconcile documented in `.claude/skills/gaia/references/debt.md`. Do not duplicate any of that here. This rule covers every other issue.

Claim a `tech-debt` issue through `/gaia-debt` rather than by hand. Its stale-claim reconcile runs over every open `tech-debt` issue, not only the ones it claimed itself, and its liveness rule is written for work `/gaia-debt` drives. A hand-set claim worked outside that shape fails it once the grace passes, so the next drain releases the issue and can hand it to someone else. The rule itself lives in `.claude/skills/gaia/references/debt.md`, and is deliberately not copied here.
