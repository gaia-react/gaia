---
type: decision
status: active
priority: 2
date: 2026-05-26
created: 2026-05-26
updated: 2026-05-26
tags: [decision, ci, audit, github-actions]
---

# Decision: Dispatched-Check Rollup via In-Loop Polling

The audit workflow's self-heal step dispatches required sibling workflows (e.g. Chromatic, Tests) on the self-heal HEAD via `workflow_dispatch` under `GITHUB_TOKEN`. Those dispatched runs complete, but their check suites carry an empty `pull_requests` link, so GitHub excludes them from `statusCheckRollup`. Branch protection reads the rollup, so dispatched runs alone never satisfy a required-check rule — the PR stays blocked even when every dispatched run is green.

The shipped resolution is in-loop polling with direct Checks API stamping.

## How it works

The audit workflow's `Re-trigger and stamp required checks on new HEAD` step forks one background poller per `retrigger_workflows` entry. Each poller:

1. Resolves the dispatched run id via the actions/runs API, filtered by `event=workflow_dispatch&branch=<pr-branch>` and `created_at >= dispatch_ts`.
2. Polls the run to completion (capped at 25 min; an internal failure logs a WARN rather than failing the step).
3. Enumerates the run's jobs.
4. POSTs a matching check run per job to the self-heal HEAD via the Checks API.

Direct Checks API POSTs land in the PR's `statusCheckRollup` regardless of suite linkage — the same mechanism the audit's own `code-review-audit` stamp uses. Branch protection sees the stamped check runs and accepts the PR.

The empirical signature distinguishing rollup-included from rollup-excluded check runs:

- API-direct check runs share a single per-(repo, head_sha, app) suite with `check_suite.head_branch=null` and land in the rollup.
- Dispatched-workflow check runs each carry their own suite with `check_suite.head_branch=<pr-branch>` and `check_suite.pull_requests=[]`; the rollup excludes them.

Polling runs parallel across dispatched workflows, so total wait time tracks the slowest dispatched run, not the sum. The audit step's `budget_seconds` plus the slowest dispatched run plus a small overhead must fit within the job-level `timeout-minutes: 60` cap.

See [[Code Review Audit CI#Self-heal re-trigger]] for the adopter-facing configuration surface.

## Why a `workflow_run`-event listener doesn't work

The obvious alternative is a `workflow_run`-triggered listener workflow that watches for `Chromatic` / `Tests` completions and mirrors them via the Checks API. That architecture fails:

```
code-review-audit (audit step, GITHUB_TOKEN)
  → gh workflow run Chromatic --ref <pr-branch>
       → Chromatic runs on PR HEAD, completes
            → workflow_run: completed event NOT fired downstream
            → stamp-dispatched-checks listener never invoked
```

GitHub Actions suppresses `workflow_run` events for runs whose chain of triggering events traces back to `GITHUB_TOKEN`. The suppression is the same recursion guard that blocks `push` and `pull_request` events from `GITHUB_TOKEN`-authored pushes — the reason the audit's self-heal re-trigger work exists in the first place.

The listener fires for `push`- and `pull_request`-triggered Chromatic / Tests completions (those events are user-attributed), but those completions already enter the rollup natively — there is nothing to mirror. For the case the listener was meant to handle (`GITHUB_TOKEN`-attributed dispatched runs), the listener is never invoked.

`workflow_dispatch` and `repository_dispatch` are the only documented exceptions allowing new runs to start from `GITHUB_TOKEN`, but the exception covers **starting** the run, not **firing downstream `workflow_run` events when it completes**.

## Alternatives considered

- **Switch the dispatch from `GITHUB_TOKEN` to a PAT or GitHub App token.** Runs become user-attributed and their completions fire `workflow_run` events normally. Trades the polling cost for credential lifecycle: rotation, expiration handling, security review of granting `workflow` scope.
- **Checks API stamping from the source workflows directly.** Each `retrigger_workflows` entry adds a tail job that POSTs a duplicate check run under `GITHUB_TOKEN`. Direct API POSTs are not subject to the recursion guard (only events are), so it works in theory — but every entry adopters add to `retrigger_workflows` then needs the same tail-job convention added to the corresponding workflow file.

## Reference

- Verification fixture: the `test/verify-audit-retrigger` test branch fires the audit self-heal chain end-to-end. Both the listener failure mode and the in-loop polling resolution are verified against this fixture.
- Related: [[Code Review Audit CI]] for the dispatch half.
