---
type: decision
status: active
priority: 1
date: 2026-05-07
created: 2026-05-07
updated: 2026-06-02
tags: [decision, wiki, cli]
---

# Wiki Management

The wiki is critical infrastructure; it decays when drift between code and documentation grows unchecked. To keep it accurate and focused, the CLI provides a set of deterministic primitives for evaluating, logging, and auditing wiki state.

## Primitives

**`gaia wiki state`**: Outputs current sync state: `head_sha`, `state_sha`, `commits_ahead` (drift count), `reachable` (whether recorded SHA is in HEAD's history), and `suggested_base`. When `reachable` is false, `suggested_base` is the newest commit reachable from HEAD at or older than `last_evaluated_at`, a recovery baseline that lets a sync resume the un-evaluated window after a squash- or rebase-merge orphans the recorded SHA, instead of discarding it. It is empty when reachable or when no baseline resolves. Used by hooks and commands to detect when a sync is needed.

**`gaia wiki commit-classify`**: Evaluates commits since a baseline SHA. For each commit, outputs `suggestion` (`WORTHY` or `SKIP`) based on subject and file paths. WORTHY commits warrant deep-read and wiki update; SKIP commits can be logged without wiki edits. The classification is deterministic; same commit always produces the same suggestion.

**`gaia wiki state-init <sha>`**: Creates `wiki/.state.json` seeded from `<sha>`; refuses if the file already exists. Bootstrap primitive used during repo onboarding before the first `/gaia-wiki sync`.

**`gaia wiki state-bump <field> <value>`**: Atomically updates `wiki/.state.json`, preserving sibling fields and key order. Used by `/gaia-wiki sync` to advance `last_evaluated_sha` and `last_evaluated_at`; used by `/gaia-wiki consolidate` to advance `last_consolidated_sha`.

**`gaia wiki log-prepend`**: Appends a single line to `wiki/log.md` in the format `- <YYYY-MM-DD> <sha> <decision> - <reason>`. Atomic insertion after frontmatter, newest entries on top. One call per commit.

**`gaia wiki page-index`**: Walks `wiki/` frontmatter and counts inbound/outbound wikilinks per page. Used by orphan and redundancy detection.

**`gaia wiki orphans`**: Lists pages with zero inbound links (newline-separated). Candidates for archival or cross-linking.

**`gaia wiki near-collisions`**: Groups pages per domain (decisions, concepts, modules, etc.) and finds near-duplicate titles using Levenshtein distance. Used by `/gaia-wiki consolidate` to surface redundancy.

**`gaia wiki dead-paths`**: Lists backticked repo paths in `wiki/` body prose that don't exist on disk. Used by `/gaia-wiki lint` to catch zombie filename references after merges and renames.

**`gaia wiki sync land`**: Branch-aware landing of staged wiki changes: commits in place on a feature branch; on `main`, stages a branch and opens a PR. Used by `/gaia-wiki sync` as the deterministic write step.

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

- `/gaia-wiki sync` owns `last_evaluated_sha` and `last_evaluated_at`
- `/gaia-wiki consolidate` owns `last_consolidated_sha` and `last_consolidated_at`

Each writer uses `state-bump` to preserve the other's fields. Hooks and other commands are read-only consumers.

## See also

[[Wiki Sync]], [[Wiki Consolidate]], `.claude/skills/gaia/references/wiki/sync.md`, `.claude/skills/gaia/references/wiki/consolidate.md`.
