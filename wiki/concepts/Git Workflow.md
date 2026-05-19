---
type: concept
status: active
created: 2026-04-21
updated: 2026-05-19
tags: [concept, git, workflow]
---

# Git Workflow

Two invariants, machine-enforced by `.claude/hooks/block-main-destructive-git.sh` (PreToolUse `Bash` hook with `if: Bash(git *)`). The hook emits `permissionDecision: "deny"` with a reason string, so Claude cannot bypass it without explicit user override.

The guard is **repo-scoped** via `.claude/hooks/lib/repo-scope.sh`: it governs this repo only. A `git` command positively aimed at a different checkout (`git -C <other>` or `cd <other> &&`) is allowed — that sibling repo's own policy applies there, not this one's. Scoping is fail-closed: any ambiguity still enforces.

## 1. Never commit directly to `main` or `master`

Always work on a feature branch. If HEAD is on `main`/`master`, create one first:

```bash
git switch -c <type>/<short-description>
```

Conventional prefixes in this repo: `feat/`, `fix/`, `chore/`, `refactor/`, `test/`, `wiki/`

## 2. Never force-push to `main` or `master`

No `--force`, `--force-with-lease`, or `-f` to `main`/`master` — upstream history is shared. Fix conflicts with a merge or rebase on the feature branch, then open a PR.

See [[PR Merge Workflow]], [[Claude Hooks]].
