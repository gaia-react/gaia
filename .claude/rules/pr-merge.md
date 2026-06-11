# PR Merge

Before any `gh pr merge`, **read `wiki/concepts/PR Merge Workflow.md` and complete its audit + marker handshake; do not merge from memory.** After the call, verify `gh pr view <N> --json state` returns `"MERGED"` before any local cleanup (`git checkout main`, `git branch -D`, `git fetch --prune`), `gh pr merge` can fail when checks are pending or branch protection blocks; proceeding to cleanup leaves a deleted local branch with the PR still OPEN. Use `--auto` (not `--admin`) when branch protection rejects with "base branch policy prohibits the merge".
