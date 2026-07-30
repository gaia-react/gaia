# PR Merge

## Verify your own work before the first dispatch

**The audit gate is a merge gate, not an incremental check.** Each dispatched member costs 60-110k tokens and several minutes per round, so a defect it finds that you could have found locally spends the budget that should go to what you cannot see yourself. Two or three rounds spent discovering your own shape bugs is the failure mode.

Before dispatching any member: run the deterministic checks covering what you changed (the relevant test suites, the linters for the languages you touched, the Quality Gate when it applies), and write the adversarial fixtures an auditor would ask for. For new parsing or matching logic, one fixture per shape it might mishandle. Reach for a real parser rather than hand-rolling one for a format that has one.
<!-- gaia:maintainer-only:start -->
In this repo that means the bats suites for the paths touched and `bash .gaia/tests/shell-lint.sh`; run bats through `bash .gaia/scripts/bats5.sh` so local matches CI's bash 5.
<!-- gaia:maintainer-only:end -->

**For a guard, prove it can fail.** A guard whose assertions cannot be made to fire reports green in exactly the case it exists to catch. Break what it watches on purpose, confirm the failure, restore. This is per mechanism, not per file: a suite that goes red when you loosen one threshold says nothing about a second mechanism added in the same change, so mutate each one separately. An assertion that recomputes the logic under test in its own body is testing its own arithmetic, not the code.

Green locally is the entry condition for dispatch, not a milestone you pass once. Re-run it after the last edit, including edits made to prose or docs after the suites went green.

If you catch yourself thinking "the audit will tell me if this is wrong", that thought names the fixture to write.

## Merging

Before any `gh pr merge`, **read `wiki/concepts/PR Merge Workflow.md` and complete its audit + marker handshake; do not merge from memory.** Resolve the dispatched Code Audit Team members first with `bash .gaia/scripts/resolve-audit-spawn.sh` and spawn each member it names (zero, one, or several), rather than assuming a single auditor. After the call, verify `gh pr view <N> --json state` returns `"MERGED"` before any local cleanup (`git checkout main`, `git branch -D`, `git fetch --prune`), `gh pr merge` can fail when checks are pending or branch protection blocks; proceeding to cleanup leaves a deleted local branch with the PR still OPEN. Use `--auto` (not `--admin`) when branch protection rejects with "base branch policy prohibits the merge".

<!-- gaia:maintainer-only:start -->
Maintainer-only: that workflow's **CHANGELOG gate** is mandatory. Before merging, decide whether the change needs a `## [Unreleased]` entry in `CHANGELOG.md` and, if so, land it on the PR branch first. Re-check on every merge, including PRs resumed across sessions; an entry is only as good as the commit that lands it. Write any entry at Keep a Changelog altitude: 1-3 sentences on what changed and why it matters, not implementation mechanics (no file/function/flag-internals narration). Keep action-required markers with their literal commands, breaking/migration substance plus a pointer, behavior-changing flag names, adopter-relevant version/engine bumps, and a truthful who/why; deep detail belongs in the PR/commit.
<!-- gaia:maintainer-only:end -->
