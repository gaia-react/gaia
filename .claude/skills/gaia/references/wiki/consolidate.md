# wiki-consolidate playbook

Dispatched by the `/gaia wiki` router (`references/wiki.md` → "Consolidate"). Detection runs in a Sonnet subagent; apply/state/report run in the parent.

## Playbook

This workflow complements but does not replace `wiki-promote` (per-SPEC writes), `/gaia wiki sync` (commit-driven updates), or `/gaia wiki lint` (broken-thing detection). It detects **redundancy and contradiction** across the wiki and proposes merges so the wiki stays an accurate "today's state of the app" snapshot.

**Follow `.claude/rules/wiki-style.md` when writing prose during apply actions.** Present tense; no UAT-NNN, SPEC-NNN, PR-number, or commit-SHA references in body prose. The `## Historical context (from <older-title>)` archival heading defined in Step 4 is a deliberate exception — it labels content lifted from a superseded page so it remains discoverable.

Wiki pages emitted by `wiki-promote` carry `promoted_from: SPEC-NNN` and `promoted_at: <ISO>` frontmatter. Those fields are the consolidation seam — they tie pages back to source SPECs and let the audit detect when newer SPECs have superseded older ones.

## Step 1 — Build the page index

Run `gaia wiki page-index --json` and use the returned shape. The CLI walks the canonical domains (`wiki/decisions/`, `wiki/concepts/`, `wiki/modules/`, `wiki/flows/`, `wiki/components/`, `wiki/dependencies/`), skipping `wiki/_archived/`, `wiki/meta/`, `wiki/entities/`, `wiki/log.md`, `wiki/index.md`, `wiki/hot.md`, `wiki/overview.md`, `wiki/README.md`, and per-domain `_index.md` files.

Each entry in `pages[]` provides `path`, `domain`, `title`, `type`, `status`, `tags`, `inbound_links`, and `outbound_links`. Augment with the consolidation-only fields the CLI does not surface — read each page's frontmatter for:

- `slug` — last path component of `path` without `.md`
- `promoted_from` — string, list, or null
- `promoted_at` — ISO or null
- `consolidation_ack` — list of slugs the user previously confirmed should coexist (skip-flags written by prior runs)

Treat a missing `status` as `active`. Pages with `status: superseded` or `status: archived` are excluded as the **newer** side of a comparison but remain visible as the **older** side (used to suppress already-handled findings).

## Step 2 — Detection passes

Run all four passes; collect findings before prompting any actions.

### 2a. Same-subject across SPECs (supersession)

For each pair of pages in the same `domain`, compare:

- **Title match** — case-insensitive equality OR Jaccard similarity ≥ 0.7 over title tokens (split on whitespace + punctuation, lowercase, drop tokens shorter than 3 chars).
- **Provenance gap** — both pages have non-null `promoted_from`, the values differ, and `promoted_at` of one is at least 30 days newer than the other.

When both conditions hold, flag a **supersession candidate**: newer page is the canonical, older is the supersession candidate.

### 2b. Reversed decisions

Scope: `wiki/decisions/` only.

For each pair of decision pages where one is newer than the other (by `promoted_at`), scan the newer page's body for negation patterns referencing the older page's title:

- `"no longer use"`, `"replaces"`, `"supersedes"`, `"deprecated in favor of"`, `"reversed"`, `"obsoletes"` (case-insensitive)

If a match references the older page's title (substring, case-insensitive), flag the older page for **retirement**.

### 2c. Near-collision slugs

Run `gaia wiki near-collisions --max-distance 2` and surface its output. The CLI emits per-domain pairs that are within Levenshtein distance 2 (or where one slug is a prefix of the other) as tabular text. Flag each as a **near-collision** candidate. The newer page (by `promoted_at`, ties broken by file mtime) is the canonical.

Distance 2 is the right floor: distance 3 produces excessive false positives in dense domains with short slugs (e.g. `Ky` matches every dependency, `State` collides with `Styles`).

### 2d. Subject-orphaned pages

Run `gaia wiki orphans` to enumerate pages with zero inbound wikilinks. For each candidate, refine: keep only pages where the body title also has zero case-insensitive substring matches in `wiki/concepts/` and `wiki/modules/`, AND the page has not been touched in 90+ days (`git log -1 --format=%aI -- <path>`). Flag the survivors as **subject-orphaned**.

### 2e. Suppress acknowledged findings

For every candidate, check the canonical page's `consolidation_ack` frontmatter array. If it contains the comparison page's slug, drop the finding — the user already said keep both.

## Step 3 — Render the report (subagent-final step)

