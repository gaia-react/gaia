GAIA CI auto-revert in progress for PR #${ORIGINAL_PR}.

Post-merge CI on the merge commit `${MERGE_SHA}` failed. The bot has opened a
revert PR (#${REVERT_PR}) and enabled auto-merge.

If the revert's CI is also red, the bot will stop and escalate to a
`priority:critical` issue. No second revert is attempted.

- Original PR: #${ORIGINAL_PR} (${ORIGINAL_TITLE})
- Merge commit: ${MERGE_SHA}
- Failed run: ${FAILED_RUN_URL}
- Revert PR: #${REVERT_PR}
- Workflow: ${WORKFLOW_NAME}

If you want to investigate before the revert merges, you can hold the revert PR
by removing its `gaia-ci` label or closing it; the bot will treat that as a
revert failure and escalate.
