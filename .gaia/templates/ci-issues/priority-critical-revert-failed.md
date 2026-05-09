GAIA CI auto-revert FAILED for PR #${ORIGINAL_PR}. The bot has stopped
automated activity on this change and is asking for human intervention.

A revert PR (#${REVERT_PR}) was opened to undo PR #${ORIGINAL_PR}, but the
revert's own CI failed. Per the SPEC's hard-cap rule (one revert attempt per
original PR), no second revert will be attempted automatically.

Recovery options:
1. Investigate the original failure on `${MERGE_SHA}` and fix forward in a
   manual PR.
2. Manually merge the revert PR after fixing whatever made the revert's CI red.
3. Manually revert via `git revert ${MERGE_SHA}` on a local branch and open a
   PR yourself.

References:
- Original PR: #${ORIGINAL_PR} (${ORIGINAL_TITLE})
- Merge commit: ${MERGE_SHA}
- Failed post-merge run: ${FAILED_RUN_URL}
- Revert PR (failed): #${REVERT_PR}
- Failed revert run: ${REVERT_FAILED_RUN_URL}
- Workflow: ${WORKFLOW_NAME}

Until this issue is closed, the GAIA CI cron schedule for `${WORKFLOW_NAME}` is
not suppressed automatically — the next scheduled run will proceed normally on
its next cycle. The hard-cap rule applies only to the specific original PR;
unrelated runs continue.
