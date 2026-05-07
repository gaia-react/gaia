---
type: decision
status: active
priority: 1
date: 2026-05-07
created: 2026-05-07
updated: 2026-05-07
tags: [decision, wiki, cli]
---

# Wiki Management

The wiki is critical infrastructure — it decays when drift between code and documentation grows unchecked. To keep it accurate and focused, the CLI provides a set of deterministic primitives for evaluating, logging, and auditing wiki state.

## Primitives

**`gaia wiki state`** — Outputs current sync state: `head_sha`, `state_sha`, `commits_ahead` (drift count), and `reachable` (whether recorded SHA is in HEAD's history). Used by hooks and commands to detect when a sync is needed.

**`gaia wiki commit-classify`** — Evaluates commits since a baseline SHA. For each commit, outputs `suggestion` (`WORTHY` or `SKIP`) based on subject and file paths. WORTHY commits warrant deep-read and wiki update; SKIP commits can be logged without wiki edits. The classification is deterministic — same commit always produces the same suggestion.

**`gaia wiki state-bump <field> <value>`** — Atomically updates `wiki/.state.json`, preserving sibling fields and key order. Used by `/wiki-sync` to advance `last_evaluated_sha` and `last_evaluated_at`; used by `/wiki-consolidate` to advance `last_consolidated_sha`.

**`gaia wiki log-prepend`** — Appends a single line to `wiki/log.md` in the format `- <YYYY-MM-DD> <sha> <decision> — <reason>`. Atomic insertion after frontmatter, newest entries on top. One call per commit.

**`gaia wiki page-index`** — Walks `wiki/` frontmatter and counts inbound/outbound wikilinks per page. Used by orphan and redundancy detection.

**`gaia wiki orphans`** — Lists pages with zero inbound links (newline-separated). Candidates for archival or cross-linking.

**`gaia wiki near-collisions`** — Groups pages per domain (decisions, concepts, modules, etc.) and finds near-duplicate titles using Levenshtein distance. Used by `/wiki-consolidate` to surface redundancy.

## State file

`wiki/.state.json` is the single source of truth for sync state:

```json
{
  "version": 1,
  "last_evaluated_sha": "...",
  "last_evaluated_at": "2026-05-07T...",
  "last_consolidated_sha": "...",
  "last_consolidated_at": "2026-05-07T..."
}
```

Two commands own disjoint subsets:
- `/wiki-sync` owns `last_evaluated_sha` and `last_evaluated_at`
- `/wiki-consolidate` owns `last_consolidated_sha` and `last_consolidated_at`

Each writer uses `state-bump` to preserve the other's fields. Hooks and other commands are read-only consumers.

## See also

[[Wiki Sync]], [[Wiki Consolidate]], `.claude/commands/wiki-sync.md`, `.claude/commands/wiki-consolidate.md`.
