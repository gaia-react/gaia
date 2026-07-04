---
type: concept
title: Token Cost Readout
status: active
created: 2026-07-04
updated: 2026-07-04
tags: [concept, telemetry, cost, token-accounting]
---

# Token Cost Readout

GAIA prices the ground-truth token usage of each workflow action (`/gaia-spec`, `/gaia-plan`, and KICKOFF plan execution) into a dollar estimate. Two scripts split the work: `.gaia/scripts/token-tally.sh` writes a per-action ledger record (the write half), and `.gaia/scripts/token-rollup.sh` reads the ledger, sums a full-cycle spec / plan / execute / total breakdown, and appends a dollar figure (the read half). The roll-up renders at `gh pr merge` via a `PostToolUse` hook and on demand from the command line.

The write half is documented alongside the rest of the tally in [[Telemetry]]'s storage model; this page covers the three surfaces the dollar estimate rests on: the `by_model` ledger field, the committed rate table, and the dollar block with its degrade markers.

## The `by_model` ledger field

Each ledger record (appended to the machine-local, gitignored `.gaia/local/telemetry/tokens.jsonl`, resolved to the main checkout so it survives a linked worktree) carries the aggregate token buckets used by the token readout, and, when attribution succeeds, a `by_model` object used for pricing:

```json
"by_model": {
  "claude-opus-4-8":   { "fresh_input": 300, "cache_write_5m": 40, "cache_write_1h": 360, "cache_read": 3000, "output": 30 },
  "claude-sonnet-4-6": { "fresh_input": 30,  "cache_write_5m": 10, "cache_write_1h": 20,  "cache_read": 3000, "output": 3 }
}
```

Pricing needs per-model, per-bucket counts because models and cache TTLs price differently, so `by_model` keys each model id to five buckets. The write side sums the API's recorded usage per model: `fresh_input` from `input_tokens`, `cache_read` from `cache_read_input_tokens`, `output` from output tokens, and the cache-write count split by TTL: `cache_write_5m` from `cache_creation.ephemeral_5m_input_tokens` and `cache_write_1h` from `cache_creation.ephemeral_1h_input_tokens` (falling back to the flat `cache_creation_input_tokens` when the split is absent). This 5m/1h split is what the top-level aggregate `cache_write` bucket collapses; the roll-up needs it separated because the two TTLs carry different multipliers.

A record whose attribution fails omits `by_model` entirely rather than writing an empty object. A missing `by_model` therefore reads as "this row predates per-model attribution", which the dollar block treats distinctly from a corrupt or unreadable input.

## The rate table

Rates live in a **committed** table at `.gaia/scripts/token-rates.json`, so they ship to adopters and version with the code. The roll-up locates it via `git rev-parse --show-toplevel`, which resolves the table from inside a linked worktree as well as the main checkout (no override needed).

```json
{
  "cache_multipliers": { "read": 0.1, "write_5m": 1.25, "write_1h": 2.0 },
  "models": {
    "claude-opus-4-8": [ { "input": 5, "output": 25 } ],
    "claude-sonnet-5": [
      { "input": 2, "output": 10, "effective_through": "2026-08-31" },
      { "input": 3, "output": 15 }
    ]
  }
}
```

- **Per-model, per-MTok rates.** Each model id maps to a list of rate entries carrying an `input` and `output` price per million tokens.
- **Cache multipliers scale the input rate.** `fresh_input` prices at `input`; `cache_read` at `input × 0.1`; `cache_write_5m` at `input × 1.25`; `cache_write_1h` at `input × 2.0`; `output` at `output`. Every bucket is summed and divided by 1e6.
- **Effective-dated intro pricing.** A model with introductory pricing lists the intro entry first with an `effective_through` date, then the sticker entry with none. The roll-up selects the entry whose window covers the record's run-time anchor (its timestamp), treating `effective_through` as an inclusive upper bound; the final entry with no `effective_through` is the open-ended sticker rate.

## The dollar block

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
| `unavailable (rate table unreadable)` | unavailable | The committed rate table is missing or unparseable. |
| `(lower bound: unpriced model(s) <names>)` | lower bound | A `claude-` model in the ledger is absent from the rate table; it contributes $0 and is named. |
| `(lower bound: a session lacked a run-time anchor)` | lower bound | A session has no timestamp, so no effective-dated rate can be selected; it contributes $0. |
| `(partial lower bound: some records predate per-model attribution)` | lower bound | Mixed provenance: some rows are priced, others predate attribution and are excluded from the dollar sum (their token totals stay intact). |
| `(partial lower bound: …)` | lower bound | The token readout itself is partial (some ledger input was unreadable, corrupt, or lacked timing), so the dollar figure inherits that partial signal. |

A ledger key that does not match `claude-` is silently ignored: it contributes no price and raises no marker, so a non-model bookkeeping key never distorts the estimate.

Like the token readout, the dollar block runs under a strict never-block contract: every failure mode degrades to a marked figure and the roll-up always exits 0.

## Pairs with

- [[Telemetry]]: the token tally's storage model and the `.gaia/local/telemetry/` streams the ledger lives beside.
- [[PR Merge Workflow]]: the merge-time `PostToolUse` hook that renders the full-cycle roll-up.
- [[Task Orchestration]]: KICKOFF plan execution, whose per-commit cost the ledger accumulates.
