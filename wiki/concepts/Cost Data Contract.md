---
type: concept
title: Cost Data Contract
status: active
created: 2026-07-05
updated: 2026-07-08
tags: [concept, cost, data-contract, audit]
---

# Cost Data Contract

`.gaia/local/telemetry/cost.jsonl` is a versioned, self-describing cost ledger: one JSON record per `/gaia-spec`, `/gaia-plan`, or KICKOFF-execution run, durable enough for an external dashboard to read directly. `.gaia/scripts/token-tally.sh` is the single source of truth for the emitted schema, this page documents what it builds, not the other way around; when the two disagree, the script wins.

The ledger lives at `.gaia/local/telemetry/cost.jsonl`, resolved to the main checkout (never a linked worktree's own `.gaia/local/`) by `.gaia/scripts/ledger-path-lib.sh`'s `gaia_resolve_ledger_path`, so a worktree-run tally still appends to the one ledger the rest of the project's history lives in. It is gitignored, machine-local, and append-only.

## Record fields (schema_version 1)

| Field | Type | Notes |
| --- | --- | --- |
| `schema_version` | `int` (literal `1`) | Identifies the record shape. See the evolution rule below. |
| `kind` | `"spec" \| "plan" \| "execute" \| "review"` | Which action produced the row. `"review"` is a standalone record, not a spec/plan/execute phase: one row per `code-review-audit` invocation, deduped by `review_id`. See "Review rows" below. |
| `spec_id` | `"SPEC-NNN" \| null` | Set only when the feature carries a SPEC identity. |
| `plan_id` | `"PLAN-NNN" \| null` | Set only for a spec-less plan/execute. `spec_id` and `plan_id` are never both set; a spec identity wins the tiebreak when both are somehow supplied. An unclassifiable or absent feature key degrades to a partial row with **both** null, never a mistyped id. |
| `plan_slug` | `string \| null` | The plan folder's human-facing slug. |
| `session_id` | `string` | The Claude Code session that produced the tally. |
| `buckets` | `object` | `{ fresh_input, cache_write, cache_read, output }`, four `int`s: the session's deduped token totals. |
| `total` | `int` | Sum of the four `buckets`. |
| `by_model` | `object`, omitted when empty | Model id → five-bucket object: `{ fresh_input, cache_write_5m, cache_write_1h, cache_read, output }` (all `int`). The `cache_write_5m`/`cache_write_1h` split is what `buckets.cache_write` collapses; a record whose attribution failed omits the key entirely rather than writing `{}`. |
| `by_agent_type` | `object`, omitted when empty | Bucket key → the same five-bucket shape as `by_model`. Keys: `main` (the main transcript), a sub-agent's own `agentType` (e.g. `general-purpose`), `auto-compaction` (a compaction-summary line, regardless of which transcript it came from), and `unknown` (a sidecar whose sibling `.meta.json` is missing, unreadable, or lacks `.agentType`). Reconciles by equality: collapsing every bucket's `cache_write_5m` + `cache_write_1h` and summing across buckets reproduces the top-level `buckets`/`total` exactly. |
| `dollars` | `number \| null` | The session's estimated USD cost, priced from `by_model` at generation time. `null` when pricing was unavailable (empty `by_model`, unreadable rate table). |
| `rate_table_id` | `"sha256:<16-hex>" \| null` | Identity of the committed rate table that priced `dollars`, so a downstream reader can re-price the raw `by_model` under a different card. `null` off the priced path. See [[Token Cost Readout]] for how a rate table earns this id. Absent (not present, not `null`) on `source: "backfill"` rows. |
| `partial` | `bool` | `true` when the session id was empty, the main transcript matched no file, or any matched file failed to parse. An empty sidecar set alone does NOT set this. Absent (not present) on `source: "backfill"` rows; a reader treats a missing `partial` the same as `false` rather than rejecting the row. |
| `started_at` | `iso \| null` | Earliest usage-bearing transcript timestamp, raw UTC. `null` when `duration_available` is `false`. |
| `ended_at` | `iso \| null` | Latest usage-bearing transcript timestamp, raw UTC. Same null condition as `started_at`. |
| `duration_seconds` | `int \| null` | `ended_at` minus `started_at`. `null` when unavailable. |
| `duration_available` | `bool` | Independent of `partial`: tokens can be complete while duration is unavailable (an unparseable extremal timestamp), and the reverse. |
| `git_branch` | `string \| null` | Current branch at tally time, or `null` when it could not be resolved. Absent (not present) on `source: "backfill"` rows. |
| `project` | `"sha256:<16-hex>" \| "path:<16-hex>" \| null` | Repo identity: a hash of the normalized `origin` remote URL when one exists (so an `https` and `ssh` clone of the same repo collide), else a hash of the main checkout's absolute path, else `null`. Absent (not present) on `source: "backfill"` rows. |
| `seq` | `int` | `0` for `spec`/`plan` rows (one row per session). For `execute`, the count of prior same-`(feature, session_id)` execute rows already on the ledger; monotonic per feature per session. |
| `final` | `bool` | `true` on every newly appended row. For `execute`, a best-effort rewrite flips every prior same-`(feature, session_id)` row's `final` to `false` after append, so at most one row per feature per session stays `true`. |
| `ts` | `iso` | Generation stamp: when this record was written. |
| `session_cwd` | `string \| null` | The session's live working directory at tally time (the tally's own `$PWD`, not `--out-dir` or the resolved ledger path), including from the worktree and degraded-attribution paths. `null` when empty. A reader forward-encodes it with Claude Code's transcript-directory transform (`/` and `.` each become `-`) to name the exact `~/.claude/projects` folder the session's transcript lives under. Absent on rows written before this field existed and on `source: "backfill"` rows; a reader without `session_cwd` falls back to a directory-scan heuristic to locate the transcript. |
| `source` | `"backfill" \| "code-review-audit" \| absent` | Additive provenance marker. `"backfill"` marks the one-off vintage `cost.md` → `cost.jsonl` backfill (see "Retention at merge" below); `"code-review-audit"` marks every `kind: "review"` row. Absent (not present, not null) on every other natively emitted row. |
| `review_id` | `string`, present only on `kind: "review"` rows | The dedup key for the triggering `code-review-audit` run. A later trigger for a `review_id` already on the ledger writes nothing. |
| `audit` | `object`, present only on `kind: "spec"` \| `"plan"` rows, omitted when absent | `{ adversarial: { buckets, dollars, elapsed_seconds, lenses, intensity? } }`: a same-session adversarial-audit-window drill-down. A strict subset of the phase's own `buckets` / `total` / `dollars`, never summed into them. Omitted, never fabricated, when no matching-session audit-window breadcrumb exists or its window catches zero sidecar activity. |

