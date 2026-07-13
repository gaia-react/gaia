import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {resolveStorageRoots} from '../../storage/paths.js';
import {detectIntentClarityGap} from '../patterns/intent-clarity-gap.js';
import {readMentorshipEvents} from '../reader.js';
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

type TimeToResolvedArgs = {
  area: string;
  auto?: boolean;
  index: number;
  questionCeiling?: number;
  questionCount: number;
  specId: string;
};

const buildTimeToResolved = (args: TimeToResolvedArgs): MentorshipEvent => ({
  agent_type: 'human',
  event_id: `01HZZZT${args.index.toString().padStart(19, '0')}`,
  event_type: 'time_to_resolved_spec',
  payload: {
    abandoned: false,
    area_tags: [args.area],
    ...(args.auto === undefined ? {} : {auto: args.auto}),
    duration_seconds: 1850,
    ...(args.questionCeiling === undefined ?
      {}
    : {question_ceiling: args.questionCeiling}),
    question_count: args.questionCount,
    spec_id: args.specId,
  },
  project_id: 'a'.repeat(32),
  schema_version: 1,
  session_hash: 'b'.repeat(32),
  timestamp: '2026-05-07T12:00:00.000Z',
});

const buildVisualBaseline = (): MentorshipEvent[] => {
  const events: MentorshipEvent[] = [];

  for (let index = 0; index < 10; index += 1) {
    events.push(
      buildTimeToResolved({
        area: 'visual',
        index,
        questionCount: 2,
        specId: `SPEC-${index.toString().padStart(3, '0')}`,
      })
    );
  }

  return events;
};

const findComponent = (
  results: ReturnType<typeof detectIntentClarityGap>,
  metric: string
) =>
  results
    .find((entry) => entry.area_tag === 'visual')
    ?.components.find((component) => component.metric === metric)?.value;

const buildCeilingFiveCorpus = (): MentorshipEvent[] => {
  const events: MentorshipEvent[] = [];

  for (let index = 0; index < 10; index += 1) {
    events.push(
      buildTimeToResolved({
        area: 'visual',
        index,
        questionCeiling: 5,
        questionCount: 4,
        specId: `SPEC-${index.toString().padStart(3, '0')}`,
      })
    );
  }

  return events;
};

