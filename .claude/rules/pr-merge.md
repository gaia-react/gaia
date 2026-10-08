# PR Merge

## Verify your own work before the first dispatch

**The audit gate is a merge gate, not an incremental check.** Read `wiki/concepts/PR Merge Workflow.md` (`#### Before the first dispatch: verify your own work`) before the first member dispatch: run the deterministic checks and adversarial fixtures it describes, and prove every new guard can fail before relying on it; do not merge-gate from memory.
<!-- gaia:maintainer-only:start -->
In this repo that means `bash .gaia/tests/verify-harness.sh branch`, the last step before the first member or `audit-loop-unit` dispatch: commit first (exit 3 means uncommitted tracked changes or a detached HEAD), and run it in the background with output redirected to a log, since it takes minutes. The dispatch is refused until it has passed for the current HEAD, so any commit after the pass needs a new pass. Each audit round's gate then runs `bash .gaia/tests/verify-harness.sh round`. Its bats steps run the way `.claude/rules/bats-assertions.md` prescribes, so local matches CI's bash 5.
<!-- gaia:maintainer-only:end -->

## Merging

Before any `gh pr merge`, **read `wiki/concepts/PR Merge Workflow.md` and complete its audit + marker handshake, then post the `GAIA-Audit` status yourself as its final step (`#### Posting the status last`); do not merge from memory.** Its `## Who audits: the dispatched member set` section owns which members owe a marker and how the audit loop unit runs them. After the merge call, wait with `bash .gaia/scripts/pr-wait-merge.sh --pr <N>` and run local cleanup only once it prints `MERGED`; `## Post-merge verification before cleanup` owns the rest, including `--auto` over `--admin`.

**The audit loop runs on its own until the branch checkpoint.** `.claude/hooks/audit-loop-bound.sh` enforces it, only a human's answer to its pinned question or a typed grant or accept line records a grant, and Claude never writes grants or loop state: `wiki/concepts/PR Merge Workflow.md`, `#### The branch checkpoint`.

<!-- gaia:maintainer-only:start -->
Maintainer-only: that workflow's **CHANGELOG gate** is mandatory. Before merging, decide whether the change needs a `## [Unreleased]` entry in `CHANGELOG.md` and, if so, land it on the PR branch first. Re-check on every merge, including PRs resumed across sessions; an entry is only as good as the commit that lands it. Write any entry at Keep a Changelog altitude: 1-3 sentences on what changed and why it matters, not implementation mechanics (no file/function/flag-internals narration). Keep action-required markers with their literal commands, breaking/migration substance plus a pointer, behavior-changing flag names, adopter-relevant version/engine bumps, and a truthful who/why; deep detail belongs in the PR/commit.
<!-- gaia:maintainer-only:end -->