## Execute aggregation rule

An `execute` action appends one cumulative row per commit, `seq` incrementing per `(feature, session_id)`. A reader takes the row with `final: true` for a given `session_id` (falling back to the row with the max `seq` when none is marked final, the ledger-write rewrite is best-effort and can fail open) as the session's true cumulative cost. That row is counted once: no per-commit overcount, and no cross-row total comparison is needed, the terminal row already carries the full cumulative figure.

## Review rows

A `code-review-audit` run (the pre-merge gate, or an ad-hoc invocation) writes a standalone `kind: "review"` row rather than nesting into a spec/plan/execute phase; `plan_slug` is always `null` on these rows. Two triggers can fire for the same run, a `gh pr merge` PostToolUse hook and a Stop hook, `token-tally.sh --action review` owns the window detection and `review_id` dedup so only the first trigger writes a row. A spec/plan/execute phase's own aggregated total excludes any overlapping `code-review-audit` window from its buckets, so a reader summing a phase row plus its `review` rows never double-counts.

## schema_version evolution rule

Additive-only by default: a new field does not bump `schema_version`. A breaking change, removing or repurposing an existing field, bumps `schema_version` and is confirmed first, an external consumer depends on this contract holding still. The ledger holds only `schema_version` 1-or-later records; a prior, differently-shaped ledger is moved aside to a backup file the contract never reads, so there is no absent-`schema_version` legacy branch to handle downstream.

## Retention at merge

A merged folder's archival unit is its consolidated `SUMMARY.md` plus its `cost.json` sidecar, kept at merge; the SessionStart janitor age-reaps the folder once its merge has aged past the retention window (`GAIA_SPEC_RETENTION_DAYS`, default 30 days) and its cost is fully represented in this ledger, a check the delete/reap gate (`cost-represented.sh`) drives from the `cost.json` sidecar itself, cross-checked against this ledger. A spec-less `PLAN-NNN` folder takes the symmetric path: kept at merge, reduced to `SUMMARY.md` + `cost.json`, and age-reaped by the same fail-closed gate, keyed on `plan_id` instead of `spec_id`. A spec-colocated plan's `plan[-N]` subfolder is deleted once its own `PROGRESS.md` has fed the parent SPEC's `SUMMARY.md`; the parent SPEC folder remains the archival unit. Either way, nothing kept on disk carries the cost forward beyond the sidecar: `cost.jsonl` (this ledger) plus the two id-ledgers (`specs/ledger.json`, `plans/ledger.json`) are the whole durable record. Every figure a reaped folder's `cost.json` sidecar once carried, per-phase buckets, totals, and dollars, is recoverable from this ledger's rows keyed by `spec_id` or `plan_id`, with no dependency on any sidecar file surviving.

`token-tally.sh` writes a per-folder `cost.json` sidecar alongside its ledger append: a single JSON object keyed by phase kind (`spec` for a spec folder; `plan` and/or `execute` for a plan folder), each value the same record shape as the matching `cost.jsonl` row, scoped to that one run. A plan or execute write replaces only its own key and preserves any sibling key's value untouched, so a plan folder's sidecar accumulates both phases without one write clobbering the other.

A vintage `cost.md` that predates this ledger and the sidecar gets one `source: "backfill"` row per `## SPEC` / `## Planning` / `## Execution` section (never `## Total`, a derived grand-sum rather than its own phase).

## Pairs with

- [[Token Cost Readout]]: the `by_model` pricing surfaces (rate table, shared pricing lib, tally-time vs roll-up-time dollar figures) built on top of this ledger.
- [[Task Orchestration]]: the merge-time reconcile and retention lifecycle that eventually removes the folder this ledger's rows outlive.