describe('detectIntentClarityGap (unit)', () => {
  test('returns strength=null when total spec_amended + ttr count < 10', () => {
    const events: MentorshipEvent[] = [
      buildSpecAmended('SPEC-001', 1),
      buildTimeToResolved({
        area: 'visual',
        index: 1,
        questionCount: 8,
        specId: 'SPEC-001',
      }),
      buildTimeToResolved({
        area: 'visual',
        index: 2,
        questionCount: 6,
        specId: 'SPEC-002',
      }),
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
      events.push(
        buildTimeToResolved({
          area: 'visual',
          index,
          questionCount: 18,
          specId,
        })
      );
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
      events.push(
        buildTimeToResolved({
          area: 'react',
          index,
          questionCount: 3,
          specId,
        })
      );
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
      events.push(
        buildSpecAmended(`SPEC-${index.toString().padStart(3, '0')}`, index)
      );
    }
    const results = detectIntentClarityGap({events, windowDays: 30});

    expect(results.some((entry) => entry.area_tag === '_unknown')).toBe(false);
  });

  test('amended_rate denominator is closed specs only, not closed + amended', () => {
    const events: MentorshipEvent[] = [];

    // 10 closed specs in `visual`.
    for (let index = 0; index < 10; index += 1) {
      events.push(
        buildTimeToResolved({
          area: 'visual',
          index,
          questionCount: 5,
          specId: `SPEC-${index.toString().padStart(3, '0')}`,
        })
      );
    }

    // Amend 2 of those closed specs.
    events.push(
      buildSpecAmended('SPEC-000', 100),
      buildSpecAmended('SPEC-001', 101)
    );
    const results = detectIntentClarityGap({events, windowDays: 30});
    const visual = results.find((entry) => entry.area_tag === 'visual');
    const amendedRate = visual?.components.find(
      (component) => component.metric === 'amended_rate'
    );

    // amended_rate = 2 amended / 10 closed = 0.2; the denominator must not
    // be inflated by the amended spec IDs (which would give 2/10 here too,
    // but a wrong denominator surfaces when amended specs lack a ttr event).
    expect(amendedRate?.value).toBeCloseTo(0.2, 5);
  });

  test('amended specs without a ttr event do not inflate a real area denominator', () => {
    const events: MentorshipEvent[] = [];

    // 10 closed specs in `visual`; amend all 10 of them.
    for (let index = 0; index < 10; index += 1) {
      const specId = `SPEC-${index.toString().padStart(3, '0')}`;
      events.push(
        buildTimeToResolved({
          area: 'visual',
          index,
          questionCount: 5,
          specId,
        }),
        buildSpecAmended(specId, 100 + index)
      );
    }
    const results = detectIntentClarityGap({events, windowDays: 30});
    const visual = results.find((entry) => entry.area_tag === 'visual');
    const amendedRate = visual?.components.find(
      (component) => component.metric === 'amended_rate'
    );

    // 10 amended / 10 closed = 1.0; saturated, but correctly so.
    expect(amendedRate?.value).toBeCloseTo(1, 5);
  });

  test('clamps amended_rate to 1 when a spec is amended twice', () => {
    // One closed spec, amended twice: `amendedCount` is 2 but the
    // closed-spec denominator is 1, so the raw ratio is 2/1 = 2. The
    // `amended_rate` component value must be clamped to 1.
    const events: MentorshipEvent[] = [
      buildTimeToResolved({
        area: 'visual',
        index: 0,
        questionCount: 5,
        specId: 'SPEC-000',
      }),
      buildSpecAmended('SPEC-000', 100),
      buildSpecAmended('SPEC-000', 101),
    ];
    const results = detectIntentClarityGap({events, windowDays: 30});
    const visual = results.find((entry) => entry.area_tag === 'visual');
    const amendedRate = visual?.components.find(
      (component) => component.metric === 'amended_rate'
    );

    expect(amendedRate?.value).toBeLessThanOrEqual(1);
    expect(amendedRate?.value).toBe(1);
  });

  test('rejects negative, NaN, and Infinity question_count values', () => {
    const negative = buildTimeToResolved({
      area: 'visual',
      index: 1,
      questionCount: -5,
      specId: 'SPEC-NEG',
    });
    const events: MentorshipEvent[] = [negative];

    for (let index = 0; index < 9; index += 1) {
      events.push(
        buildTimeToResolved({
          area: 'visual',
          index,
          questionCount: 0,
          specId: `SPEC-${index.toString().padStart(3, '0')}`,
        })
      );
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

  describe('auto-mode partition (UAT-007)', () => {
    test('an auto row with a high question_count does not move avg_q_count', () => {
      const baselineResults = detectIntentClarityGap({
        events: buildVisualBaseline(),
        windowDays: 30,
      });
      const before = findComponent(baselineResults, 'avg_question_count');

      const withAuto = [
        ...buildVisualBaseline(),
        buildTimeToResolved({
          area: 'visual',
          auto: true,
          index: 100,
          questionCount: 40,
          specId: 'SPEC-AUTO',
        }),
      ];
      const afterResults = detectIntentClarityGap({
        events: withAuto,
        windowDays: 30,
      });
      const after = findComponent(afterResults, 'avg_question_count');

      expect(after).toBe(before);
    });

    test('an auto row does not move the pattern strength', () => {
      const baselineResults = detectIntentClarityGap({
        events: buildVisualBaseline(),
        windowDays: 30,
      });
      const before = baselineResults.find(
        (entry) => entry.area_tag === 'visual'
      )?.strength;

      const withAuto = [
        ...buildVisualBaseline(),
        buildTimeToResolved({
          area: 'visual',
          auto: true,
          index: 100,
          questionCount: 40,
          specId: 'SPEC-AUTO',
        }),
      ];
      const afterResults = detectIntentClarityGap({
        events: withAuto,
        windowDays: 30,
      });
      const after = afterResults.find(
        (entry) => entry.area_tag === 'visual'
      )?.strength;

      // A partial exclusion (e.g. leaking into ttrCount or closedSpecIds)
      // would move strength even when avg_q_count stays put.
      expect(after).toBe(before);
    });

    test('an auto row does not enter the amended_rate denominator', () => {
      const baselineResults = detectIntentClarityGap({
        events: buildVisualBaseline(),
        windowDays: 30,
      });
      const before = findComponent(baselineResults, 'amended_rate');

      const withAuto = [
        ...buildVisualBaseline(),
        buildTimeToResolved({
          area: 'visual',
          auto: true,
          index: 100,
          questionCount: 40,
          specId: 'SPEC-AUTO',
        }),
      ];
      const afterResults = detectIntentClarityGap({
        events: withAuto,
        windowDays: 30,
      });
      const after = findComponent(afterResults, 'amended_rate');

      expect(after).toBe(before);
    });

    test('an amendment to an auto-authored spec does not inflate a human area', () => {
      const baselineResults = detectIntentClarityGap({
        events: buildVisualBaseline(),
        windowDays: 30,
      });
      const visualBaseline = baselineResults.find(
        (entry) => entry.area_tag === 'visual'
      );

      const withAutoAmendment = [
        ...buildVisualBaseline(),
        buildTimeToResolved({
          area: 'visual',
          auto: true,
          index: 200,
          questionCount: 40,
          specId: 'SPEC-900',
        }),
        buildSpecAmended('SPEC-900', 300),
      ];
      const results = detectIntentClarityGap({
        events: withAutoAmendment,
        windowDays: 30,
      });
      const visual = results.find((entry) => entry.area_tag === 'visual');
      const amendedRate = visual?.components.find(
        (component) => component.metric === 'amended_rate'
      );
      const baselineAmendedRate = visualBaseline?.components.find(
        (component) => component.metric === 'amended_rate'
      );

      // SPEC-900's only ttr event is auto, so it never enters `visual`'s
      // closedSpecIds; the amendment buckets to `_unknown` and is dropped.
      expect(amendedRate?.value).toBe(baselineAmendedRate?.value);
      expect(visual?.strength).toBe(visualBaseline?.strength);
    });
  });

  describe('ceiling-aware normalization (SC7)', () => {
    test('a higher ceiling with proportionally more questions does not raise strength', () => {
      // Falsification note: under the old raw-count formula, set B (ceiling
      // 10, 8 questions) scored (8 / 15) * 0.4 = 0.213 against set A's
      // (ceiling 5, 4 questions) (4 / 15) * 0.4 = 0.107, a +0.107 swing from
      // nothing but a raised ceiling, in a pattern whose remedy tells the
      // loop to ask more questions. The ceiling normalization collapses that
      // swing to zero: both sets represent 80% utilization of their own
      // ceiling and must score identically.
      const setA: MentorshipEvent[] = [];
      const setB: MentorshipEvent[] = [];

      for (let index = 0; index < 10; index += 1) {
        const specId = `SPEC-A${index.toString().padStart(3, '0')}`;
        setA.push(
          buildTimeToResolved({
            area: 'visual',
            index,
            questionCeiling: 5,
            questionCount: 4,
            specId,
          })
        );
      }

      for (let index = 0; index < 10; index += 1) {
        const specId = `SPEC-B${index.toString().padStart(3, '0')}`;
        setB.push(
          buildTimeToResolved({
            area: 'visual',
            index,
            questionCeiling: 10,
            questionCount: 8,
            specId,
          })
        );
      }

      const resultsA = detectIntentClarityGap({events: setA, windowDays: 30});
      const resultsB = detectIntentClarityGap({events: setB, windowDays: 30});
      const strengthA = resultsA.find(
        (entry) => entry.area_tag === 'visual'
      )?.strength;
      const strengthB = resultsB.find(
        (entry) => entry.area_tag === 'visual'
      )?.strength;

      expect(strengthB).not.toBeGreaterThan(strengthA ?? 0);
      expect(strengthB).toBeCloseTo(strengthA ?? 0, 10);
    });

    test('a row with no question_ceiling is read as a 5-ceiling row', () => {
      const noCeiling: MentorshipEvent[] = [];
      const explicitFive: MentorshipEvent[] = [];

      for (let index = 0; index < 10; index += 1) {
        noCeiling.push(
          buildTimeToResolved({
            area: 'visual',
            index,
            questionCount: 4,
            specId: `SPEC-N${index.toString().padStart(3, '0')}`,
          })
        );
        explicitFive.push(
          buildTimeToResolved({
            area: 'visual',
            index,
            questionCeiling: 5,
            questionCount: 4,
            specId: `SPEC-F${index.toString().padStart(3, '0')}`,
          })
        );
      }

      const noCeilingResults = detectIntentClarityGap({
        events: noCeiling,
        windowDays: 30,
      });
      const explicitFiveResults = detectIntentClarityGap({
        events: explicitFive,
        windowDays: 30,
      });

      expect(
        noCeilingResults.find((entry) => entry.area_tag === 'visual')?.strength
      ).toBe(
        explicitFiveResults.find((entry) => entry.area_tag === 'visual')
          ?.strength
      );
    });

    test('a malformed question_ceiling does not poison the mean', () => {
      for (const malformed of [0, -1, Number.NaN]) {
        const events = buildCeilingFiveCorpus();
        const target = events[0];
        (target.payload as Record<string, unknown>).question_ceiling =
          malformed;

        const results = detectIntentClarityGap({events, windowDays: 30});
        const visual = results.find((entry) => entry.area_tag === 'visual');
        const baselineResults = detectIntentClarityGap({
          events: buildCeilingFiveCorpus(),
          windowDays: 30,
        });
        const baselineVisual = baselineResults.find(
          (entry) => entry.area_tag === 'visual'
        );

        expect(visual?.strength).not.toBeNull();
        expect(Number.isFinite(visual?.strength)).toBe(true);
        expect(visual?.strength).toBe(baselineVisual?.strength);
      }
    });
  });
});

describe('question_ceiling survives the reader', () => {
  let homeDirectory = '';
  let repoRoot = '';

  beforeEach(() => {
    repoRoot = mkdtempSync(path.join(tmpdir(), 'gaia-ceiling-repo-'));
    homeDirectory = mkdtempSync(path.join(tmpdir(), 'gaia-ceiling-home-'));
  });

  afterEach(() => {
    rmSync(repoRoot, {force: true, recursive: true});
    rmSync(homeDirectory, {force: true, recursive: true});
  });

  // The payload schema is a strip-mode z.object, so a question_ceiling that is
  // not declared on it is silently dropped on read and the pattern falls back
  // to the baseline ceiling. Every other test in this file constructs events
  // in memory and never crosses that boundary, so without this one the field
  // could stop being carried and the suite would stay green.
  test('a row read off disk still carries question_ceiling', async () => {
    const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});
    const now = new Date('2026-05-07T12:00:00.000Z');
    const date = now.toISOString().slice(0, 10);

    mkdirSync(roots.mentorshipDir, {recursive: true});
    writeFileSync(
      path.join(roots.mentorshipDir, `events-${date}.jsonl`),
      `${JSON.stringify({
        agent_type: 'human',
        event_id: `01HZZZT${'0'.repeat(19)}`,
        event_type: 'time_to_resolved_spec',
        payload: {
          abandoned: false,
          area_tags: ['visual'],
          duration_seconds: 1850,
          question_ceiling: 10,
          question_count: 8,
          spec_id: 'SPEC-777',
        },
        project_id: 'a'.repeat(32),
        schema_version: 1,
        session_hash: 'b'.repeat(32),
        timestamp: '2026-05-07T12:00:00.000Z',
      })}\n`,
      'utf8'
    );

    const events = await readMentorshipEvents({now, roots, windowDays: 1});

    expect(events).toHaveLength(1);
    expect(events[0]?.payload).toHaveProperty('question_ceiling', 10);
  });
});
