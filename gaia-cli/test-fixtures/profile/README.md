# profile/ fixtures

Synthetic NDJSON fixtures that drive the pattern-detection tests in
`gaia-cli/src/profile/__tests__/`. Phase 6's smoke harness reads
`multi-area.jsonl` end-to-end.

## Regenerating

```bash
pnpm fixtures:build
```

Fixtures are checked into git AND regenerable. Build emits deterministic
output: timestamps anchor to virtual `now = 2026-05-07T12:00:00.000Z` and
ULIDs use a seeded PRNG, so two builds produce byte-identical files.

Tests pin the same virtual `now` via the detector's `generatedAt`
parameter so the rolling-window aggregator sees the same daysAgo
distribution that the builder emitted.

## Fixture catalog

| File | UAT | Drives |
|------|-----|--------|
| `below-threshold.jsonl` | UAT-029 | sample-count gate |
| `articulation-fire.jsonl` | UAT-030 | articulation-gap fires |
| `articulation-fade.jsonl` | UAT-031 | articulation-gap fades |
| `flake-downweight.jsonl` | UAT-032 | flake_suspected weight |
| `multi-area.jsonl` | smoke | end-to-end shape |

## Per-fixture intent and expected detector output

### `below-threshold.jsonl` (UAT-029)

10 events total: 4 `needs_context_returned` for `visual` with
`unclear_acceptance_criteria` plus 6 `uat_pass` events for `visual` as
denominator filler.

Expected: `articulation_gap` for `visual` →
`{sample_count: 4, strength: null}` → "below sample threshold (N=4, min 10)".

No active pattern. No active adaptation.

### `articulation-fire.jsonl` (UAT-030)

50 events total: 30 `needs_context_returned` for `visual` with
`unclear_acceptance_criteria` plus 20 `uat_pass` for `visual` as
denominator filler. Rate = 30 / 50 = 0.60.

Expected: `articulation_gap` for `visual` →
`{sample_count: 30, strength: 1.0}` (saturates at `RATE_TARGET = 0.30`).

`profile.md` lists `articulation_gap` under `## Active patterns` and
`po_socratic_depth_increased` under `## Active adaptations`.

### `articulation-fade.jsonl` (UAT-031)

Two-segment fixture across the rolling 30-day window:

- **Prior weeks 1-3 (days 7..28):** 30 `needs_context_returned` + 45
  `uat_pass` for `visual` → 75 visual events, rate = 30/75 = 0.40.
- **Week 0 (days 0..6):** 2 `needs_context_returned` + 9 `uat_pass`
  for `visual` → 11 visual events, rate ≈ 2/11 ≈ 0.18.

30-day aggregate: 32 needs_context / 86 visual events ≈ 0.372 → strength
≈ `min(1, 0.372 / 0.30)` ≈ 1.0 — passes threshold pre-fade.

Improvement = (0.40 - 0.18) / 0.40 = 0.55 → fade_factor =
`max(0, 1 - 0.55 / 0.50)` = 0 → effective strength = 0.

Expected: `articulation_gap` fires on the 30-day aggregate but the fade
multiplier zeroes effective strength → adaptation moves to
`## Faded adaptations` and stops injecting.

### `flake-downweight.jsonl` (UAT-032)

48 events total in the `react` area: 4 `uat_fail` `assertion`,
4 `uat_fail` `exception`, 16 `uat_fail` `flake_suspected`, plus
24 `uat_pass` denominator filler.

`weightForUatFail` returns `0.25` for `flake_suspected` and `1.0`
otherwise. Effective failure count: `4 + 4 + (16 * 0.25) = 12`. Without
downweighting: 24.

Expected: pattern aggregator that consumes `uat_fail` reflects the
downweighted count. The detector tests assert `weightForUatFail` matches
`FLAKE_DOWNWEIGHT = 0.25` for `flake_suspected` events.

### `multi-area.jsonl`

Cross-cutting fixture: every one of the 8 mentorship event types appears
across the four area tags `visual` / `react` / `form` / `typescript`.
Volume is deliberately modest (24 events total) — this fixture exists
for the Phase 6 smoke harness to walk an end-to-end shape; it is NOT
shaped to fire any specific pattern.

Expected: detectors run without errors; no pattern fires above the
sample threshold.

## Conventions

- Each line is a full mentorship envelope: universal envelope fields
  plus `_local: { fixture: true }` plus an event-type-specific payload.
- Every line satisfies `EnvelopeSchema.safeParse` AND
  `MentorshipPayloadByType[event_type].safeParse(payload)`.
- `event_id` ULIDs come from a seeded PRNG: distinct, deterministic,
  but not content-derived. Idempotency is verified elsewhere; these
  fixtures verify detector aggregation only.
- `project_id = 'a' * 32`, `session_hash = 'b' * 32`.
- No trailing newline on the file.
