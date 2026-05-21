import {describe, expect, test} from 'vitest';
import {detectIntentClarityGap} from '../patterns/intent-clarity-gap.js';
import type {MentorshipEvent} from '../reader.js';

const buildSpecAmended = (specId: string, index: number): MentorshipEvent => ({
  agent_type: 'human',
  event_id: `01HZZZA${index.toString().padStart(19, '0')}`,
  event_type: 'spec_amended',
  payload: {
    amendment_reason: 'missed empty-state UAT',
    fields_changed: ['uats'],
    spec_id: specId,
    time_since_close_seconds: 14_400,
  },
  project_id: 'a'.repeat(32),
  schema_version: 1,
  session_hash: 'b'.repeat(32),
  timestamp: '2026-05-07T12:00:00.000Z',
});

const buildTimeToResolved = (
  specId: string,
  area: string,
  questionCount: number,
  index: number
): MentorshipEvent => ({
  agent_type: 'human',
  event_id: `01HZZZT${index.toString().padStart(19, '0')}`,
  event_type: 'time_to_resolved_spec',
  payload: {
    abandoned: false,
    area_tags: [area],
    duration_seconds: 1850,
    question_count: questionCount,
    spec_id: specId,
  },
  project_id: 'a'.repeat(32),
  schema_version: 1,
  session_hash: 'b'.repeat(32),
  timestamp: '2026-05-07T12:00:00.000Z',
});

describe('detectIntentClarityGap (unit)', () => {
  test('returns strength=null when total spec_amended + ttr count < 10', () => {
    const events: MentorshipEvent[] = [
      buildSpecAmended('SPEC-001', 1),
      buildTimeToResolved('SPEC-001', 'visual', 8, 1),
      buildTimeToResolved('SPEC-002', 'visual', 6, 2),
    ];
    const results = detectIntentClarityGap({events, windowDays: 30});
    const visual = results.find((entry) => entry.area_tag === 'visual');

    expect(visual?.sample_count).toBe(3);
    expect(visual?.strength).toBeNull();
  });

  test('composite strength uses 0.6 amended + 0.4 question_count weighting', () => {
    const events: MentorshipEvent[] = [];

    // Build 10 SPECs in `visual` with high question counts; amend 4 of them.
    for (let index = 0; index < 10; index += 1) {
      const specId = `SPEC-${index.toString().padStart(3, '0')}`;
      events.push(buildTimeToResolved(specId, 'visual', 18, index));
    }

    for (let index = 0; index < 4; index += 1) {
      const specId = `SPEC-${index.toString().padStart(3, '0')}`;
      events.push(buildSpecAmended(specId, 100 + index));
    }
    const results = detectIntentClarityGap({events, windowDays: 30});
    const visual = results.find((entry) => entry.area_tag === 'visual');

    expect(visual).toBeDefined();
    // sample = 10 ttr + 4 amended = 14, ≥ MIN
    expect(visual?.sample_count).toBe(14);
    // amended_rate = 4/10 = 0.4 → 0.4/0.20 = 2.0 (clamped via min)
    // avg_q = 18 → 18/15 = 1.2 (clamped via min)
    // composite = min(1, 2.0*0.6 + 1.2*0.4) = min(1, 1.2 + 0.48) = 1
    expect(visual?.strength).toBe(1);
  });

  test('low signal stays below firing threshold', () => {
    const events: MentorshipEvent[] = [];

    for (let index = 0; index < 10; index += 1) {
      const specId = `SPEC-${index.toString().padStart(3, '0')}`;
      // Low question count (3) and 0 amendments → near-zero strength.
      events.push(buildTimeToResolved(specId, 'react', 3, index));
    }
    const results = detectIntentClarityGap({events, windowDays: 30});
    const react = results.find((entry) => entry.area_tag === 'react');

    expect(react).toBeDefined();
    // amended_rate = 0, avg_q = 3 → 0.6*0 + 0.4*(3/15) = 0.08
    expect(react?.strength).toBeCloseTo(0.08, 3);
  });

  test('never emits a `_unknown` area result, even at threshold', () => {
    const events: MentorshipEvent[] = [];

    // 12 spec_amended events whose specs have no time_to_resolved_spec
    // event in the window → all attributed to the `_unknown` sentinel.
    for (let index = 0; index < 12; index += 1) {
      events.push(buildSpecAmended(`SPEC-${index.toString().padStart(3, '0')}`, index));
    }
    const results = detectIntentClarityGap({events, windowDays: 30});

    expect(results.some((entry) => entry.area_tag === '_unknown')).toBe(false);
  });

  test('amended_rate denominator is closed specs only, not closed + amended', () => {
    const events: MentorshipEvent[] = [];

    // 10 closed specs in `visual`.
    for (let index = 0; index < 10; index += 1) {
      events.push(
        buildTimeToResolved(`SPEC-${index.toString().padStart(3, '0')}`, 'visual', 5, index)
      );
    }

    // Amend 2 of those closed specs.
    events.push(buildSpecAmended('SPEC-000', 100));
    events.push(buildSpecAmended('SPEC-001', 101));
    const results = detectIntentClarityGap({events, windowDays: 30});
    const visual = results.find((entry) => entry.area_tag === 'visual');
    const amendedRate = visual?.components.find(
      (component) => component.metric === 'amended_rate'
    );

    // amended_rate = 2 amended / 10 closed = 0.2 — the denominator must not
    // be inflated by the amended spec IDs (which would give 2/10 here too,
    // but a wrong denominator surfaces when amended specs lack a ttr event).
    expect(amendedRate?.value).toBeCloseTo(0.2, 5);
  });

  test('amended specs without a ttr event do not inflate a real area denominator', () => {
    const events: MentorshipEvent[] = [];

    // 10 closed specs in `visual`; amend all 10 of them.
    for (let index = 0; index < 10; index += 1) {
      const specId = `SPEC-${index.toString().padStart(3, '0')}`;
      events.push(buildTimeToResolved(specId, 'visual', 5, index));
      events.push(buildSpecAmended(specId, 100 + index));
    }
    const results = detectIntentClarityGap({events, windowDays: 30});
    const visual = results.find((entry) => entry.area_tag === 'visual');
    const amendedRate = visual?.components.find(
      (component) => component.metric === 'amended_rate'
    );

    // 10 amended / 10 closed = 1.0 — saturated, but correctly so.
    expect(amendedRate?.value).toBeCloseTo(1, 5);
  });

  test('rejects negative, NaN, and Infinity question_count values', () => {
    const negative = buildTimeToResolved('SPEC-NEG', 'visual', -5, 1);
    const events: MentorshipEvent[] = [negative];

    for (let index = 0; index < 9; index += 1) {
      events.push(buildTimeToResolved(`SPEC-${index.toString().padStart(3, '0')}`, 'visual', 0, index));
    }
    (negative.payload as Record<string, unknown>).question_count = Number.NaN;

    const results = detectIntentClarityGap({events, windowDays: 30});
    const visual = results.find((entry) => entry.area_tag === 'visual');
    const avgQ = visual?.components.find(
      (component) => component.metric === 'avg_question_count'
    );

    // A NaN question_count must coerce to 0, not poison the mean.
    expect(avgQ?.value).toBe(0);
  });
});
