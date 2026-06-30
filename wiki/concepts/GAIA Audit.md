---
type: concept
title: GAIA Audit
status: active
created: 2026-04-20
updated: 2026-07-01
tags: [concept, claude, skill, knowledge, hygiene]
---

# GAIA Audit

`/gaia-audit` runs a two-stage audit over every knowledge store in the project (wiki, auto-loaded `CLAUDE.md` files, `.claude/rules/`, machine-local memory) checking for duplication, stale entries, and auto-load token bloat. **Wiki is the source of truth.** The skill lives at `.claude/skills/gaia/references/audit.md` (dispatched by the `/gaia-audit` command, which reads this reference and follows it).

## When to use

- After an ingestion spree that may have introduced overlap
- When auto-load payload starts feeling heavy (CLAUDE.md, `wiki/hot.md`, or rules growing)
- Periodic hygiene pass
- When the statusline shows `Run /gaia-audit (<reason>)`: GAIA nudges on per-machine memory drift, an auto-load file over budget, or a pending draft to resume

## Two-stage execution with a decision gate

`/gaia-audit` is the intent to audit. The default researches, then gates: Stage 1 produces a report, the main conversation summarizes it and asks a single **Apply / Discuss / Decline** question, and only on **Apply** does Stage 2 execute it. The two-stage split is technical (different reasoning loads, a drift-check between stages); the user-confirmation checkpoint is the single decision gate after Stage 1.

A clean audit (Stage 1 finds 0 actions) skips the gate and auto-applies: there is nothing to approve, and applying only finalizes the report's `status` and clears the statusline nudge. Leaving a 0-action report parked at the gate is the exact path that strands a `draft` that nudges indefinitely.

- **Apply**: spawn Stage 2 to execute the report now (the one-keystroke fast path).
- **Discuss / refine**: talk it through, edit the report in place, then re-ask.
- **Decline**: delete the report; nothing is applied.

### Classification-verification round

When Stage 1 proposes at least one action, a recommended-but-optional **classification-verification round** runs in the main conversation between the report and the decision gate. Low-overlap lenses verify Stage 1's single-pass classifications against ground truth: the cited fact actually lives in the wiki page it names, a STALE entry is genuinely gone rather than renamed, a CONFLICT is a real contradiction rather than a sanctioned path-scoped rule, and a memory delete's reason citation resolves. The round is biased toward dropping a delete it cannot confirm, because memory deletes are machine-local and have no git undo, so a wrongly-kept entry is cheap clutter while a wrongly-executed delete is permanent. A mis-classified action is dropped or corrected in the report directly; a whole miscalibrated lens re-spawns Stage 1 once with the findings as a correction directive.

The hardened report carries an `audit_hardened` stamp that the decision gate and `--apply` inherit: `--apply` against a stamped report trusts the hardening, while an unstamped draft has the round run non-interactively before applying. The round is recommended (and recommended only when an irreversible or contradiction-risk action is present; a set of git-reversible shrinks may legitimately skip it), never blocks, and is skipped entirely on a clean 0-action report.

| Invocation             | Path                              | When to use                                                                                                       |
| ---------------------- | --------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `/gaia-audit`          | Stage 1 → gate → Stage 2 on Apply | Default. Research, review at the gate, then apply                                                                 |
| `/gaia-audit "<hint>"` | Same, scoped to the hint          | Narrow Stage 1 to named stores or files; a scoped run still applies by default                                   |
| `/gaia-audit --apply`  | Stage 2 only                      | Retry against the most recent draft or partial report (after drift fix or interrupted apply), within a 72h grace |

Stage 1 (Sonnet) proposes actions (`delete`, `delete-entry`, `promote`, `shrink`), each with verbatim `expect` snippets and sha256 drift signals, written to `.gaia/local/audit/KNOWLEDGE-{timestamp}.md`. Stage 2 (Sonnet) reads the report, verifies drift signals still match, and applies changes verbatim; on mismatch it skips and reports rather than improvising. Drift checks (sha256 + verbatim before/after) carry the safety, so the research stage doesn't need a heavier model. Contradiction findings (CONFLICT research category) emit `replace` or `delete` action types in the report, not a separate action type.

### Report lifecycle

Each report carries a `status:` field. Stage 1 writes it as `draft`; Stage 2 flips it to `applied` when every action lands cleanly, or `applied-partial` when some actions are skipped or fail (kept so `/gaia-audit --apply` can retry the remainder). A `draft` survives an interrupted run and is resumable. The Step 0 prune keeps the newest few `applied` reports and never deletes a `draft`; declining at the gate deletes the report immediately. Recovery for tracked files is git, printed as a `recovery:` line after apply (`git restore` / `git checkout --` / `git clean`).

## What it catches

- **Cross-store duplication**: fact lives in both memory and wiki → wiki wins; the memory entry is deleted
- **Contradictions**: a memory entry, rule, or project file that asserts the opposite of the authoritative source on a subject → resolved toward the authoritative source (cross-store favors the wiki; project-internal favors whichever file is canonical for that fact).
- **Promotable memory**: durable knowledge stuck in machine-local memory → moves to a specific wiki page
- **Auto-load bloat**: flags `wiki/hot.md`, `CLAUDE.md`, and rules over budget
- **Stale entries** referencing removed code, branches, or features
- Wiki-internal redundancy and broken links are out of scope here; see [[Wiki Management]] (consolidate / lint).

Guardrails and portability details live in `.claude/skills/gaia/references/audit.md`. Key invariants: Stage 2 never deletes unless Stage 1 named the wiki target; never runs `git add` / `git commit`; reports gitignored under `.gaia/local/audit/`.

## Pairs with

- [[Claude Integration]]: registered alongside the other GAIA workflows as a discrete `/gaia-*` command
- [[Quality Gate]]: code-correctness counterpart; knowledge audit is the same idea for docs
