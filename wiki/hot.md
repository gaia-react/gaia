---
type: meta
title: Hot Cache
status: active
created: 2026-06-05
updated: 2026-06-05
tags: [meta, cache]
---

# Recent Context

## Last Updated

2026-06-05. SPEC-004 Policy-Memory Loop shipped (PRs #321, #322 merged to main).

## Active Threads

- None open. The Policy-Memory Loop is live: `code-review-audit` emits a stable
  `finding_class` per finding (schema-enforced) into its telemetry trailer and the
  CI PR comment; the TTL refresher tallies classes across the 90-day merged-PR
  window and raises a `Run /gaia-harden review (N)` statusline nudge at >=3 distinct
  PRs; `/gaia-harden` judges the lowest-context-weight form (deterministic check /
  skill / path-scoped prose rule) and drafts on approve, records machine-local
  declines, or defers, all under human gate; `/gaia-audit` prunes a promoted rule
  only on obsolescence/redundancy/supersession/duplication, never for non-recurrence.
  The CLI bundle is rebuilt so `harden-tally` / `harden-ledger` ship in the binary.
  See [[Policy-Memory Loop]].
- Open follow-up: widen the holistic/rule finding-class seed vocabulary as real
  recurrence data shows which classes the agent assigns reliably.
