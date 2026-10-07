---
type: concept
status: active
created: 2026-05-06
updated: 2026-05-07
tags: [concept, claude, workflow, wiki]
---

# Wiki Consolidate

The consolidate stage of `/gaia-wiki` audits the wiki for redundancy and contradiction across promoted pages. It detects supersession candidates, reversed decisions, near-collision slugs, and subject-orphans, then surfaces each finding as a proposal the maintainer can apply, defer, or acknowledge as intentional. The playbook lives at `.claude/skills/gaia/references/wiki/consolidate.md`.

## Role in the wiki system

Three wiki mechanisms with non-overlapping scopes:

| Mechanism                                    | Scope                                                                      |
| -------------------------------------------- | -------------------------------------------------------------------------- |
| [[Wiki Sync\|Sync stage]]                    | Commit-driven: per-commit updates from code to wiki                        |
| The wiki promotion step | Before the merge, in the `/gaia-plan` orchestrator: promotes a SPEC or plan's content into wiki domain pages from its `SUMMARY.md` frontmatter |
| Consolidate stage                            | Cross-SPEC: detects redundancy and contradiction after multiple SPECs land |

The wiki promotion step writes correctly for its SPEC or plan. Consolidate is the "are the combined writes still coherent?" pass.

## What it detects

1. **Supersession candidates.** Two pages in the same domain whose titles are near-identical (Jaccard ≥ 0.7) and whose `promoted_from` provenance differs by ≥ 30 days. Newer is canonical; older is the candidate.
2. **Reversed decisions.** A newer decision page whose body references the older page's title with negation phrases (`"no longer use"`, `"supersedes"`, `"replaces"`, etc.). Older page is flagged for retirement.
3. **Near-collision slugs.** Pairs of slugs in the same domain with Levenshtein distance ≤ 2 or prefix overlap ≥ 3 chars. Editorial disambiguation prompt. Distance 2 is the floor; distance 3 produces excessive false positives in dense domains with short slugs.
4. **Subject-orphaned pages.** Pages with no wikilink references in `wiki/concepts/` or `wiki/modules/` that haven't been touched in 90+ days.

Findings where the user previously selected "Keep both" are suppressed via `consolidation_ack` frontmatter on the canonical page.

## Execution model

The skill runs in two stages. Detection (page-index walk, frontmatter reads, the four detection passes, report rendering) runs in a Sonnet subagent so the heavy reads stay out of the parent context. The detection subagent returns a structured findings JSON and stops. The parent then iterates findings via `AskUserQuestion`, applies the chosen action per finding, advances state, and prints the summary.

The split is forced by `AskUserQuestion`: dispatched subagents cannot surface it to the user. Keeping the apply loop in the parent is the only way the interactive prompts work.

## Apply actions

- **Supersession / reversed:** extract unique content from the older page, append under `## Historical context (from <older-title>)` in the newer page, move older to `wiki/_archived/`, update `wiki/index.md`.
- **Near-collision:** rename the non-canonical page (user picks canonical), update all wikilinks.
- **Subject-orphan:** retire to `wiki/_archived/` or set `consolidation_ack: [self]` to suppress future flags.

Consolidate does NOT commit; it stages edits and the router commits them with `gaia wiki chain commit`.

## State tracking

The consolidate stage owns `last_consolidated_sha` and `last_consolidated_at` in `wiki/.state.json`. It advances these fields on every completion (including zero-finding and all-skip runs). Each writer preserves the other stage's fields.

## When it runs

Consolidate runs on every `/gaia-wiki` chain whose sync completes normally. A finding answered `Skip` resurfaces on the next run; `Keep both` is the only answer that suppresses it.

## Pairs with

- [[Wiki Sync]]: drives the commit and owns the parallel sync-state fields.
- [[GAIA Spec]]: the workflow that produces SPECs. the wiki promotion step is the orchestrator's pre-merge step; consolidate audits its writes. The wiki promotion step writes `promoted_from` provenance.
<!-- gaia:maintainer-only:start -->
- [[spec-kit Extension Strategy]]: superseded record of the original extension-plus-preset design.
<!-- gaia:maintainer-only:end -->
