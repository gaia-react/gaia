# 23-hook-root-from-process-cwd

**Path**: `.claude/hooks/block-worktree-path-mismatch.sh`
**Line**: 41

## Title

The guard derives the checkout it protects from its own process working directory
instead of the directory the hook payload names.

## Failure mode

The script sets its root with `git rev-parse --show-toplevel` run in whatever directory
the hook process happens to start in, while the payload it is handed carries a `cwd`
field naming the session's actual checkout. When the hook process starts outside any
repository, the `rev-parse` fails, the root is empty, and every later comparison against
it succeeds trivially: the guard permits every write it exists to deny, and it does so
silently, because an empty root is indistinguishable from a matching one at the
comparison site.

## Verified by

Invoked the hook from a directory outside the repository with a payload naming a real
worktree path and a write target in a different worktree; the guard exited 0 and allowed
the write. Invoked identically from inside the repository and it denied.

## Suggested fix

Read the root from the payload's `cwd` field, and fail loudly when that field is absent
rather than falling through to the ambient directory.
