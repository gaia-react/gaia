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

## Resolution: in-loop polling and direct Checks API stamping

The audit workflow's `Re-trigger and stamp required checks on new HEAD` step forks one background poller per dispatched workflow. Each poller resolves the dispatched run id via the actions/runs API (filtered by `event=workflow_dispatch&branch=<pr-branch>` and `created_at >= dispatch_ts`), polls the run to completion, enumerates its jobs, and POSTs a matching check run per job to the self-heal HEAD via the Checks API.

Direct Checks API POSTs land in the PR's `statusCheckRollup` regardless of suite linkage — the same mechanism the audit's own `code-review-audit` stamp uses. Branch protection sees the stamped check runs and accepts the PR.

The empirical signature that distinguishes rollup-included from rollup-excluded check runs:

- API-direct check runs share a single per-(repo, head_sha, app) suite with `check_suite.head_branch=null` and land in the rollup.
- Dispatched-workflow check runs each carry their own suite with `check_suite.head_branch=<pr-branch>` and `check_suite.pull_requests=[]`; the rollup excludes them.

This avoids a separate listener workflow, a static list of source workflows to mirror, additional credentials, and per-source-workflow tail-job conventions. The cost is the audit step holds its runner for the slowest dispatched run. Polling is parallel across dispatched workflows so total wait tracks max-duration, not sum.

See [[Code Review Audit CI#Self-heal re-trigger]] for the shipped implementation.

## Other paths considered

- **Switch the dispatch from `GITHUB_TOKEN` to a PAT or GitHub App token.** Runs become user-attributed; their completions fire `workflow_run` events normally. Trades the polling cost for credential lifecycle: rotation, expiration handling, security review of granting `workflow` scope.
- **Use Checks API stamping from the source workflows directly.** Each `retrigger_workflow` adds a tail job that POSTs a duplicate check run under `GITHUB_TOKEN`. Works in theory (direct API POSTs are not subject to the recursion guard, only events are), but every entry adopters add to `retrigger_workflows` then needs the same tail-job convention added to the corresponding workflow file.

## Reference

- Verification fixture: the `test/verify-audit-retrigger` test branch fires the audit self-heal chain end-to-end. Both the original listener failure mode and the in-loop polling resolution were verified against this fixture.
- Related: [[Code Review Audit CI]] for the dispatch half.
