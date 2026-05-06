---
name: speckit-gaia-wiki-promote
description: Promote merged SPEC content into the GAIA wiki.
---

# Wiki Promote — `after_implement` hook

Fires automatically on `/speckit-implement` completion. Reads the SPEC artifact, detects whether the implementing PR has merged, and either promotes content into `gaia/wiki/` or persists a defer flag.

## Step 1 — Resolve the SPEC

The hook fires on `/speckit-implement` completion. The agent has the SPEC ID in conversation context (the implementer agent referenced it).

Identify the SPEC ID from the running conversation. If ambiguous, fall back to the most-recently-modified file under `.gaia/local/specs/SPEC-*.md` (excluding `-revised-contracts` and `-refit-decision` suffixes).

Read the SPEC frontmatter. Required fields: `spec_id`, `wiki_promote_default`, `wiki_promote_targets` (default `[]`).

If the SPEC file is missing, exit with: `wiki-promote: SPEC artifact not found; nothing to promote.`

## Step 2 — Read promotion gate

Branch on `wiki_promote_default`:

- `no` → exit silently with: `wiki-promote: SPEC-NNN skipped per frontmatter (wiki_promote_default: no).` (UAT-002)
- `ask` → surface `AskUserQuestion`:
  - Question: `Promote SPEC-NNN to wiki? (default yes)`
  - Options: `Yes, promote now` / `No, skip silently` / `Preview pages without writing`
  - On `Yes` → continue to Step 3.
  - On `No` → exit silently with the skip report.
  - On `Preview` → render the candidate pages (call Step 4 + Step 5 in dry-run mode), print to stdout, exit without writing. Mark this branch with `--preview` for downstream tasks.
  (UAT-003)
- `yes` → continue to Step 3.
- Any other value → emit warning `wiki-promote: unrecognized wiki_promote_default '<value>'; treating as 'no'.` and exit silently.

## Step 3 — Detect merged PR

Determine the current branch:
```bash
current_branch=$(git rev-parse --abbrev-ref HEAD)
```

Probe for a merged PR matching the branch:
```bash
pr_json=$(gh pr list --head "$current_branch" --state merged --json number,mergedAt,url,body --limit 1 2>/dev/null || echo '[]')
```

If `$pr_json` is `[]` (no merged PR for this branch):

1. Write defer flag to `.gaia/local/cache/wiki-promote/SPEC-NNN.json`:
   ```json
   {
     "spec_id": "SPEC-NNN",
     "branch": "<current_branch>",
     "deferred_at": "<now ISO 8601 UTC>",
     "status": "awaiting-merge"
   }
   ```
   (Cache directory creation: `mkdir -p .gaia/local/cache/wiki-promote/`. The `.gaia/local/` line in `.gitignore` covers this path.)

2. Exit with: `wiki-promote: SPEC-NNN deferred — awaiting PR merge for branch <current_branch>. Drain via /gaia spec close SPEC-NNN after merge.` (UAT-005)

If `$pr_json` contains a merged PR:

1. Capture `pr_number`, `pr_url`, `pr_body`, `merged_at` for downstream steps.
2. Continue to Step 4 (routing — Phase 3).
3. If a defer flag exists at `.gaia/local/cache/wiki-promote/SPEC-NNN.json`, delete it (the wait is over).

If `gh` is not installed or not authenticated, treat as "no merged PR" — write the defer flag with an additional field `gh_unavailable: true` and exit. This handles GAIA's framework-neutrality (offline, GitLab, Bitbucket users).

## Step 4 — Route to wiki destinations

(filled in by Phase 3 task-routing)

## Step 5 — Render and write pages

(filled in by Phase 3 task-idempotency + task-cross-links)

## Step 6 — Hand off to wiki-sync

(filled in by Phase 4 task-wiki-sync-handoff)

## Step 7 — Report

(filled in by Phase 4 task-wiki-sync-handoff)
