---
type: concept
title: GAIA Audit
status: active
created: 2026-04-20
updated: 2026-05-03
tags: [concept, claude, skill, knowledge, hygiene]
---

# GAIA Audit

`/gaia-audit` runs a two-stage audit over every knowledge store in the project (wiki, auto-loaded `CLAUDE.md` files, `.claude/rules/`, machine-local memory) checking for duplication, stale entries, and auto-load token bloat. **Wiki is the source of truth.** The skill lives at `.claude/skills/gaia/references/audit.md` (dispatched by the `/gaia` router skill).

## When to use

- After an ingestion spree that may have introduced overlap
- When auto-load payload starts feeling heavy (CLAUDE.md, `wiki/hot.md`, or rules growing)
- Periodic hygiene pass

## Two-stage execution

`/gaia-audit` is the intent to apply. The default chains both stages; Stage 1 produces a report, Stage 2 executes it. The two-stage split is for technical reasons (different reasoning loads, drift-check between stages), not as a user-confirmation gate.

| Invocation            | Stages            | When to use                                                                          |
| --------------------- | ----------------- | ------------------------------------------------------------------------------------ |
| `/gaia-audit`         | Stage 1 → Stage 2 | Default. Research, then apply, in sequence                                           |
| `/gaia-audit --apply` | Stage 2 only      | Retry against the most recent existing report (after drift fix or interrupted apply) |

Stage 1 (Sonnet) proposes actions (`delete`, `delete-entry`, `promote`, `shrink`, `conflict`), each with verbatim `expect` snippets and sha256 drift signals, written to `.gaia/local/audit/KNOWLEDGE-{timestamp}.md`. Stage 2 (Sonnet) reads the report, verifies drift signals still match, and applies changes verbatim; on mismatch it skips and reports rather than improvising. Drift checks (sha256 + verbatim before/after) carry the safety, so the research stage doesn't need a heavier model.

## What it catches

- **Cross-store duplication**: fact lives in both memory and wiki → wiki wins; the memory entry is deleted
- **Contradictions**: a memory entry, rule, or project file that asserts the opposite of the authoritative source on a subject → resolved toward the authoritative source (cross-store favors the wiki; project-internal favors whichever file is canonical for that fact).
- **Promotable memory**: durable knowledge stuck in machine-local memory → moves to a specific wiki page
- **Auto-load bloat**: flags `wiki/hot.md`, `CLAUDE.md`, and rules over budget
- **Stale entries** referencing removed code, branches, or features
- Wiki-internal redundancy and broken links are out of scope here — see [[GAIA Wiki]] (consolidate / lint).

Guardrails and portability details live in `.claude/skills/gaia/references/audit.md`. Key invariants: Stage 2 never deletes unless Stage 1 named the wiki target; never runs `git add` / `git commit`; reports gitignored under `.gaia/local/audit/`.

## Pairs with

- [[Claude Integration]]: registered alongside the other GAIA workflows under the `/gaia` router skill
- [[Quality Gate]]: code-correctness counterpart; knowledge audit is the same idea for docs
