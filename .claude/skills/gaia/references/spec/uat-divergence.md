---
description: 'The cosmetic versus logical line for a rendered UAT spec, how it is enforced, how an executor reports a logical divergence, and how a SPEC is reopened.'
---

# UAT Divergence Policy

When an owning phase turns a red Playwright UAT spec green, the test body has to bind abstract user-acceptance language ("the user sees a confirmation") to concrete UI surface (selectors, button labels, copy strings, route paths). Some of that binding is editable; some of it is not. This rule names the line.

## Contract

- **Cosmetic divergence**: selector text, button label, accessible-name strings, copy, role names, URL slugs, layout-only assertions: **editable** by the implementer. The PO authored the UAT against an idealized UI; the implementer reconciles it with the shipped UI. Edits to cosmetic surface stay in the spec file and require no SPEC reopen.
- **Logical divergence**: the user flow, the success criteria, the error-handling branch, the asserted side effect, the precondition, the post-state: **forbidden**. If the implementation cannot satisfy the UAT's logic as written, the spec is NOT edited. The executor reports the divergence, the orchestrator halts, and the SPEC is reopened to refine the UAT (`## Reopen`). The render step then regenerates the spec from the corrected UAT.

## Enforcement

Three layers, each independent of the others:

1. **Deterministic divergence check.** `.gaia/scripts/spec/uat-divergence-check.sh` compares the contract comment of each rendered spec with the SPEC's UAT text. `uat-gate.sh` runs it at every owning-phase gate and before the audit, so a spec whose contract lines were edited blocks the commit. It never reads the test body, so a cosmetic edit never changes its verdict.
2. **Executor report.** An executor that needs a logical change does not make it. It reports the change under `## Reporting` and stops; the orchestrator halts the phase.
3. **Audit member.** The pre-merge audit member judges whether each test body still asserts its contract: a body can keep the contract comment intact and still stop asserting it.

Re-rendering after a reopen follows the digest embedded in each spec: an unedited spec is rewritten from the corrected UAT, an edited one comes back as a conflict the human resolves (`uat-write.md` `## Conflicts`).

## Reporting

An executor that finds a logical divergence adds this block to its `## Notes for orchestrator`, with the heading exactly as shown:

```
### Logical UAT divergence
UAT: <uat_id>
Category: <flow | success criteria | error-handling branch | asserted side effect | precondition | post-state>
Needed change: <one or two sentences>
```

## Reopen

A logical divergence is resolved by a SPEC reopen. `/gaia-spec` has no reopen entry, so the steps are manual edits, which the halted phase's `PROGRESS.md` block points here for:

1. Edit `SPEC.md` at its absolute, main-anchored path: set `status: reopened` and today's `updated:`, add a `## Reopen rationale` section (why the UAT cannot hold) and a `## UAT diff` section holding the pre-change UAT text verbatim, then change the UAT.
2. Run `bash .gaia/scripts/spec/lint.sh <SPEC.md path>` until it prints `{"ok":true,...}`. Its reopen check fails a `reopened` SPEC that lacks either section.
3. The human (not the orchestrator) updates the plan README's routing row when the change re-routes the UAT or moves its owning phase, and the owning task doc's acceptance criteria when they quoted the old text. The render step's routing validation fails loudly on a forgotten row.
4. Stash or discard the halted phase's uncommitted edits (resume refuses a dirty tree), then resume with the plan's `KICKOFF.md`. The render step re-renders the changed UAT; an edited spec comes back as a conflict.

The specs ledger row needs no change: its vocabulary has no reopened state, and the SPEC's frontmatter `status` carries it.
