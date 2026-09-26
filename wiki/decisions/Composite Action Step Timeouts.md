---
type: decision
status: active
priority: 3
date: 2026-09-07
created: 2026-09-07
updated: 2026-09-15
tags: [decision, ci, github-actions]
---

# Decision: Composite Action Step Timeouts

Most workflows that provision Node route through the shared composite action `.github/actions/gaia-setup-node`; the action's own docblock names the callers deliberately left out and why. The composite's own inner steps carry no cap and cannot, because a composite action's steps take no `timeout-minutes` at all, so whatever bounds a stalled pnpm registry fetch or Node tarball download has to sit on the caller.

## Rule

A Node-provisioning step, whether it `uses:` the composite or calls `actions/setup-node` directly, is bounded by its owning job's `timeout-minutes`. A stalled fetch runs until that cap fires, and the job reds with a generic job-timeout message rather than one naming the install. The job cap keeps every run bounded and loud; a step-level cap would buy only the name of the step that stalled.

A workflow may still give a provisioning step its own cap, set strictly under its job's so it fires first and names the install. That is a per-workflow choice, not a rule, and no check enforces it.

`tests.yml` and `chromatic.yml` are shipped, adopter-facing workflows that bound their install through the job cap alone, so an adopter whose install is larger than the measured baseline may need to raise that job's cap.

## Provisioning attribution vs. recovery

GAIA declines to replace `pnpm/action-setup` with hand-rolled provisioning, which a per-attempt timeout could otherwise bound below the caller's cap. The one recorded stall degraded at least six provisioning legs across two concurrent runs over roughly seven and a half minutes, a sustained condition that a second attempt starting fifteen to sixty seconds later re-enters rather than escapes. Two of the degraded legs cleared at exactly sixty-one seconds, so a bound sized near sixty seconds would have aborted those attempts rather than rescued them. A bounded retry therefore buys **attribution**, which step is named when the lane reds, not **recovery**: a stall still consumes the caller's whole budget at every surface GAIA provisions pnpm.

Wherever provisioning newly routes through the composite, that routing reaches an already-installed adopter's own CI only on their next `/setup-gaia` re-render, never through `/update-gaia`.

This decision reopens on either a second recorded stall event, or a base rate established from raw job logs. Absence of recorded stalls is not a measured base rate: zero events across the unbiased sample bounds the per-run rate no tighter than roughly thirteen percent.

<!-- gaia:maintainer-only:start -->
## Pairs with

- [[Sharded CI Test Matrix]]: a different, job-level `timeout-minutes` ceiling on the dispatched-audit path; that page's zero-headroom arithmetic is unrelated to this composite-action bound.
<!-- gaia:maintainer-only:end -->
