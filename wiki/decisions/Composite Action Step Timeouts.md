---
type: decision
status: active
priority: 3
date: 2026-09-07
created: 2026-09-07
updated: 2026-09-08
tags: [decision, ci, github-actions]
---

# Decision: Composite Action Step Timeouts

Most workflows that provision Node route through the shared composite action `.github/actions/gaia-setup-node`; the action's own docblock names the callers deliberately left out and why. A step-level `timeout-minutes` on the caller bounds the whole composite; without one, a stalled pnpm registry fetch or Node tarball download runs until the owning job's own cap fires. The job then reds with a generic job-timeout message attributed to no step, which on a declared-required context blocks a pull request with a failure pointing at nothing, and the obvious next move (re-run) doesn't diagnose it.

## Rule

Every call site that `uses: ./.github/actions/gaia-setup-node` carries its own `timeout-minutes`, set strictly under its job's own cap so the step fires first and names the install rather than the job. The value is sized against that step's measured warm-cache runtime, not against the job's headroom: five minutes where the step installs the whole workspace, three where it only provisions Node and warms the pnpm store.

Both halves are enforced upstream, in GAIA's own CI: every `gaia-setup-node` call site carries a cap, and that cap sits under its job's. The enforcing checks derive their subject set from the tracked tree rather than a hand-named list, so a call site added anywhere they cover fails a check rather than going unnoticed. An adopter clone does not run them, so a call site added there is held to this rule by the rule alone.

The composite retries a failed pnpm install once, pausing 15 seconds between attempts. A caller's cap therefore has to cover two install attempts plus the pause, not one. The composite's own docblock enumerates what its provisioning covers and already sizes the pause against the leanest caller's cap; call sites point at the composite for that set rather than keeping a local copy that goes stale the next time the composite's provisioning changes.

<!-- gaia:maintainer-only:start -->
The enforcing checks live in `.gaia/tests/lib/`; each names its own subject set.
<!-- gaia:maintainer-only:end -->

`tests.yml` and `chromatic.yml` are shipped, adopter-facing workflows, so this bound reaches an adopter's own CI on their next `/update-gaia`; an adopter whose install is larger than the measured baseline may need to raise the cap.

## Provisioning attribution vs. recovery

GAIA declines to replace `pnpm/action-setup` with hand-rolled provisioning, which a per-attempt timeout could otherwise bound below the caller's cap. The one recorded stall degraded at least six provisioning legs across two concurrent runs over roughly seven and a half minutes, a sustained condition that a second attempt starting fifteen to sixty seconds later re-enters rather than escapes. Two of the degraded legs cleared at exactly sixty-one seconds, so a bound sized near sixty seconds would have aborted those attempts rather than rescued them. A bounded retry therefore buys **attribution**, which step is named when the lane reds, not **recovery**: a stall still consumes the caller's whole budget at every surface GAIA provisions pnpm.

The composite's own pause-then-retry construct exists only at composite call sites. The two workflow steps that call `pnpm/action-setup` directly carry a step-level cap of their own but none of the composite's retry construct, so a stall there names the step without a bounded second attempt. Wherever provisioning newly routes through the composite, that routing reaches an already-installed adopter's own CI only on their next `/setup-gaia` re-render, never through `/update-gaia`.

This decision reopens on either a second recorded stall event, or a base rate established from raw job logs. Absence of recorded stalls is not a measured base rate: zero events across the unbiased sample bounds the per-run rate no tighter than roughly thirteen percent.

<!-- gaia:maintainer-only:start -->
## Pairs with

- [[Sharded CI Test Matrix]]: a different, job-level `timeout-minutes` ceiling on the dispatched-audit path; that page's zero-headroom arithmetic is unrelated to this per-step composite-action bound.
<!-- gaia:maintainer-only:end -->
