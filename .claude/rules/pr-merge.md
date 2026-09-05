# PR Merge

## Verify your own work before the first dispatch

**The audit gate is a merge gate, not an incremental check.** Read `wiki/concepts/PR Merge Workflow.md` (`#### Before the first dispatch: verify your own work`) before the first member dispatch: run the deterministic checks and adversarial fixtures it describes, and prove every new guard can fail before relying on it; do not merge-gate from memory.
<!-- gaia:maintainer-only:start -->
In this repo that means the bats suites for the paths touched, plus `bash .gaia/tests/whole-tree-invariants.sh` for the checks no path can select, shell-lint and the shard partition among them; run bats the way `.claude/rules/bats-assertions.md` prescribes, so local matches CI's bash 5.
<!-- gaia:maintainer-only:end -->

## Merging

Before any `gh pr merge`, **read `wiki/concepts/PR Merge Workflow.md` and complete its audit + marker handshake; do not merge from memory.** Resolve the dispatched Code Audit Team members first with `bash .gaia/scripts/resolve-audit-spawn.sh` and spawn each member it names (zero, one, or several), rather than assuming a single auditor. After the call, verify `gh pr view <N> --json state` returns `"MERGED"` before any local cleanup (`git checkout main`, `git branch -D`, `git fetch --prune`), `gh pr merge` can fail when checks are pending or branch protection blocks; proceeding to cleanup leaves a deleted local branch with the PR still OPEN. Use `--auto` (not `--admin`) when branch protection rejects with "base branch policy prohibits the merge". When disposing an out-of-scope or cross-remit finding before the merge, apply the eligibility rule in that workflow page's `#### Cross-remit findings` section rather than a remembered summary of it; that rule carries more terms than a one-sentence aside can hold, and the section owns it.

**Three audit rounds per session, then stop.** The re-audit loop is capped: dispatch at most three rounds in one session, fix and push the third round's findings, then emit a continuation prompt and end the run rather than dispatching a fourth. A clean round, or one carrying only accepted residuals, still merges at any round number. The cap never licenses a merge without clearance, and it is not routed around through a subagent, a fork, or a session this one starts. A fourth dispatch wave is machine-denied by `.claude/hooks/block-fourth-audit-round.sh`, not merely prescribed here. Terms and what the handoff prompt must carry: that workflow page's `#### The three-round session cap`.

<!-- gaia:maintainer-only:start -->
Maintainer-only: that workflow's **CHANGELOG gate** is mandatory. Before merging, decide whether the change needs a `## [Unreleased]` entry in `CHANGELOG.md` and, if so, land it on the PR branch first. Re-check on every merge, including PRs resumed across sessions; an entry is only as good as the commit that lands it. Write any entry at Keep a Changelog altitude: 1-3 sentences on what changed and why it matters, not implementation mechanics (no file/function/flag-internals narration). Keep action-required markers with their literal commands, breaking/migration substance plus a pointer, behavior-changing flag names, adopter-relevant version/engine bumps, and a truthful who/why; deep detail belongs in the PR/commit.
<!-- gaia:maintainer-only:end -->
