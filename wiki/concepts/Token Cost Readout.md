---
type: concept
title: Token Cost Readout
status: active
created: 2026-07-04
updated: 2026-09-30
tags: [concept, cost, token-accounting]
---

# Token Cost Readout

GAIA prices the ground-truth token usage of each workflow action into a dollar estimate: `/gaia-spec`, `/gaia-plan`, KICKOFF plan execution, and each maintenance command the tally's `--command` closed set names (see [[Cost Data Contract]]). Two scripts share the pricing math: `.gaia/scripts/token-tally.sh` writes a per-action ledger record and, for `/gaia-spec`, `/gaia-plan`, and plan execution, also prices a generation-time `dollars` figure into each `cost.json` sidecar record it writes, alongside the matching `cost.jsonl` row (the write half); `.gaia/scripts/token-rollup.sh` reads the ledger, sums a full-cycle spec / plan / execute / total breakdown, and appends a dollar figure (the read half). At `gh pr merge` a `PostToolUse` hook renders two readouts, the per-PR cost block from the usage ledger and then the roll-up; the roll-up is also available on demand from the command line.

The write half is documented in full in [[Cost Data Contract]]; this page covers the surfaces the dollar estimate rests on: the `by_model` field, the machine-local rate table, the shared pricing lib both scripts source, the roll-up's dollar block, and the tally's own per-run dollar figure.

## The `by_model` ledger field

Each ledger record (appended to the machine-local, gitignored `.gaia/local/telemetry/cost.jsonl`, resolved to the main checkout so it survives a linked worktree) carries the aggregate token buckets used by the token readout, and, when attribution succeeds, a `by_model` object used for pricing. The record's other fields, the sibling `by_agent_type` attribution, `dollars`, `rate_table_id`, `git_branch`, `project`, `seq`, and `final`, are documented in full in [[Cost Data Contract]]; this page covers only the pricing-relevant surfaces.

```json
"by_model": {
  "claude-opus-4-8":   { "fresh_input": 300, "cache_write_5m": 40, "cache_write_1h": 360, "cache_read": 3000, "output": 30 },
  "claude-sonnet-4-6": { "fresh_input": 30,  "cache_write_5m": 10, "cache_write_1h": 20,  "cache_read": 3000, "output": 3 }
}
```

Pricing needs per-model, per-bucket counts because models and cache TTLs price differently, so `by_model` keys each model id to five buckets. The write side sums the API's recorded usage per model: `fresh_input` from `input_tokens`, `cache_read` from `cache_read_input_tokens`, `output` from output tokens, and the cache-write count split by TTL: `cache_write_5m` from `cache_creation.ephemeral_5m_input_tokens` and `cache_write_1h` from `cache_creation.ephemeral_1h_input_tokens` (falling back to the flat `cache_creation_input_tokens` when the split is absent). This 5m/1h split is what the top-level aggregate `cache_write` bucket collapses; the roll-up needs it separated because the two TTLs carry different multipliers.

`token-tally.sh` builds this same shape in-process (its `BY_MODEL` variable) before any record reaches the ledger, and prices its own per-section cost line straight from that in-process object, the same object that goes on to become the ledger record's `by_model` field.

A record whose attribution fails omits `by_model` entirely rather than writing an empty object. A missing `by_model` therefore reads as "this row predates per-model attribution", which the dollar block treats distinctly from a corrupt or unreadable input.

## The rate table

Pricing reads a **machine-local** table at `.gaia/local/telemetry/token-rates.json`, resolved to the main checkout (a provisioned worktree reaches it through its `.gaia/local` symlink; see [[Worktrees]]). The file is uncommitted. It is seeded as a byte copy of the main checkout's `.gaia/scripts/token-rates.json`, which stays the single file the maintainer edits and ships to adopters. Both scripts resolve the table through the same lib call, so the tally and the roll-up price from one file.

