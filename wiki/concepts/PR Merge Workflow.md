---
type: concept
status: active
created: 2026-04-20
updated: 2026-05-10
tags: [concept, ci, review]
---

# PR Merge Workflow

Mandatory before any `gh pr merge`. Machine-enforced by `.claude/hooks/pr-merge-audit-check.sh`, which denies `gh pr merge` calls when no `code-review-audit` marker exists for the current HEAD SHA.

## Four-step protocol

### 1. Run code-review-audit

Spawn the agent on the PR's changes:

```
Task(
  subagent_type="code-review-audit",
  prompt="Review all changes in the current branch compared to main. Identify security vulnerabilities, performance issues, code smells, anti-patterns, and refactoring opportunities."
)
```

### 2. Fix all issues

- Fix every Critical Issue and every Important Issue the audit identifies.
- Re-run linting and type checking after fixes.
- Stage, commit, and push the fixes — HEAD must move so the next audit runs against the fixed tree.
- Re-spawn the audit agent on the new HEAD until it reports clean.

### 3. Marker handshake

The audit agent writes `.gaia/local/audit/<HEAD-sha>.ok` only on a clean pass (no Critical Issues, every Important Issue addressed in the working tree). The hook gates `gh pr merge` on the presence of that marker for the exact commit being merged. Knip / react-doctor advisories and Suggestions never block marker emission.

If the agent declines to write the marker, the report names what remains unaddressed; resolve those, commit, push, re-spawn.

### 4. Merge

Once the marker exists for HEAD, run `gh pr merge`. The hook short-circuits to allow the call.

## Post-merge verification before cleanup

`gh pr merge` can fail without aborting the rest of a script — branch protection ("base branch policy prohibits the merge"), pending CI checks, missing `--auto` for queued merges, or auth issues. Proceeding to local cleanup (`git checkout main`, `git branch -D <pr-branch>`, `git fetch --prune`) before confirming the merge actually succeeded leaves the local branch deleted while the PR is still OPEN. Recoverable via `git checkout -b <branch> origin/<branch>` while the remote ref still exists, but it's avoidable churn.

The safe pattern after any `gh pr merge`:

```bash
gh pr merge <N> --squash --delete-branch [--auto]
for i in 1 2 3 4 5; do
  state=$(gh pr view <N> --json state -q .state)
  [ "$state" = "MERGED" ] && break
  sleep 30
done
[ "$state" = "MERGED" ] || { echo "merge did not complete"; exit 1; }
git checkout main && git pull origin main
git branch -D <pr-branch>  # force needed for squash (orphaned commits)
git fetch --prune origin
```

**`--auto` vs `--admin`:** when `gh pr merge` rejects with "base branch policy prohibits the merge", the right escape is `--auto` — it queues the merge and GitHub completes it once checks pass. Never reach for `--admin` to bypass branch protection without explicit permission; it removes the safety the policy exists to provide.

## Local-sync failure mode

When `gh pr merge` exits with `fatal: 'main' is already used by worktree at <path>`, **the GitHub-side merge has already succeeded**. The local checkout step is what failed, not the merge itself. Confirm with:

```
gh pr view <N> --json state
```

If `state == "MERGED"`, do NOT retry the merge. Treat it as merged, run any post-merge steps (wiki-sync, spec-close, etc.), and resolve the local worktree conflict separately. Retrying compounds the problem and can produce a duplicate squash on a non-existent branch.

## No exceptions

- Never skip the audit, even for "small" PRs. The hook denies the merge.
- Never hand-write a marker file to bypass the gate. The agent owns marker emission.
- If a doc-only PR genuinely does not warrant an audit, run the agent anyway — it will report no findings and write the marker quickly.

See [[Code Review Audit Agent]], [[Quality Gate]], [[Git Workflow]].