This is the last step the detection subagent runs. After writing the report file and emitting the findings JSON per the router's contract, the subagent STOPS — it does NOT proceed to Steps 4–6.

Write to `wiki/meta/consolidate-report-<YYYY-MM-DD>.md`, where `<YYYY-MM-DD>` is `date +%F` (shell) — derive it deterministically, never guess the current date. The same value fills the frontmatter `created`/`updated` and the H1. Overwrite if a same-day report exists.

Frontmatter:

```yaml
---
type: meta
title: Consolidate Report — <YYYY-MM-DD>
status: active
created: <YYYY-MM-DD>
updated: <YYYY-MM-DD>
tags: [meta, consolidate]
---
```

Body sections (omit any section with zero findings — do not emit empty H2s):

```markdown
# Consolidate Report — <YYYY-MM-DD>

Run summary: <total> findings across <domain count> domains.

## Supersession candidates (<count>)

### <domain>: <newer-title> supersedes <older-title>

- **Newer:** [[<newer-title>]] (`<newer-path>`) — promoted from `<spec_id_new>` on `<date>`
- **Older:** [[<older-title>]] (`<older-path>`) — promoted from `<spec_id_old>` on `<date>`
- **Action:** merge older into newer; mark older `status: superseded`; retire older to `wiki/_archived/<older-slug>.md`.

## Reversed decisions (<count>)

### <newer-title> reverses <older-title>

- **Newer:** [[<newer-title>]] — promoted from `<spec_id>` on `<date>`
- **Older:** [[<older-title>]] — promoted from `<spec_id>` on `<date>`
- **Negation phrase:** "<phrase>"
- **Action:** retire older to `wiki/_archived/<older-slug>.md`.

## Near-collision slugs (<count>)

### <domain>: <slug-a> vs <slug-b>

- **Page A:** [[<title-a>]] (`<path-a>`)
- **Page B:** [[<title-b>]] (`<path-b>`)
- **Distance:** <int>
- **Action:** rename one or merge.

## Subject-orphaned pages (<count>)

### [[<title>]]

- **Path:** `<path>`
- **No references** in `wiki/concepts/` or `wiki/modules/`
- **Last touched:** <N> days ago
- **Action:** retire to `wiki/_archived/<slug>.md` OR confirm still relevant (sets `consolidation_ack: [self]` on the page).
```

## Step 4 — Action prompts (parent-side, interactive)

The parent (the agent reading this file in the live conversation) iterates the findings JSON returned by the detection subagent and surfaces each via `AskUserQuestion`. The subagent does not run this step.

For each finding:

- Question: use the finding's `label` followed by `. Action?` (e.g. `decisions: auth-strategy supersedes auth-flow. Action?`)
- Header: `Consolidate`
- Options:
  - `{ label: "Apply (Recommended)", description: "<short summary of the merge or retire>." }`
  - `{ label: "Keep both", description: "Mark consolidation_ack on the canonical page; suppresses re-flagging on future runs." }`
  - `{ label: "Skip", description: "Defer to the next consolidate run; finding remains active." }`

Process findings in this order: **supersession → reversed → near-collision → subject-orphan**. Most-impactful first.

### Apply actions

**Supersession / reversed:**