- **Sync.** When the distributed file changes, a per-model three-way merge brings the local table along: GAIA's new row replaces any model the adopter never edited, a row the adopter edited is kept, an adopter-added model is kept, a new model is added, and no local row is ever dropped. `cache_multipliers` follow the same rule as one value. When the merged result equals GAIA's table, the local file is GAIA's bytes, so `rate_table_id` matches the committed table's id.
- **Custom prices** belong in the local table. A price written into the distributed file is treated as GAIA's and replaced on a later sync. A deleted local row comes back on the next sync or heal. Reverting the feature leaves the local file inert.
- **Heal.** When a run prices a `claude-*` model the local table lacks, the pricing path makes one request to `https://raw.githubusercontent.com/gaia-react/gaia/main/.gaia/scripts/token-rates.json`, the public distributed table on `main`. Each candidate row is validated per model; a row that passes is written into the local table marked `"source": "feed"` (the price math ignores the mark), refreshed on a later fetch while the adopter has not edited it, and the same run is priced with the healed table. A failed request leaves the table untouched and backs off before trying again.
- **What a request discloses.** Your IP address, curl's default User-Agent, and the request time. It reveals that a miss happened, never which model or any usage. `.gaia/scripts/check-updates.sh` already contacts api.github.com on the same footing.
- **Switches.** `GAIA_RATES_FEED_DISABLE=1` turns the request off; only the value `1` does. `GAIA_RATES_FEED_URL` overrides the URL, and only `https://` or `file://` is accepted. The timeout, size cap, and backoff live in `.gaia/scripts/token-rates-feed-lib.sh`, which is their source of truth.
- **`--rate-table <path>`** on either script prices from that file with no seed, sync, heal, or write. This is how a maintainer prices a branch's edit of the distributed table.
- **Readonly fallback.** With no main checkout to resolve (a bare repository's worktree), the lib prices from the current tree's distributed table and writes nothing.

This file is a **public read contract**: any reader pricing token usage, GAIA's own scripts or an external re-implementation, parses this exact shape rather than reverse-engineering shell internals.

```json
{
  "cache_multipliers": { "read": 0.1, "write_5m": 1.25, "write_1h": 2.0 },
  "models": {
    "claude-opus-4-8": [ { "input": 5, "output": 25 } ],
    "claude-opus-5-5": [ { "input": 4, "output": 20, "cache_read_multiplier": 0.05 } ],
    "claude-example-intro": [
      { "input": 2, "output": 10, "effective_through": "2026-08-31" },
      { "input": 3, "output": 15 }
    ]
  }
}
```

- **Table shape.** `models` maps each model id to a list of rate entries, each carrying an `input` and `output` price per million tokens, an optional `effective_through`, and an optional `cache_read_multiplier`. `cache_multipliers` is a sibling top-level object carrying the four bucket multipliers. A reader parses exactly these two top-level keys.
- **Cache multipliers scale the input rate, value-coupled to the table.** `fresh_input` prices at `input`; `cache_read` at `input × cache_read_multiplier` when the winning rate entry carries one (the price card discounts cache reads on some models below the standard factor), else at `input × cache_multipliers.read`; `cache_write_5m` at `input × cache_multipliers.write_5m`; `cache_write_1h` at `input × cache_multipliers.write_1h`; `output` at `output`. Every bucket is summed and divided by 1e6. The table file that priced, not this description, is the source of truth for the multiplier values: a reader always takes the live values from the file, so the contract holds even after those values change.
- **Effective-dated intro pricing.** A model with introductory pricing lists the intro entry first with an `effective_through` date, then the sticker entry with none. Each script selects the entry whose window covers its own run-time anchor (the roll-up's per-record timestamp, the tally's own generation stamp), comparing at **day granularity**: the anchor's date (its `[0:10]` slice) against `effective_through`. `effective_through` is an **inclusive** upper bound, an entry is a candidate whenever the anchor's date is less than or equal to it, and the final entry with no `effective_through` is the open-ended sticker rate that wins once no earlier entry's window covers the anchor.
- **The `rate_table_id` recipe.** `sha256` of the raw bytes of the table that priced, truncated to the first 16 hex characters, prefixed `sha256:` (e.g. `sha256:1a2b3c4d5e6f7890`). `.gaia/scripts/token-pricing-lib.sh`'s `gaia_hash16` and `gaia_rate_table_id` are the implementation anchor. This is the exact identity a downstream reader uses to re-price a stored `by_model` under a known rate card.
- **Implementation source of truth for selection semantics.** `.gaia/scripts/token-pricing-lib.sh`'s `rate_window` and `priced_row` jq definitions (detailed in the next section) are the authoritative implementation of window selection and per-bucket arithmetic; this section is the contract they satisfy, not a parallel spec that can drift from them.

## Shared pricing lib

The rate-table resolution helpers and the per-model, per-bucket dollar arithmetic (the `rate_window` and `priced_row` jq definitions) live in one sourced shell lib, `.gaia/scripts/token-pricing-lib.sh`. It sources two sibling libs relative to its own path: `.gaia/scripts/token-rates-local-lib.sh` (seed, corrupt-file recovery, and the three-way sync of the local table) and `.gaia/scripts/token-rates-feed-lib.sh` (the bounded heal request). Both `token-rollup.sh` and `token-tally.sh` source the pricing lib relative to their own script path (`$(dirname "${BASH_SOURCE[0]}")/token-pricing-lib.sh`), which resolves correctly from inside a linked worktree as well as the main checkout. This is the single source of the pricing math: the roll-up's full-cycle sum and the tally's per-section snapshot run the identical `rate_window` window-selection logic and the identical `priced_row` per-bucket multiplication.

`gaia_resolve_rate_table`, which locates the current tree's distributed table via `git rev-parse --show-toplevel`, survives only as the fallback for a partial update that left the two new libs absent.

## The roll-up's dollar block

When at least one record carries `by_model`, the roll-up appends an `Est. cost (USD)` block beneath the token block, mirroring its per-action-plus-total shape:

```
  Est. cost (USD):
    execute:   $0.88
    Total:     $0.88
```

The block never fabricates a number. Anything it cannot price truthfully surfaces as one of two kinds of marker: an **unavailable** line (nothing could be priced) or a **lower bound** line (a real figure that undercounts because some input was skipped).

| Marker | Kind | Trigger |
| --- | --- | --- |
| `unavailable (records predate per-model attribution)` | unavailable | No record for the feature carries `by_model`, so nothing is priceable. Token lines still render their real totals. |
| `unavailable (rate table unreadable)` | unavailable | Neither the local table nor the distributed table could be read. |
| `(lower bound: unpriced model(s) <names>)` | lower bound | A `claude-` model in the ledger is absent from the local table after any heal; it contributes $0 and is named. |
| `(lower bound: a session lacked a run-time anchor)` | lower bound | A session has no timestamp, so no effective-dated rate can be selected; it contributes $0. |
| `(partial lower bound: some records predate per-model attribution)` | lower bound | Mixed provenance: some rows are priced, others predate attribution and are excluded from the dollar sum (their token totals stay intact). |
| `(partial lower bound: …)` | lower bound | The token readout itself is partial (some ledger input was unreadable, corrupt, or lacked timing), so the dollar figure inherits that partial signal. |

A ledger key that does not match `claude-` is silently ignored: it contributes no price and raises no marker, so a non-model bookkeeping key never distorts the estimate.

Like the token readout, the dollar block runs under a strict never-block contract: every failure mode degrades to a marked figure and the roll-up always exits 0.

## The tally-time dollar figure

There is no per-section markdown cost line anymore: for `/gaia-spec`, `/gaia-plan`, and plan execution, `token-tally.sh`'s dollar estimate, priced from that run's own in-process `by_model`, lives in the `cost.json` sidecar record's `dollars` field and in the matching `cost.jsonl` row alongside it, not in any per-folder markdown file. `token-tally.sh` still prints its own four-bucket-plus-total-plus-elapsed stdout block for these three actions (plus a partial marker when the token read is incomplete), but the workflow does not restate that block to the user.

There are two assembly paths for the pinned `Cost:` line, depending on which action produced it:

- **`spec` / `plan` / `execute`.** The tally prints its four-bucket block; the caller reads `<dollars>` out of the `cost.json` sidecar's record and assembles the pinned line itself. `/gaia-spec`, `/gaia-plan`, and the executed-plan closeout each report exactly one pinned line: `Cost: ~<total> tokens, $<dollars>, <elapsed>`, with a per-stage dollar breakdown appended when the roll-up prices more than one stage (e.g. `(spec $0.40 + plan $0.48)`).
- **`command`.** A maintenance-command record has no sidecar for the caller to read a figure out of, so the tally prints the **finished line itself** on stdout, in place of the four-bucket block, and the caller relays it **verbatim** as the last line of its report. This is what keeps every surface byte-identical by construction.

`<total>` abbreviates the token count to millions with one decimal and a `~` prefix (`~5.2M`). `<dollars>` renders `$X.XX`; an unpriceable figure renders the literal `cost unavailable` in its place. `<elapsed>` renders `<N>h<M>m<S>s`, dropped along with its preceding comma when unavailable. A partial figure appends ` (partial: lower bound)`. A command line carries no per-stage breakdown parenthetical, a command run has exactly one stage; only the full-cycle roll-up line carries one. Never fabricated: an unpriceable dollar figure always renders `cost unavailable`, and a partial/lower-bound figure always carries that marker through. Every surface emitting this line is kept in sync so it reads identically regardless of which workflow emitted it.

## Snapshot vs live

The sidecar record's `dollars` is a generation-time snapshot: it is frozen at the rate whose effective window covers the session's run-time anchor at the moment the record is written. The `execute` key refreshes on every orchestrator commit that rewrites the sidecar (each write replaces only its own key and preserves the sibling, see [[Cost Data Contract]]), so its snapshot moves forward each time; the `spec` and `plan` keys are each written once and stay fixed after that.

The roll-up's dollar block is a read-time reprice: it recomputes from the ledger every time it runs, against whatever the machine-local rate table holds at that moment. Both surfaces select a rate the same way, effective-dating on the run-time anchor through the shared lib's `rate_window` logic, so the two figures agree for a session most of the time. They can still diverge for one session: the rate table can change between the tally's write and a later merge-time roll-up, or the roll-up's ledger dedup can select a different underlying row than the one the tally priced. The roll-up is the authoritative live figure; the sidecar's `dollars` field is a per-phase snapshot of what pricing looked like when that record was written.

## Tally-time degrade markers

`token-tally.sh` degrades the record's `dollars` field to `null` under the same never-block contract as the roll-up. Most of those degrades carry no marker text, only the raw number or `null`, because there is no per-folder file left to render a marker line into.

An unpriced model is the exception, and it is the one degrade whose figure is silently plausible rather than visibly absent: a mixed-model run prices its other models normally and drops the missing one's share, so the total looks like an ordinary number. The tally names every such model in an `unpriced` array on the record (and in the `cost.json` sidecar), and appends `(lower bound: unpriced model(s) <names>)` to whichever stdout shape it printed. The marker keys on the unpriced model, never on a `$0.00` total, so it fires on exactly the mixed runs a total-keyed check would stay quiet about. Because the array names the models on the row itself, a later pass finds the affected rows by field rather than by re-deriving which keys the table was missing then.

| Trigger | Record effect |
| --- | --- |
| Neither the local table nor the distributed table could be read | `dollars: null` |
| The section's `by_model` is empty (no per-model attribution for the session) | `dollars: null` |
| A `claude-` model in the section's `by_model` is absent from the local table after any heal | `dollars` prices the remaining models and omits the absent one's share, a lower bound. The absent models are named in an `unpriced` array on both the record and the sidecar, and the stdout line carries the lower-bound marker |
| The section's own token render is itself partial | `dollars` prices whatever `by_model` data is available, silently, with no marker recorded (the token partial marker on the bucket totals still renders independently) |

A reader who wants a human-facing description of any of the other degrades, rather than a bare number, reads the roll-up's dollar-block markers above, which cover the same triggers and render as text at read time.

## Per-PR and initiative readouts

The per-PR block and the initiative readouts come from the usage ledger, not from `cost.jsonl`; [[Usage Ledger]] documents them. Their dollars are repriced at read time from the raw token buckets through the same shared pricing lib, so they follow the machine-local rate table the same way the roll-up does. `bash .gaia/scripts/usage.sh` prints its subcommands.

## Pairs with

- [[Usage Ledger]]: per-message usage capture, attribution, and the per-PR and initiative readouts priced through this page's lib.
- [[Cost Data Contract]]: the full `cost.jsonl` record schema, the execute aggregation rule, and the retention rules for what survives merge.
- [[PR Merge Workflow]]: the merge-time `PostToolUse` hook that renders the full-cycle roll-up.
- [[Task Orchestration]]: KICKOFF plan execution, whose per-commit cost the ledger accumulates.
