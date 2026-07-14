---
type: concept
title: Cost Data Contract
status: active
created: 2026-07-05
updated: 2026-07-14
tags: [concept, telemetry, cost, data-contract, audit]
---

# Cost Data Contract

`.gaia/local/telemetry/cost.jsonl` is a versioned, self-describing cost ledger: one JSON record per `/gaia-spec` run, `/gaia-plan` run, KICKOFF-execution run, or maintenance-command run (`/gaia-audit`, `/gaia-debt`, `/gaia-fitness`, `/gaia-forensics`, `/gaia-harden`, `/gaia-wiki`), durable enough for an external dashboard to read directly. `.gaia/scripts/token-tally.sh` is the single source of truth for the emitted schema, this page documents what it builds, not the other way around; when the two disagree, the script wins.

The ledger lives at `.gaia/local/telemetry/cost.jsonl`, resolved to the main checkout (never a linked worktree's own `.gaia/local/`) by `.gaia/scripts/ledger-path-lib.sh`'s `gaia_resolve_ledger_path`, so a worktree-run tally still appends to the one ledger the rest of the project's history lives in. It is gitignored, machine-local, and append-only.

## Record fields (schema_version 1)

| Field | Type | Notes |
| --- | --- | --- |
| `schema_version` | `int` (literal `1`) | Identifies the record shape. See the evolution rule below. |
| `kind` | `"spec" \| "plan" \| "execute" \| "review" \| "command"` | Which action produced the row. `"review"` is a standalone record, not a spec/plan/execute phase: one row per `code-review-audit` invocation, deduped by `review_id`. See "Review rows" below. `"command"` is likewise a standalone record, not a spec/plan/execute phase: one row per maintenance-command invocation, unattributed (`spec_id`, `plan_id`, `plan_slug` all `null`), keyed by `run_id`. See "Maintenance-command rows" below. |
| `spec_id` | `"SPEC-NNN" \| null` | Set only when the feature carries a SPEC identity. |
| `plan_id` | `"PLAN-NNN" \| null` | Set only for a spec-less plan/execute. `spec_id` and `plan_id` are never both set; a spec identity wins the tiebreak when both are somehow supplied. An unclassifiable or absent feature key degrades to a partial row with **both** null, never a mistyped id. |
| `plan_slug` | `string \| null` | The plan folder's human-facing slug. |
| `command` | `string \| null`, present only on `kind: "command"` rows | Names the invoking command. The closed set is exactly `gaia-audit`, `gaia-debt`, `gaia-fitness`, `gaia-forensics`, `gaia-harden`, `gaia-wiki`. An unrecognized value is carried through verbatim and degrades the record to `partial` rather than erroring; an omitted flag writes `null` and also degrades to `partial`. A consumer treats an unrecognized value as a valid command it does not yet have a label for, never as a corrupt row. |
| `run_id` | `string`, present only on `kind: "command"` rows | Stable identifier for one invocation. Shape: `<command-slug>-<YYYYMMDDTHHMMSSZ>-<4-hex>`, e.g. `gaia-audit-20260714T021530Z-a1b2`. Exists so a consumer that groups by attribution, kind, and session can still tell two runs apart; the trailing 4-hex suffix keeps two same-second runs distinct but is not on its own a uniqueness guarantee. **A consumer must include it in its group key**, exactly as it already does for `review_id`; without it two runs of the same command in one session collapse into one. |
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
| `github` | `object`, **omitted entirely** when absent | Present on `kind: "command"` and `kind: "execute"` rows when the run produced a pull request or an issue: `{ "type": "pr" \| "issue", "number": <int>, "repo": "<owner>/<name>" }`. `repo` is the repository the artifact actually **lives in**, which is not always the repository the command ran in (a forensics issue is filed against GAIA's own repo). **Never present-and-null-filled**: a consumer that expects `"github": null` throws on a row where the key is simply absent. Its absence never marks a row `partial`. See "How a record binds its GitHub artifact" below. |

These additions, one new `kind` value and three new optional fields, are additive: `schema_version` stays `1`.

## Execute aggregation rule

An `execute` action appends one cumulative row per commit, `seq` incrementing per `(feature, session_id)`. A reader takes the row with `final: true` for a given `session_id` (falling back to the row with the max `seq` when none is marked final, the ledger-write rewrite is best-effort and can fail open) as the session's true cumulative cost. That row is counted once: no per-commit overcount, and no cross-row total comparison is needed, the terminal row already carries the full cumulative figure.

## Review rows

A `code-review-audit` run (the pre-merge gate, or an ad-hoc invocation) writes a standalone `kind: "review"` row rather than nesting into a spec/plan/execute phase; `plan_slug` is always `null` on these rows. Two triggers can fire for the same run, a `gh pr merge` PostToolUse hook and a Stop hook, `token-tally.sh --action review` owns the window detection and `review_id` dedup so only the first trigger writes a row. A spec/plan/execute phase's own aggregated total excludes any overlapping `code-review-audit` window from its buckets, so a reader summing a phase row plus its `review` rows never double-counts.

## Maintenance-command rows

Each of the six maintenance commands (`/gaia-audit`, `/gaia-debt`, `/gaia-fitness`, `/gaia-forensics`, `/gaia-harden`, `/gaia-wiki`) appends one standalone `kind: "command"` row per invocation, on every path that ends the run: a read-only subcommand, a decline, a no-op, and an error exit each still record exactly one row. These rows write no `cost.json` sidecar; they hang on no SPEC or plan folder, and a non-record key there would fail the merge-time retention gate closed. They are unattributed (`spec_id`, `plan_id`, `plan_slug` all `null`), so the feature roll-up, which is keyed by feature identity, never matches them and needs no change to stay correct. A consumer groups maintenance-command rows by `(attribution, kind, session_id, run_id)`; dropping `run_id` from that key collapses two runs of the same command in one session into one. Like every other non-`review` kind, a maintenance-command row's aggregate excludes any overlapping `code-review-audit` window, which lands in its own `kind: "review"` row instead, so a reader summing a command row plus its review rows never double-counts.

## How a record binds its GitHub artifact

The five prose commands and the `/gaia-wiki` chain pass the artifact through directly: each reads the URL its own creation command printed and hands the type, number, and repo straight to the tally. A record therefore names the artifact **that run** produced, never one produced by a manually run command, a sibling session, or an interleaved plan execution. `/gaia-forensics` is the one command whose pass-through can name an issue rather than a pull request (`type: "issue"`, sourced from the issue reference it already persists to its own report); the other five commands, and plan execution's breadcrumb below, only ever produce `type: "pr"`.

Plan execution is the one surface with no agent in the loop, because its rows come from a `PreToolUse` hook on `git commit` / `git push`. A `PostToolUse` hook on `gh pr create` writes a breadcrumb keyed by session, branch, and creation time, under the main checkout's cache (resolved through the git common directory, so a run inside a linked worktree still finds it). The execute tally reads the breadcrumb without consuming it, so every cumulative commit on the branch re-reads the same file and the terminal (`final: true`) row carries the pull request. No network call is added to the commit path.

Two preconditions are **limits on this, not guarantees**:

1. The terminal execute row carries `github` only when at least one commit or push follows the pull request's creation. A plan whose last commit-bearing phase completes before the PR is opened writes its last execute row before the breadcrumb exists, and the run records no artifact. That is correct behavior, not a defect.
2. A plan execution resumed in a new session leaves its terminal row without the pull request, because the breadcrumb is session-keyed. A documented limitation, never a fabricated attribution.

Rows written before the pull request existed carry no `github` field and are never back-filled.

`.gaia/scripts/tests/token-command.bats` is the executable producer oracle whose assertions pin the `command`, `run_id`, and `github` shapes above; a consumer author should read it alongside this page.

## schema_version evolution rule

Additive-only by default: a new field does not bump `schema_version`. A breaking change, removing or repurposing an existing field, bumps `schema_version` and is confirmed first, an external consumer depends on this contract holding still. The ledger holds only `schema_version` 1-or-later records; a prior, differently-shaped ledger is moved aside to a backup file the contract never reads, so there is no absent-`schema_version` legacy branch to handle downstream.

## Retention at merge

A merged folder's archival unit is its consolidated `SUMMARY.md` plus its `cost.json` sidecar, kept at merge; the SessionStart janitor age-reaps the folder once its merge has aged past the retention window (`GAIA_SPEC_RETENTION_DAYS`, default 30 days) and its cost is fully represented in this ledger, a check the delete/reap gate (`cost-represented.sh`) drives from the `cost.json` sidecar itself, cross-checked against this ledger. A spec-less `PLAN-NNN` folder takes the symmetric path: kept at merge, reduced to `SUMMARY.md` + `cost.json`, and age-reaped by the same fail-closed gate, keyed on `plan_id` instead of `spec_id`. A spec-colocated plan's `plan[-N]` subfolder is deleted once its own `PROGRESS.md` has fed the parent SPEC's `SUMMARY.md`; the parent SPEC folder remains the archival unit. Either way, nothing kept on disk carries the cost forward beyond the sidecar: `cost.jsonl` (this ledger) plus the two id-ledgers (`specs/ledger.json`, `plans/ledger.json`) are the whole durable record. Every figure a reaped folder's `cost.json` sidecar once carried, per-phase buckets, totals, and dollars, is recoverable from this ledger's rows keyed by `spec_id` or `plan_id`, with no dependency on any sidecar file surviving.

`token-tally.sh` writes a per-folder `cost.json` sidecar alongside its ledger append: a single JSON object keyed by phase kind (`spec` for a spec folder; `plan` and/or `execute` for a plan folder), each value the same record shape as the matching `cost.jsonl` row, scoped to that one run. A plan or execute write replaces only its own key and preserves any sibling key's value untouched, so a plan folder's sidecar accumulates both phases without one write clobbering the other.

A vintage `cost.md` that predates this ledger and the sidecar gets one `source: "backfill"` row per `## SPEC` / `## Planning` / `## Execution` section (never `## Total`, a derived grand-sum rather than its own phase).

## Pairs with

- [[Token Cost Readout]]: the `by_model` pricing surfaces (rate table, shared pricing lib, tally-time vs roll-up-time dollar figures) built on top of this ledger.
- [[Telemetry]]: the ledger's place among GAIA's other telemetry streams.
- [[Task Orchestration]]: the merge-time reconcile and retention lifecycle that eventually removes the folder this ledger's rows outlive.
