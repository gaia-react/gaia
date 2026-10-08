# /gaia-debt: post-merge worktree cleanup

The worktree-mode cleanup of `/gaia-debt`. `debt.md` routes here from its `## Drive the PR to merge` once the merge wait returns `MERGED` and the fix ran in worktree mode.

### Post-merge worktree cleanup (worktree-mode fixes only)

1. The merge wait in `## Drive the PR to merge` in `debt.md` (`bash .gaia/scripts/pr-wait-merge.sh --pr <N>`) returned `MERGED`, and only that verdict reaches this procedure. A run arriving here any other way (a resume) runs that wait first and proceeds only on exit 0; otherwise surface and stop.
2. **Isolation-context check** (below). If running inside an isolated subagent context, emit the continuation prompt and stop; do not call `ExitWorktree`.
3. Otherwise call `ExitWorktree({action: "remove", discard_changes: true})` directly. `discard_changes: true` is safe: the squash-merge absorbed every commit on the worktree branch, but those commits are not ancestors of `main`, so the runtime would otherwise refuse; the merged-state confirmation in step 1 proves the work is preserved.
4. Delete the renamed branch as `.claude/skills/gaia/references/isolation.md` (`### Post-merge removal`) prescribes.
5. Report one line: `worktree discarded; PR #<N> squash-merged as <short-sha>`. (Run ends here; see `## Cost record (run end)` in `debt.md`.)

Never call `ExitWorktree` first and treat its refusal as the discard trigger; the merged-state confirmation is the primary signal.

### Isolation-context detection (worktree-mode fixes only)

The runtime refuses `ExitWorktree` from an agent dispatched with `isolation: "worktree"` or a `cwd` override (refusal text: `ExitWorktree cannot be called from a subagent with a cwd override`). `/gaia-debt` normally runs on the user's own main thread, so the direct in-session `ExitWorktree` path above is the common case; still detect the automation case:

- **Primary signal:** the skill was invoked via `Agent(...)` with `isolation: "worktree"` (dispatch was a sub-agent task and cwd is a worktree path under `.claude/worktrees/`).
- **Fallback:** if uncertain, attempt `ExitWorktree({action: "remove", discard_changes: true})`; if the response contains `cannot be called from a subagent`, treat it as never-issued (a refusal, not a destructive action), branch into the continuation-prompt path, and stop.

When detected, emit this copy-paste continuation prompt to the user and stop:

    The worktree at <ABSOLUTE-PATH-TO-WORKTREE> is ready to discard.
    PR #<N> squash-merged as <short-sha>. From a shell at
    <ABSOLUTE-PATH-TO-MAIN-CHECKOUT>, run:

        git worktree remove --force <ABSOLUTE-PATH-TO-WORKTREE>
        git branch -D <branch-name>   # if it still exists

(Run ends here; see `## Cost record (run end)` in `debt.md`.)

Do not emit an `ExitWorktree({...})` call in this continuation prompt. `ExitWorktree` only operates on a worktree created by `EnterWorktree` in the current session: from a fresh session it is a no-op on a prior-session worktree, and its schema requires `action` and rejects a `worktree` parameter. A plain `git worktree remove --force` is the correct session-independent cleanup. This matches `plan.md`'s Isolation-context detection block, whose continuation prompt emits the same session-independent shell cleanup.
