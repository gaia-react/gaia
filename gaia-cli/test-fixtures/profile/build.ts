import {factory as ulidFactory} from 'ulid';
/**
 * Programmatic builder for the profile pattern-detection fixture set.
 *
 * Run via `pnpm fixtures:build`. Emits one JSONL file per scenario into
 * `gaia-cli/test-fixtures/profile/`. Every line is a full mentorship-event
 * envelope that satisfies `EnvelopeSchema` plus the matching
 * `MentorshipPayloadByType[event_type]` schema from `gaia-cli/src/schemas/`.
 *
 * Determinism:
 *   - Virtual `now` is fixed at `VIRTUAL_NOW` so tests that pin the same
 *     value via the detector's `generatedAt` parameter aggregate against
 *     the same window.
 *   - ULIDs are generated via a seeded PRNG so re-running the build
 *     yields byte-identical files. Fixtures are checked into git; CI
 *     diff stays clean across runs.
 *
 * Per `task-fixtures.md`, fixtures use random-looking distinct ULIDs (not
 * the content-derived dedup path). Idempotency is verified elsewhere; these
 * fixtures verify detector aggregation.
 */
import {writeFileSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const FIXTURE_DIR = path.dirname(fileURLToPath(import.meta.url));

// Pinned virtual `now` shared with detector tests.
const VIRTUAL_NOW = new Date('2026-05-07T12:00:00.000Z');

const PROJECT_ID = 'a'.repeat(32);
const SESSION_HASH = 'b'.repeat(32);

// 32-bit linear-congruential PRNG seeded with a fixed value. Returns a
// number in [0, 1) as ulid's `PRNG` interface requires. Stable across
// Node versions; no dependency on `Math.random`.
//
// Uses modulo 2^32 instead of bitwise `>>> 0` to satisfy the `no-bitwise`
// project rule; numerically identical to the standard 32-bit LCG.
const MODULUS_2_32 = 4_294_967_296;
const LCG_MULTIPLIER = 1_664_525;
const LCG_INCREMENT = 1_013_904_223;

const seededPrng = (seed: number): (() => number) => {
  let state = seed % MODULUS_2_32;

  return () => {
    state = (state * LCG_MULTIPLIER + LCG_INCREMENT) % MODULUS_2_32;

    return state / MODULUS_2_32;
  };
};

const ulid = ulidFactory(seededPrng(0xc0_ff_ee_42));

type AgentType =
  | 'Curator'
  | 'Custodian'
  | 'human'
  | 'Junior'
  | 'Lead'
  | 'PO'
  | 'Reviewer'
  | 'Senior'
  | 'Steward';

type EnvelopeArgs = {
  agentType?: AgentType;
  daysAgo: number;
  eventType: MentorshipEventType;
  hourOffset?: number;
  payload: Record<string, unknown>;
};

type MentorshipEventType =
  | 'blocked_returned'
  | 'code_review_audit_finding'
  | 'needs_context_returned'
  | 'plan_revised'
  | 'spec_amended'
  | 'time_to_resolved_spec'
  | 'uat_fail'
  | 'uat_pass';

const ONE_DAY_MS = 86_400_000;
const ONE_HOUR_MS = 3_600_000;

const isoTimestampDaysAgo = (daysAgo: number, hourOffset = 0): string => {
  const ms =
    VIRTUAL_NOW.getTime() - daysAgo * ONE_DAY_MS + hourOffset * ONE_HOUR_MS;

  return new Date(ms).toISOString();
};

// Anchor ULID timestamp portion to VIRTUAL_NOW so the ULID's high bits
// are stable across builds; the random portion is already deterministic
// via the seeded PRNG above.
const ULID_SEED_TIME = VIRTUAL_NOW.getTime();

const buildLine = (args: EnvelopeArgs): string => {
  const envelope = {
    _local: {fixture: true},
    agent_type: args.agentType ?? 'Senior',
    event_id: ulid(ULID_SEED_TIME),
    event_type: args.eventType,
    payload: args.payload,
    project_id: PROJECT_ID,
    schema_version: 1,
    session_hash: SESSION_HASH,
    timestamp: isoTimestampDaysAgo(args.daysAgo, args.hourOffset ?? 0),
  };

  return JSON.stringify(envelope);
};

const writeJsonl = (filename: string, lines: string[]): void => {
  const filePath = path.join(FIXTURE_DIR, filename);
  // Single JSON object per line; no trailing newline on the file.
  writeFileSync(filePath, lines.join('\n'));
};

// ---------------------------------------------------------------------------
// below-threshold.jsonl (UAT-029)
// ---------------------------------------------------------------------------
//
// 4 needs_context_returned events for `visual` (below MIN_SAMPLE_COUNT=10).
// Plus a handful of unrelated events so the totals computation has a
// non-empty denominator. Detector should report:
//   articulation_gap visual → sample_count: 4, strength: null,
//   "below sample threshold (N=4, min 10)".
const buildBelowThreshold = (): string[] => {
  const lines: string[] = [];

  // 4 needs_context_returned visual events scattered across 30-day window.
  const ncDaysAgo = [2, 9, 17, 24];

  for (const [index, daysAgo] of ncDaysAgo.entries()) {
    lines.push(
      buildLine({
        daysAgo,
        eventType: 'needs_context_returned',
        payload: {
          agent_type: 'Senior',
          area_tags: ['visual'],
          context_request_class: 'unclear_acceptance_criteria',
          spec_id: 'SPEC-101',
          task_id: `TASK-bt-${String(index + 1).padStart(3, '0')}`,
        },
      })
    );
  }

  // 6 unrelated visual uat_pass events as denominator filler.
  for (let index = 0; index < 6; index += 1) {
    lines.push(
      buildLine({
        daysAgo: 1 + index * 4,
        eventType: 'uat_pass',
        hourOffset: 1,
        payload: {
          area_tags: ['visual'],
          attempts: 1,
          spec_id: 'SPEC-101',
          task_id: `TASK-bt-pass-${String(index + 1).padStart(3, '0')}`,
          uat_id: `UAT-${String(200 + index).padStart(3, '0')}`,
        },
      })
    );
  }

  return lines;
};

// ---------------------------------------------------------------------------
// articulation-fire.jsonl (UAT-030)
// ---------------------------------------------------------------------------
//
// 30 needs_context_returned events for `visual` + 20 other visual events
// → 50 total visual events, rate = 30/50 = 0.60 → strength = min(1, 0.60/0.30) = 1.0.
// Detector should fire `articulation_gap` for `visual` with sample_count=30,
// strength=1.0, linking adaptation `po_socratic_depth_increased`.
const buildArticulationFire = (): string[] => {
  const lines: string[] = [];

  // 30 needs_context_returned events spread across 30-day window.
  for (let index = 0; index < 30; index += 1) {
    lines.push(
      buildLine({
        daysAgo: 1 + index, // days 1..30
        eventType: 'needs_context_returned',
        payload: {
          agent_type: 'Senior',
          area_tags: ['visual'],
          context_request_class: 'unclear_acceptance_criteria',
          spec_id: 'SPEC-102',
          task_id: `TASK-af-nc-${String(index + 1).padStart(3, '0')}`,
        },
      })
    );
  }

  // 20 visual uat_pass events as denominator filler. Distinct hour offsets
  // so timestamps don't collide with the needs_context lines.
  for (let index = 0; index < 20; index += 1) {
    lines.push(
      buildLine({
        daysAgo: 1 + index,
        eventType: 'uat_pass',
        hourOffset: 2,
        payload: {
          area_tags: ['visual'],
          attempts: 1,
          spec_id: 'SPEC-102',
          task_id: `TASK-af-pass-${String(index + 1).padStart(3, '0')}`,
          uat_id: `UAT-${String(300 + index).padStart(3, '0')}`,
        },
      })
    );
  }

  return lines;
};

// ---------------------------------------------------------------------------
// articulation-fade.jsonl (UAT-031)
// ---------------------------------------------------------------------------
//
// Two-segment fixture:
//   - Prior weeks 1-3 (days 7..28): 30 needs_context out of 75 visual events
//     → rate 0.40
//   - Prior week 0 (days 0..6): 2 needs_context out of 11 visual events
//     → rate ≈ 0.18
// Improvement = (0.40 - 0.18) / 0.40 = 0.55 → fade_factor = max(0, 1 - 0.55/0.50) = 0.
// 30-day aggregate: 32 needs_context / 86 visual ≈ 0.372 → strength ≈ 1.0
// passes threshold pre-fade, but fade_factor = 0 zeroes effective strength →
// adaptation moves to `## Faded adaptations`.
const buildArticulationFade = (): string[] => {
  const lines: string[] = [];

  // Prior weeks 1-3: 30 needs_context_returned visual events, days 7..28.
  for (let index = 0; index < 30; index += 1) {
    const daysAgo = 7 + Math.floor(index * (21 / 30)); // 7..27 spread

    lines.push(
      buildLine({
        daysAgo,
        eventType: 'needs_context_returned',
        hourOffset: index % 12,
        payload: {
          agent_type: 'Senior',
          area_tags: ['visual'],
          context_request_class: 'unclear_acceptance_criteria',
          spec_id: 'SPEC-103',
          task_id: `TASK-fade-nc-${String(index + 1).padStart(3, '0')}`,
        },
      })
    );
  }

  // Prior weeks 1-3 denominator filler: 45 visual uat_pass → 75 total visual.
  for (let index = 0; index < 45; index += 1) {
    lines.push(
      buildLine({
        daysAgo: 7 + Math.floor(index * (21 / 45)),
        eventType: 'uat_pass',
        hourOffset: 13 + (index % 10),
        payload: {
          area_tags: ['visual'],
          attempts: 1,
          spec_id: 'SPEC-103',
          task_id: `TASK-fade-pass-${String(index + 1).padStart(3, '0')}`,
          uat_id: `UAT-${String(400 + index).padStart(3, '0')}`,
        },
      })
    );
  }

  // Week 0: 2 needs_context_returned visual events, days 0..6.
  for (let index = 0; index < 2; index += 1) {
    lines.push(
      buildLine({
        daysAgo: 1 + index * 3, // days 1, 4
        eventType: 'needs_context_returned',
        payload: {
          agent_type: 'Senior',
          area_tags: ['visual'],
          context_request_class: 'unclear_acceptance_criteria',
          spec_id: 'SPEC-103',
          task_id: `TASK-fade-recent-nc-${String(index + 1).padStart(3, '0')}`,
        },
      })
    );
  }

  // Week 0 denominator filler: 9 visual uat_pass → 11 total recent visual.
  for (let index = 0; index < 9; index += 1) {
    lines.push(
      buildLine({
        daysAgo: index % 7,
        eventType: 'uat_pass',
        hourOffset: 5 + (index % 4),
        payload: {
          area_tags: ['visual'],
          attempts: 1,
          spec_id: 'SPEC-103',
          task_id: `TASK-fade-recent-pass-${String(index + 1).padStart(3, '0')}`,
          uat_id: `UAT-${String(500 + index).padStart(3, '0')}`,
        },
      })
    );
  }

  return lines;
};

// ---------------------------------------------------------------------------
// flake-downweight.jsonl (UAT-032)
// ---------------------------------------------------------------------------
//
// 4 uat_fail assertion + 4 uat_fail exception + 16 uat_fail flake_suspected.
// Without downweighting → 24 effective failures.
// With FLAKE_DOWNWEIGHT=0.25 → 4 + 4 + 16*0.25 = 12 effective.
// `weightForUatFail` returns 0.25 for flake_suspected and 1.0 otherwise.
const buildFlakeDownweight = (): string[] => {
  const lines: string[] = [];

  type FailureClass = 'assertion' | 'exception' | 'flake_suspected';

  const groups: {
    count: number;
    failureClass: FailureClass;
    tagPrefix: string;
  }[] = [
    {count: 4, failureClass: 'assertion', tagPrefix: 'assert'},
    {count: 4, failureClass: 'exception', tagPrefix: 'except'},
    {count: 16, failureClass: 'flake_suspected', tagPrefix: 'flake'},
  ];

  let dayCounter = 0;

  for (const group of groups) {
    for (let index = 0; index < group.count; index += 1) {
      lines.push(
        buildLine({
          daysAgo: 1 + (dayCounter % 28),
          eventType: 'uat_fail',
          hourOffset: dayCounter % 24,
          payload: {
            area_tags: ['react'],
            attempts: 1,
            failure_class: group.failureClass,
            spec_id: 'SPEC-104',
            task_id: `TASK-fl-${group.tagPrefix}-${String(index + 1).padStart(3, '0')}`,
            uat_id: `UAT-${String(600 + dayCounter).padStart(3, '0')}`,
          },
        })
      );
      dayCounter += 1;
    }
  }

  // Denominator filler: 24 react uat_pass events so failure rate is computable.
  for (let index = 0; index < 24; index += 1) {
    lines.push(
      buildLine({
        daysAgo: 1 + (index % 28),
        eventType: 'uat_pass',
        hourOffset: 14,
        payload: {
          area_tags: ['react'],
          attempts: 1,
          spec_id: 'SPEC-104',
          task_id: `TASK-fl-pass-${String(index + 1).padStart(3, '0')}`,
          uat_id: `UAT-${String(700 + index).padStart(3, '0')}`,
        },
      })
    );
  }

  return lines;
};

// ---------------------------------------------------------------------------
// multi-area.jsonl (cross-cutting smoke-harness driver)
// ---------------------------------------------------------------------------
//
// Mix of all 8 mentorship event types across visual / react / form /
// typescript area tags. Volume is deliberately modest — this fixture exists
// for the Phase 6 smoke harness to walk an end-to-end pipeline shape; it is
// NOT shaped to fire any specific pattern.
const buildMultiArea = (): string[] => {
  const lines: string[] = [];
  const areas = ['visual', 'react', 'form', 'typescript'] as const;

  // 4 uat_pass — one per area.
  for (const [index, area] of areas.entries()) {
    lines.push(
      buildLine({
        daysAgo: 2 + index,
        eventType: 'uat_pass',
        payload: {
          area_tags: [area],
          attempts: 1,
          spec_id: 'SPEC-105',
          task_id: `TASK-ma-pass-${area}`,
          uat_id: `UAT-${String(800 + index).padStart(3, '0')}`,
        },
      })
    );
  }
  // 4 uat_fail — one per area, varying failure_class.
  const failureClasses = [
    'assertion',
    'exception',
    'timeout',
    'setup',
  ] as const;

  for (const [index, area] of areas.entries()) {
    lines.push(
      buildLine({
        daysAgo: 4 + index,
        eventType: 'uat_fail',
        hourOffset: 1,
        payload: {
          area_tags: [area],
          attempts: 2,
          failure_class: failureClasses[index],
          spec_id: 'SPEC-105',
          task_id: `TASK-ma-fail-${area}`,
          uat_id: `UAT-${String(810 + index).padStart(3, '0')}`,
        },
      })
    );
  }
  // 4 needs_context_returned — one per area.
  const contextClasses = [
    'unclear_acceptance_criteria',
    'missing_codebase_knowledge',
    'ambiguous_boundary',
    'unclear_business_intent',
  ] as const;

  for (const [index, area] of areas.entries()) {
    lines.push(
      buildLine({
        daysAgo: 6 + index,
        eventType: 'needs_context_returned',
        hourOffset: 2,
        payload: {
          agent_type: 'Senior',
          area_tags: [area],
          context_request_class: contextClasses[index],
          spec_id: 'SPEC-105',
          task_id: `TASK-ma-nc-${area}`,
        },
      })
    );
  }
  // 4 blocked_returned — one per area, varying classification.
  const classifications = ['intent', 'spec', 'code', 'intent'] as const;

  for (const [index, area] of areas.entries()) {
    lines.push(
      buildLine({
        agentType: 'Lead',
        daysAgo: 8 + index,
        eventType: 'blocked_returned',
        hourOffset: 3,
        payload: {
          agent_type: 'Lead',
          area_tags: [area],
          classification: classifications[index],
          spec_id: 'SPEC-105',
          task_id: `TASK-ma-block-${area}`,
        },
      })
    );
  }

  // 2 spec_amended events.
  for (let index = 0; index < 2; index += 1) {
    lines.push(
      buildLine({
        daysAgo: 12 + index,
        eventType: 'spec_amended',
        payload: {
          amendment_reason: 'Missed empty-state UAT during initial draft.',
          fields_changed: ['uats'],
          spec_id: 'SPEC-105',
          time_since_close_seconds: 14_400,
        },
      })
    );
  }
  // 2 plan_revised events.
  const revisionClasses = ['scope_change', 'sequencing_change'] as const;

  for (let index = 0; index < 2; index += 1) {
    lines.push(
      buildLine({
        agentType: 'Lead',
        daysAgo: 14 + index,
        eventType: 'plan_revised',
        payload: {
          items_added: 2,
          items_removed: index,
          plan_id: `PLAN-105-rev${index + 1}`,
          revision_class: revisionClasses[index],
          spec_id: 'SPEC-105',
        },
      })
    );
  }

  // 2 time_to_resolved_spec events.
  for (let index = 0; index < 2; index += 1) {
    lines.push(
      buildLine({
        agentType: 'PO',
        daysAgo: 18 + index,
        eventType: 'time_to_resolved_spec',
        payload: {
          abandoned: false,
          area_tags: [areas[index]],
          duration_seconds: 1800 + index * 600,
          question_count: 10 + index * 2,
          spec_id: 'SPEC-105',
        },
      })
    );
  }
  // 2 code_review_audit_finding events.
  const severities = ['warning', 'error'] as const;

  for (let index = 0; index < 2; index += 1) {
    lines.push(
      buildLine({
        agentType: 'Reviewer',
        daysAgo: 20 + index,
        eventType: 'code_review_audit_finding',
        payload: {
          area_tags: [areas[index + 2]],
          auditor_type: 'code-review-audit',
          finding_class: 'type_hole',
          pr_number: 100 + index,
          severity: severities[index],
          spec_id: 'SPEC-105',
        },
      })
    );
  }

  return lines;
};

writeJsonl('below-threshold.jsonl', buildBelowThreshold());
writeJsonl('articulation-fire.jsonl', buildArticulationFire());
writeJsonl('articulation-fade.jsonl', buildArticulationFade());
writeJsonl('flake-downweight.jsonl', buildFlakeDownweight());
writeJsonl('multi-area.jsonl', buildMultiArea());
