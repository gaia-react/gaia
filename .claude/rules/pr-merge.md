# PR Merge

## Verify your own work before the first dispatch

**The audit gate is a merge gate, not an incremental check.** Each dispatched member costs 60-110k tokens and several minutes per round, so a defect it finds that you could have found locally spends the budget that should go to what you cannot see yourself. Two or three rounds spent discovering your own shape bugs is the failure mode.

Before dispatching any member: run the deterministic checks covering what you changed (the relevant bats suites, `bash .gaia/tests/shell-lint.sh`, the Quality Gate when it applies), and write the adversarial fixtures an auditor would ask for. For new parsing or matching logic, one fixture per shape it might mishandle. For a guard, a deliberate break proving it fails when it should, because a guard that cannot fail is the defect. Reach for a real parser rather than hand-rolling one for a format that has one. If you catch yourself thinking "the audit will tell me if this is wrong", that thought names the fixture to write.

## Merging

Before any `gh pr merge`, **read `wiki/concepts/PR Merge Workflow.md` and complete its audit + marker handshake; do not merge from memory.** Resolve the dispatched Code Audit Team members first with `bash .gaia/scripts/resolve-audit-spawn.sh` and spawn each member it names (zero, one, or several), rather than assuming a single auditor. After the call, verify `gh pr view <N> --json state` returns `"MERGED"` before any local cleanup (`git checkout main`, `git branch -D`, `git fetch --prune`), `gh pr merge` can fail when checks are pending or branch protection blocks; proceeding to cleanup leaves a deleted local branch with the PR still OPEN. Use `--auto` (not `--admin`) when branch protection rejects with "base branch policy prohibits the merge".

<!-- gaia:maintainer-only:start -->
Maintainer-only: that workflow's **CHANGELOG gate** is mandatory. Before merging, decide whether the change needs a `## [Unreleased]` entry in `CHANGELOG.md` and, if so, land it on the PR branch first. Re-check on every merge, including PRs resumed across sessions; an entry is only as good as the commit that lands it. Write any entry at Keep a Changelog altitude: 1-3 sentences on what changed and why it matters, not implementation mechanics (no file/function/flag-internals narration). Keep action-required markers with their literal commands, breaking/migration substance plus a pointer, behavior-changing flag names, adopter-relevant version/engine bumps, and a truthful who/why; deep detail belongs in the PR/commit.
<!-- gaia:maintainer-only:end -->
