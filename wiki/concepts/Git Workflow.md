---
type: concept
status: active
created: 2026-04-21
updated: 2026-06-24
tags: [concept, git, workflow]
---

# Git Workflow

Two invariants, machine-enforced by `.claude/hooks/block-main-destructive-git.sh` (a PreToolUse `Bash` hook that short-circuits on any command whose command word is not `git`, so only real `git` invocations are evaluated). The hook emits `permissionDecision: "deny"` with a reason string, so Claude cannot bypass it without explicit user override.

The guard is **repo-scoped** via `.claude/hooks/lib/repo-scope.sh`: it governs this repo only. A `git` command positively aimed at a different checkout (`git -C <other>` or `cd <other> &&`) is allowed; that sibling repo's own policy applies there, not this one's. Scoping is fail-closed: any ambiguity still enforces.

## 1. Never commit directly to `main` or `master`

Always work on a feature branch. If HEAD is on `main`/`master`, create one first:

```bash
git switch -c <type>/<short-description>
```

Conventional prefixes in this repo: `feat/`, `fix/`, `chore/`, `refactor/`, `test/`, `wiki/`

## 2. Never force-push to `main` or `master`

No `--force`, `--force-with-lease`, or `-f` to `main`/`master`; upstream history is shared. Fix conflicts with a merge or rebase on the feature branch, then open a PR.

## Setup standdown

Both invariants above have one temporary, explicit exception. `/setup-gaia` provisions a greenfield repo by landing GAIA's own CI-install commit directly on the default branch: that commit has nothing to audit and the branch is not yet a collaboration surface. For that single commit+push it suspends the hook via a machine-local, gitignored sentinel `.gaia/local/setup-in-progress`, then removes it. The sentinel is honored only while fresh (mtime within 10 minutes), so a stale one left behind by a crashed setup self-heals and enforcement resumes on its own; it is gitignored, so it never rides into a clone. Resting state is fully enforcing.

## Splitting an already-staged tree into commits

A bare `git commit -m "..."` with no pathspec commits the entire index, not just the files staged by the most recent `git add`. When only some staged files belong in a commit, pass explicit pathspecs: `git commit -m "..." -- <file1> <file2>`. The `-m` flag must come before the `--`; `-- <paths> -m "msg"` makes git treat `-m` and the message itself as pathspecs, and the commit silently does nothing. Confirm with `git status --short` before and after any split-commit sequence to verify only the intended files landed.

See [[PR Merge Workflow]], [[Claude Hooks]].
