# PR Merge

Before any `gh pr merge`, **read `wiki/concepts/PR Merge Workflow.md` and complete its audit + marker handshake; do not merge from memory.** After the call, verify `gh pr view <N> --json state` returns `"MERGED"` before any local cleanup (`git checkout main`, `git branch -D`, `git fetch --prune`), `gh pr merge` can fail when checks are pending or branch protection blocks; proceeding to cleanup leaves a deleted local branch with the PR still OPEN. Use `--auto` (not `--admin`) when branch protection rejects with "base branch policy prohibits the merge".

<!-- gaia:maintainer-only:start -->
Maintainer-only: that workflow's **CHANGELOG gate** is mandatory. Before merging, decide whether the change needs a `## [Unreleased]` entry in `CHANGELOG.md` and, if so, land it on the PR branch first. Re-check on every merge, including PRs resumed across sessions; an entry is only as good as the commit that lands it.
<!-- gaia:maintainer-only:end -->
