---
type: concept
title: Policy-Memory Loop
status: active
created: 2026-06-05
updated: 2026-06-05
tags: [concept, claude, audit, self-improvement, governance]
---

# Policy-Memory Loop

The Policy-Memory Loop turns a recurring code-review finding into a durable, human-approved, path-scoped rule, prune-first and add-only by exception. It keeps GAIA's auto-loaded config from ratcheting heavier over time: a lesson becomes permanent, but its context weight stays bounded by mandatory path-scoping, never trimmed by deletion. Nothing is authored or activated unattended.

## The loop end to end

1. **Emission contract.** [[Code Review Audit Agent]] tags every eligible finding with a stable `finding_class` and a `severity`. Oracle buckets use tool ids verbatim (`react-doctor/...`, `axe/...`, `knip/...`, `cve/...`); holistic and rule-subagent buckets draw from a constrained vocabulary. A finding with no stable class is not emitted as a countable finding, the schema rejects free-text drift. Recurrence counts only `error` and `warning`; `suggestion` is ineligible.
2. **PR substrate.** The pull request is the durable record, not a committed sidecar. CI posts a machine-readable finding block in its PR comment; local runs emit the same fields through the telemetry trailer. The cross-machine signal lives on GitHub, read back via `gh`.
3. **TTL tally.** A background refresher recomputes, each TTL, how many distinct PRs carry each `finding_class` (warning-floor) across a rolling 90-day window. It drops classes already promoted (a rule exists) or locally declined without fresh evidence, and writes a candidate count to the statusline cache. The tally is an ephemeral projection: nothing is staged, an un-acted pattern decays by ageing out of the window.
4. **Statusline nudge.** When the candidate count is above zero, the statusline shows a `Run /gaia-harden review (N)` segment, alongside the `/update-deps` and `/update-gaia` indicators and under the same worktree + setup-complete suppression.
5. **Judge the form.** `/gaia-harden review` judges the lowest-context-weight form that fits the finding (deterministic check, skill, or path-scoped prose rule) and whether to edit an existing artifact or author a new one, then drafts it into the working tree for the engineer to **approve**, **decline**, or **defer**.
   - **Approve** ships a prose rule under `.claude/rules/` carrying a mandatory `paths:` glob and a provenance marker (see below). It is never frontmatter-less / always-loaded. The rule goes through normal PR review and becomes the shared suppression signal.
   - **Decline** records `finding_class -> timestamp` in machine-local, gitignored state only. It re-surfaces to that engineer once three or more distinct PRs carrying the class merge after the decline; teammates still see and can approve the same candidate.
   - **Defer** leaves the candidate to nudge again next tally.
6. **Permanence + bounded weight.** A promoted lesson does not expire. The no-ratchet guarantee rides on context weight, not deletion: every promoted rule is path-scoped, and deterministic checks cost zero auto-load weight, so the total never becomes a global tax.
7. **Prune-first hygiene.** [[GAIA Audit]] is the single pruner. It treats a provenance-marked rule as an ordinary rule and prunes it only on obsolescence (its governed surface was removed), redundancy (a tool now enforces it), supersession, or duplication. Non-recurrence is never a prune signal: a quiet pattern under a live rule is the rule working.

## Provenance marker

An approved prose rule carries, on the first line after its frontmatter, a single HTML comment:

```
<!-- gaia-harden: promoted from recurring finding_class <class>; pruned by /gaia-audit on obsolescence/redundancy/supersession/duplication only, never for non-recurrence -->
```

The marker documents why the rule exists and reminds the pruner that "quiet" is not "stale". It grants no special lifecycle: `/gaia-audit` recognizes it only to apply its existing obsolescence / duplicate / supersession signals without exemption, and to refuse non-recurrence as a staleness signal. Because the rule is path-scoped, it is the case the pruner's Rules-vs-wiki note already permits to duplicate wiki content.

## Mentorship boundary

This loop is adjacent to, but distinct from, the mentorship detector in [[Telemetry]]. It keys on `finding_class + count` at a threshold of three over a rolling 90-day PR window, reads the PR finding-blocks via `gh`, and is human-gated and actuating: its output is a drafted rule for approval.

The mentorship detector keys on `area_tag + strength` at a threshold of ten over a rolling 30-day window. Its event store is opt-in and privacy-sealed, a display rule forbids surfacing raw events, and it produces non-actuating coaching nudges. The two are separate machinery: the loop must never read the sealed mentorship JSONL to compute its tally.

## Pairs with

- [[Code Review Audit Agent]]: the source of the `finding_class` emissions the loop counts
- [[GAIA Audit]]: the single pruner; honors the provenance marker, never prunes for non-recurrence
- [[Telemetry]]: home of the adjacent, privacy-sealed mentorship detector
