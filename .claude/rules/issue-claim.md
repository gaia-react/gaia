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

`.claude/hooks/issue-claim-release.sh` strips the claim automatically from every issue a merged pull request closes by keyword, so that path needs nothing from you. It is a `PostToolUse` hook on `Bash`, so what it sees is one tool call, and it acts only when the first command in that call is the merge itself: a second merge in the same call releases nothing. Seven paths need a hand:

- **A merge run anywhere but here.** GitHub's own web interface, a plain terminal, another person, or automation. No tool call fires, so no hook runs and the claim stays exactly as it was. Strip it by hand.

- **A pull request that does not close the issue with a keyword.** The hook reads GitHub's closing keywords out of the pull-request body, so a body that says `Refs #<n>`, or names no issue at all, releases nothing. Write a real closing reference (`Closes #<n>`) for any issue the branch claims, or strip the claim by hand after the merge.
- **A merge that lands server-side after the command returns.** `.claude/rules/pr-merge.md` prescribes `--auto` when branch protection blocks a direct merge, and that call returns while the pull request is still open. The hook requires `MERGED` within the short bounded window it re-reads the state over, and a queued merge lands far outside that window, so it sees `OPEN`, releases nothing, and never runs again: the merge that follows fires no tool call at all. Strip the claim by hand once the merge lands.
- **A merge that is not the first command in its tool call.** The hook reads the first command and requires it to be the merge; `<anything> && <merge>` releases nothing. What sits ahead of a merge decides how to read it, and reading that needs the shell's own semantics, so the hook stops rather than guessing: a wrong guess strips a label off an issue in this repository that the merge never closed. A merge naming another repository with `--repo` releases nothing for the same reason. The same stop covers the spellings the hook can only read approximately, each of which releases nothing: a clustered single-dash shorthand (`gh pr merge -sd <n>`), and a `--repo` carrying a host qualifier that is not this repository's host. Run the merge as its own command, which is what the merge workflow prescribes anyway, or strip the claim by hand afterwards.
- **A merge that names no pull request and deletes its branch.** `gh pr merge --squash --delete-branch`, with no number, is the spelling the merge gate's denial text offers as always readable, and it is the one shape that reaches the hook with nothing to look up. `--delete-branch` checks out the default branch before the command returns, and this hook runs after it, so its no-reference arm asks `gh pr view` for the current branch's pull request and is told there is none. It releases nothing, on a merge that landed, with no diagnostic anywhere. Name the number, `gh pr merge <n> --squash --delete-branch`, which the gate reads and which hands the hook a reference that does not depend on where HEAD ended up, or strip the claim by hand.
- **A controlled stop that abandons the work**, before the pull request merges. Strip the claim yourself: `gh issue edit <n> --remove-label in-progress`.
- **A stale claim** left by a session that died. `/gaia-debt` reconciles its own `tech-debt` claims; nothing reconciles the rest, so release those by hand.

## Scope

`/gaia-debt` owns the claim for `tech-debt` issues, including the race handling and the stale-claim reconcile documented in `.claude/skills/gaia/references/debt.md`. Do not duplicate any of that here. This rule covers every other issue.

Claim a `tech-debt` issue through `/gaia-debt` rather than by hand. Its stale-claim reconcile runs over every open `tech-debt` issue, not only the ones it claimed itself, and its liveness rule is written for work `/gaia-debt` drives. A hand-set claim worked outside that shape fails it once the grace passes, so the next drain releases the issue and can hand it to someone else. The rule itself lives in `.claude/skills/gaia/references/debt.md`, and is deliberately not copied here.
