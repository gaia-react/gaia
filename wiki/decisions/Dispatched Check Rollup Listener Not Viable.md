---
type: decision
status: active
priority: 2
date: 2026-05-26
created: 2026-05-26
updated: 2026-05-26
tags: [decision, ci, audit, github-actions]
---

# Decision: Dispatched-Check Rollup Stamping via `workflow_run` Listener Is Not Viable

A `workflow_run`-triggered listener that mirrors GITHUB_TOKEN-dispatched check runs into the PR's `statusCheckRollup` does not work. GitHub Actions suppresses `workflow_run` events for runs whose chain of triggering events traces back to `GITHUB_TOKEN`, so a listener watching for `workflow_run: completed` on `Chromatic` / `Tests` never receives events for the dispatched runs it was designed to mirror.

## The architecture that does not work

```
code-review-audit (audit step, GITHUB_TOKEN)
  → gh workflow run Chromatic --ref <pr-branch>
       → Chromatic runs on PR HEAD, completes
            → ❌ workflow_run: completed event NOT fired downstream
            → ❌ stamp-dispatched-checks listener never invoked
```

The listener fires for `push`- and `pull_request`-triggered Chromatic / Tests completions (since those events are user-attributed), but those completions already enter the rollup natively — there is nothing to mirror in that case. For the case the listener was meant to handle (GITHUB_TOKEN-attributed dispatched runs), the listener is never invoked.

## Why the suppression exists

GitHub Actions blocks chained-event triggers from `GITHUB_TOKEN` to prevent infinite workflow recursion. The same recursion guard is the reason a `GITHUB_TOKEN` push does not fire `push` or `pull_request` events — the cause that motivated the audit's self-heal re-trigger work in the first place. `workflow_run` events from `GITHUB_TOKEN`-attributable runs are suppressed for the identical reason.

`workflow_dispatch` and `repository_dispatch` are the only documented exceptions that allow new runs to start from `GITHUB_TOKEN` — but the exception applies to **starting** the new run, not to **firing downstream `workflow_run` events when it completes**.

## What this means for the rollup-exclusion problem

The original problem stands open: `workflow_dispatch`-event check suites are excluded from `statusCheckRollup`. Branch protection blocks merges even when the dispatched runs pass. There is no listener-based workaround under `GITHUB_TOKEN`.

## Viable paths if the problem is re-attempted

- **In-loop polling inside `code-review-audit.yml`.** After dispatching each `retrigger_workflow`, the audit step polls each run until completion (`gh run watch` or a manual loop), then POSTs matching check runs itself via the Checks API. Same end-state, no listener required. Cost: longer audit wall-clock; the audit step holds the runner until every dispatched run finishes.
- **Switch the dispatch from `GITHUB_TOKEN` to a PAT or GitHub App token.** Runs become user-attributed; their completions fire `workflow_run` events normally. Cost: an additional secret to manage and rotate, plus the security surface of granting that token `workflow` scope.
- **Use Checks API stamping from the source workflows directly.** Each `retrigger_workflow` could add a `post-job` step that POSTs a duplicate check run to its own head SHA — but that runs under `GITHUB_TOKEN` too, so the same suppression argument may bite (needs verification before committing).

None of these is in scope yet. Branch protection remains a manual unblock step for self-healed PRs until one of them lands.

## Reference

- Verification fixture: the `test/verify-audit-retrigger` test branch fires the audit self-heal chain end-to-end. Dispatched `Chromatic` / `Tests` runs complete on the self-heal HEAD but do not propagate to a downstream `workflow_run` listener.
- Related: [[Code Review Audit CI]] for the dispatch half (still active — that half works).