1. Read older page body. Extract any content not already present in the newer page (LLM judgment — preserve newer page's structure, no duplication).
2. If non-empty unique content: append to newer page under H2 `## Historical context (from <older-title>)`. The heading itself is the archival label; do NOT add a SPEC-NNN reference in the preamble (per `.claude/rules/wiki-style.md`).
3. Update older page's frontmatter: `status: superseded`, `superseded_by: <newer-slug>`, `superseded_at: <ISO>`. Preserve `created`, `promoted_from`, `promoted_at`.
4. Move older page: `mkdir -p wiki/_archived/ && git mv <older-path> wiki/_archived/<older-slug>.md`. (Use `mv` if `git mv` fails due to staging state.)
5. Update `wiki/index.md`: remove the older page's entry from its domain section. The wikilink in any newer page's "Related" section becomes a broken link — `/gaia wiki lint` will surface and the maintainer can fix on the next lint pass; do not autofix here (consolidate is conservative about page-body edits beyond the targeted merge).
6. Update newer page's `promoted_from`: if currently a string, convert to a list `[<old_provenance>, <new_provenance>]` so future wiki-promote runs treat it as a known consolidated page. If already a list, append.

**Near-collision:**

1. Surface a follow-up `AskUserQuestion`: `Which slug should be canonical?` with options for each candidate slug. (Do not assume newer wins — slug choice is editorial.)
2. Rename the non-canonical page: `git mv <non-canonical-path> <canonical-domain>/<canonical-slug>.md`.
3. Run a wikilink update: `grep -rn "\[\[<old-title>\]\]" wiki/ --include="*.md"` and replace with `[[<canonical-title>]]` across all matches.
4. Update `wiki/index.md` to drop the old entry and ensure the canonical entry is present.

**Subject-orphan:**

1. Surface a follow-up `AskUserQuestion`: `Retire <title>, or confirm still relevant?`.
2. **Retire:** move to `wiki/_archived/<slug>.md`, set `status: archived`, drop entry from `wiki/index.md`.
3. **Confirm relevant:** add `consolidation_ack: [self]` to the page's frontmatter. Suppresses future subject-orphan flags for this page.

### Keep both

Append the comparison page's slug to the canonical page's `consolidation_ack` frontmatter array. Create the field if absent. No other changes.

### Skip

No-op. Finding remains active and will re-surface on the next consolidate run.

## Step 5 — Advance consolidate state

Update `wiki/.state.json` via the CLI primitive (preserves sibling fields and key order automatically):

1. Confirm the file exists. It should — `/gaia wiki sync` creates it on first run. If missing, skip this step entirely and emit a warning in the Step 6 summary.
2. Run `gaia wiki state-bump last_consolidated_sha "$(git rev-parse HEAD)"` (full 40-char SHA at consolidate-completion time, before any of this run's edits get committed).
3. Run `gaia wiki state-bump last_consolidated_at "$(date -u +%FT%TZ)"`.

`state-bump` performs an atomic write (`writeFileSync` to `.tmp` + `renameSync`) and preserves `last_evaluated_sha`, `last_evaluated_at`, and any future sibling fields verbatim.

Advance state on every completion regardless of how many findings were applied — including zero findings and all-skip runs. The consolidate gate in the sync playbook (Step 9) reads `last_consolidated_sha` to decide when to auto-fire; not advancing would cause the gate to re-fire immediately on the next sync with the same data.

The `wiki/.state.json` file is committed by `/gaia wiki sync` (or by the maintainer manually if consolidate ran outside a sync). Consolidate itself does not commit — see Step 6.

## Step 6 — Hand off and report

Do NOT commit. Applied edits are staged; `/gaia wiki sync` (or the `wiki-commit-nudge` hook) handles the commit per its branch-aware rules.

Print:

1. The report path (e.g. `wiki/meta/consolidate-report-2026-05-06.md`).
2. One-line summary: `<applied> applied, <kept> kept, <skipped> skipped across <total> findings.`

If anything was applied, suggest: `Run /gaia wiki sync to commit.`

If any HIGH-severity supersession or reversed-decision was applied, prefix the summary with `WIKI CONSOLIDATE: ` so the parent agent surfaces it prominently.

## Notes

- **Boundary with `wiki-promote`.** wiki-promote writes per-SPEC; consolidate merges across SPECs. After a merge action, the canonical page's `promoted_from` becomes a list so future wiki-promote runs treat it as a known consolidated page (no `foreign-collision` skip).
- **Boundary with lint.** Lint finds broken things (dead links, missing frontmatter, stale claims). Consolidate finds redundant things (two pages with competing claims). Run lint before consolidate so structural issues don't get misinterpreted as content redundancy.
- **`wiki/_archived/`** is excluded from the index and from future consolidation candidacy. Pages there remain readable but are out of the live spec.
- **Idempotence.** Re-running consolidate on the same wiki state surfaces the same findings, minus those acknowledged via `consolidation_ack`. Apply actions are not idempotent (they mutate); the apply guard is "did the user already say apply" — implicit in "the older page is no longer in its original domain," which the page index would reflect on the next run.
- **Auto-invocation via the sync gate.** Sync Step 9 runs a cheap precheck after every sync (including no-op syncs): if any single wiki domain has ≥2 added pages since `last_consolidated_sha`, the router invokes consolidate automatically. Manual invocation remains available — `/gaia wiki consolidate` shows ALL current findings regardless of trigger source. Findings the user `Skip`s on a gate-triggered run will not auto-resurface until new pages accumulate; revisit them by running `/gaia wiki consolidate` manually.
- **Shared state file ownership.** `wiki/.state.json` holds fields written by both sync (`last_evaluated_sha`, `last_evaluated_at`) and this workflow (`last_consolidated_sha`, `last_consolidated_at`). Each writer preserves the other's fields. Do not delete `wiki/.state.json` — both gates depend on it.
