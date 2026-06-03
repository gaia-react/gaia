---
type: concept
status: active
created: 2026-05-06
updated: 2026-05-07
tags: [concept, claude, workflow, wiki]
---

# Wiki Consolidate

`/gaia-wiki consolidate` audits the wiki for redundancy and contradiction across promoted pages. It detects supersession candidates, reversed decisions, near-collision slugs, and subject-orphans — then surfaces each finding as a proposal the maintainer can apply, defer, or acknowledge as intentional. The playbook lives at `.claude/skills/gaia/references/wiki/consolidate.md`.

## Role in the wiki system

Three wiki commands with non-overlapping scopes:

| Command                                      | Scope                                                                      |
| -------------------------------------------- | -------------------------------------------------------------------------- |
| [[Wiki Sync\|`/gaia-wiki sync`]]             | Commit-driven: per-commit updates from code to wiki                        |
| [[GAIA Spec\|`/gaia-spec`]] → `wiki-promote` | Per-SPEC: promotes SPEC artifact content into wiki domain pages            |
| `/gaia-wiki consolidate`                     | Cross-SPEC: detects redundancy and contradiction after multiple SPECs land |

`wiki-promote` writes correctly per SPEC. Consolidate is the "are the combined writes still coherent?" pass.

## What it detects

1. **Supersession candidates.** Two pages in the same domain whose titles are near-identical (Jaccard ≥ 0.7) and whose `promoted_from` provenance differs by ≥ 30 days. Newer is canonical; older is the candidate.
2. **Reversed decisions.** A newer decision page whose body references the older page's title with negation phrases (`"no longer use"`, `"supersedes"`, `"replaces"`, etc.). Older page is flagged for retirement.
3. **Near-collision slugs.** Pairs of slugs in the same domain with Levenshtein distance ≤ 2 or prefix overlap ≥ 3 chars. Editorial disambiguation prompt. Distance 2 is the floor — distance 3 produces excessive false positives in dense domains with short slugs.
4. **Subject-orphaned pages.** Pages with no wikilink references in `wiki/concepts/` or `wiki/modules/` that haven't been touched in 90+ days.

Findings where the user previously selected "Keep both" are suppressed via `consolidation_ack` frontmatter on the canonical page.

## Execution model

The skill runs in two stages. Detection (page-index walk, frontmatter reads, the four detection passes, report rendering) runs in a Sonnet subagent so the heavy reads stay out of the parent context. The detection subagent returns a structured findings JSON and stops. The parent then iterates findings via `AskUserQuestion`, applies the chosen action per finding, advances state, and prints the summary.

The split is forced by `AskUserQuestion`: dispatched subagents cannot surface it to the user. Keeping the apply loop in the parent is the only way the interactive prompts work.

## Apply actions

- **Supersession / reversed:** extract unique content from the older page, append under `## Historical context (from <older-title>)` in the newer page, move older to `wiki/_archived/`, update `wiki/index.md`.
- **Near-collision:** rename the non-canonical page (user picks canonical), update all wikilinks.
- **Subject-orphan:** retire to `wiki/_archived/` or set `consolidation_ack: [self]` to suppress future flags.

Consolidate does NOT commit — it stages edits and hands off to `/gaia-wiki sync` (or `wiki-commit-nudge`) for the branch-aware commit.

## State tracking

`/gaia-wiki consolidate` owns `last_consolidated_sha` and `last_consolidated_at` in `wiki/.state.json`. It advances these fields on every completion (including zero-finding and all-skip runs) so the gate in `/gaia-wiki sync` Step 9 accumulates accurately from the last consolidate run. Each writer preserves the other command's fields.

## Auto-invocation

`/gaia-wiki sync` runs a consolidation gate after every sync. If any single wiki domain has ≥ 2 pages added since `last_consolidated_sha`, the sync wrapper invokes `/gaia-wiki consolidate` automatically. Manual invocation remains available at any time.

## Pairs with

- [[Wiki Sync]] — drives the commit and owns the parallel sync-state fields.
- [[GAIA Spec]] — source of wiki-promote writes that consolidate audits.
- [[spec-kit Extension Strategy]] — the extension+preset design that produces `promoted_from` provenance.
