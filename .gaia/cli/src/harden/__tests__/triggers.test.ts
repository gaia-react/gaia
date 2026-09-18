import {describe, expect, test, vi} from 'vitest';
import type {ReviewSnapshot} from '../../schemas/review-snapshot.js';
import type * as MaterialRiseModule from '../material-rise.js';
import {isMaterialRise, TALLY_SCHEMA_VERSION} from '../material-rise.js';
import {evaluateTriggers} from '../triggers.js';
import type {EvaluateTriggersArgs} from '../triggers.js';

// Wraps the REAL isMaterialRise in a vi.fn (case 11a needs a spy that still
// computes the real answer by default; every other case relies on it behaving
// identically to the unmocked function).
vi.mock('../material-rise.js', async (importOriginal) => {
  const actual = await importOriginal<typeof MaterialRiseModule>();

  return {...actual, isMaterialRise: vi.fn(actual.isMaterialRise)};
});

const makeSnapshot = (args: {
  audited: number;
  classes: Record<string, number>;
  schemaVersion?: number;
  unclassified?: null | number;
}): ReviewSnapshot => {
  const share = (count: number): number =>
    args.audited > 0 ? count / args.audited : 0;

  return {
    audited_pr_count: args.audited,
    classes: Object.fromEntries(
      Object.entries(args.classes).map(([findingClass, count]) => [
        findingClass,
        {distinct_pr_count: count, share: share(count)},
      ])
    ),
    reviewed_at: '2026-01-01T00:00:00.000Z',
    tally_schema_version: args.schemaVersion ?? TALLY_SCHEMA_VERSION,
    unclassified:
      args.unclassified == null ?
        null
      : {distinct_pr_count: args.unclassified, share: share(args.unclassified)},
    version: 1,
    window_days: 90,
  };
};

// `candidates` is an ordered tuple list, not a Record: several cases assert
// the trigger order tracks `candidates[]` order, which a plain object's key
// order cannot be relied on to preserve once linted/sorted.
const makeLive = (args: {
  audited: number;
  candidates: readonly (readonly [string, number])[];
  schemaVersion?: number;
  unclassified?: null | number;
}): EvaluateTriggersArgs['live'] => ({
  auditedPrCount: args.audited,
  candidates: args.candidates.map(([finding_class, distinct_pr_count]) => ({
    distinct_pr_count,
    finding_class,
  })),
  tallySchemaVersion: args.schemaVersion ?? TALLY_SCHEMA_VERSION,
  unclassified:
    args.unclassified == null ? null : {distinct_pr_count: args.unclassified},
});

describe('evaluateTriggers', () => {
  test('1: no snapshot -> []', () => {
    const result = evaluateTriggers({
      live: makeLive({audited: 400, candidates: []}),
      snapshot: null,
    });

    expect(result).toEqual([]);
  });

  test('2: a live candidate absent from the snapshot reads as new_class', () => {
    const snapshot = makeSnapshot({
      audited: 400,
      classes: {
        'holistic/drifting-duplicate': 10,
        'holistic/overclaimed-guarantee': 40,
      },
    });

    const result = evaluateTriggers({
      live: makeLive({
        audited: 400,
        candidates: [
          ['holistic/drifting-duplicate', 10],
          ['holistic/overclaimed-guarantee', 40],
          ['holistic/swallowed-error', 5],
        ],
      }),
      snapshot,
    });

    expect(result).toEqual([
      {finding_class: 'holistic/swallowed-error', type: 'new_class'},
    ]);
  });

  test('2b: two absent candidates yield two new_class entries in candidates order', () => {
    const snapshot = makeSnapshot({
      audited: 400,
      classes: {'holistic/overclaimed-guarantee': 40},
    });

    const result = evaluateTriggers({
      live: makeLive({
        audited: 400,
        candidates: [
          ['holistic/swallowed-error', 5],
          ['holistic/n-plus-one', 6],
          ['holistic/overclaimed-guarantee', 40],
        ],
      }),
      snapshot,
    });

    expect(result).toEqual([
      {finding_class: 'holistic/swallowed-error', type: 'new_class'},
      {finding_class: 'holistic/n-plus-one', type: 'new_class'},
    ]);
  });

  test('3: material rise across the ratio floor, and refusal just under it', () => {
    const snapshot = makeSnapshot({
      audited: 400,
      classes: {'holistic/overclaimed-guarantee': 40},
    });

    const risen = evaluateTriggers({
      live: makeLive({
        audited: 400,
        candidates: [['holistic/overclaimed-guarantee', 50]],
      }),
      snapshot,
    });
    expect(risen).toEqual([
      {finding_class: 'holistic/overclaimed-guarantee', type: 'rising_class'},
    ]);

    const notRisen = evaluateTriggers({
      live: makeLive({
        audited: 400,
        candidates: [['holistic/overclaimed-guarantee', 49]],
      }),
      snapshot,
    });
    expect(notRisen).toEqual([]);
  });

  test('4: the +3 floor refuses a ratio-only rise', () => {
    const snapshot = makeSnapshot({
      audited: 400,
      classes: {'holistic/swallowed-error': 4},
    });

    const refused = evaluateTriggers({
      live: makeLive({
        audited: 400,
        candidates: [['holistic/swallowed-error', 6]],
      }),
      snapshot,
    });
    expect(refused).toEqual([]);

    const risen = evaluateTriggers({
      live: makeLive({
        audited: 400,
        candidates: [['holistic/swallowed-error', 7]],
      }),
      snapshot,
    });
    expect(risen).toEqual([
      {finding_class: 'holistic/swallowed-error', type: 'rising_class'},
    ]);
  });

  test('5: proportional growth across a doubled audited-PR base never fires, including unclassified', () => {
    const snapshot = makeSnapshot({
      audited: 400,
      classes: {
        'holistic/drifting-duplicate': 10,
        'holistic/overclaimed-guarantee': 40,
      },
      unclassified: 120,
    });

    const result = evaluateTriggers({
      live: makeLive({
        audited: 800,
        candidates: [
          ['holistic/drifting-duplicate', 20],
          ['holistic/overclaimed-guarantee', 80],
        ],
        unclassified: 240,
      }),
      snapshot,
    });

    expect(result).toEqual([]);
  });

  test('6: rising_unclassified rules', () => {
    const snapshot = makeSnapshot({
      audited: 400,
      classes: {},
      unclassified: 120,
    });

    const risen = evaluateTriggers({
      live: makeLive({audited: 400, candidates: [], unclassified: 150}),
      snapshot,
    });
    expect(risen).toEqual([{type: 'rising_unclassified'}]);

    const nullBaseline = makeSnapshot({
      audited: 400,
      classes: {},
      unclassified: null,
    });
    const fromNullBaseline = evaluateTriggers({
      live: makeLive({audited: 400, candidates: [], unclassified: 10}),
      snapshot: nullBaseline,
    });
    expect(fromNullBaseline).toEqual([{type: 'rising_unclassified'}]);

    const liveSignalNull = evaluateTriggers({
      live: makeLive({audited: 400, candidates: [], unclassified: null}),
      snapshot,
    });
    expect(liveSignalNull).toEqual([]);
  });

  test('7: schema_change refuses every other trigger', () => {
    const snapshot = makeSnapshot({
      audited: 400,
      classes: {'holistic/overclaimed-guarantee': 40},
      schemaVersion: TALLY_SCHEMA_VERSION + 1,
    });

    const result = evaluateTriggers({
      live: makeLive({
        audited: 400,
        candidates: [
          ['holistic/overclaimed-guarantee', 50],
          ['holistic/swallowed-error', 5],
        ],
      }),
      snapshot,
    });

    expect(result).toEqual([{type: 'schema_change'}]);
  });

  test('8: a combined new_class and rising_class trigger set preserves candidates order', () => {
    const snapshot = makeSnapshot({
      audited: 400,
      classes: {'holistic/drifting-duplicate': 40},
    });

    const result = evaluateTriggers({
      live: makeLive({
        audited: 400,
        candidates: [
          ['holistic/swallowed-error', 5],
          ['holistic/drifting-duplicate', 400],
        ],
      }),
      snapshot,
    });

    expect(result).toEqual([
      {finding_class: 'holistic/swallowed-error', type: 'new_class'},
      {finding_class: 'holistic/drifting-duplicate', type: 'rising_class'},
    ]);
  });

  test('9: below the trust minimum on either side, the comparison falls back to the raw ratio', () => {
    const risenBelow = evaluateTriggers({
      live: makeLive({
        audited: 32,
        candidates: [['holistic/overclaimed-guarantee', 8]],
      }),
      snapshot: makeSnapshot({
        audited: 16,
        classes: {'holistic/overclaimed-guarantee': 4},
      }),
    });
    expect(risenBelow).toEqual([
      {finding_class: 'holistic/overclaimed-guarantee', type: 'rising_class'},
    ]);

    const refusedBelow = evaluateTriggers({
      live: makeLive({
        audited: 32,
        candidates: [['holistic/overclaimed-guarantee', 6]],
      }),
      snapshot: makeSnapshot({
        audited: 16,
        classes: {'holistic/overclaimed-guarantee': 4},
      }),
    });
    expect(refusedBelow).toEqual([]);

    const mixedTrust = evaluateTriggers({
      live: makeLive({
        audited: 400,
        candidates: [['holistic/overclaimed-guarantee', 13]],
      }),
      snapshot: makeSnapshot({
        audited: 19,
        classes: {'holistic/overclaimed-guarantee': 10},
      }),
    });
    expect(mixedTrust).toEqual([
      {finding_class: 'holistic/overclaimed-guarantee', type: 'rising_class'},
    ]);
  });

  test('10: an inventory-only class and unclassified both present in the snapshot are judged as a rise, and both miss the floor', () => {
    const snapshot = makeSnapshot({
      audited: 400,
      classes: {'holistic/n-plus-one': 2},
      unclassified: 2,
    });

    const result = evaluateTriggers({
      live: makeLive({
        audited: 800,
        candidates: [['holistic/n-plus-one', 4]],
        unclassified: 4,
      }),
      snapshot,
    });

    expect(result).toEqual([]);
  });

  test('11: a class present in the snapshot as a live candidate below the floor never rises', () => {
    const snapshot = makeSnapshot({
      audited: 400,
      classes: {'holistic/stale-figure': 2},
    });

    const result = evaluateTriggers({
      live: makeLive({
        audited: 400,
        candidates: [['holistic/stale-figure', 3]],
      }),
      snapshot,
    });

    expect(result).toEqual([]);
  });

  test('11a: every rise comparison goes through the one shared isMaterialRise (spy proof)', () => {
    const spy = vi.mocked(isMaterialRise);
    spy.mockClear();

    const snapshot = makeSnapshot({
      audited: 400,
      classes: {'holistic/overclaimed-guarantee': 40},
    });
    const live = makeLive({
      audited: 400,
      candidates: [['holistic/overclaimed-guarantee', 50]],
    });

    const risen = evaluateTriggers({live, snapshot});
    expect(risen).toEqual([
      {finding_class: 'holistic/overclaimed-guarantee', type: 'rising_class'},
    ]);
    expect(spy).toHaveBeenCalledWith({
      baseAuditedPrCount: 400,
      baseCount: 40,
      liveAuditedPrCount: 400,
      liveCount: 50,
    });

    // Refusal proof: forcing the spy's next answer to false must flip the
    // result to [], proving the trigger's own logic never reimplements the
    // ratio inline (an inline reimplementation would ignore this mock).
    spy.mockReturnValueOnce(false);
    const refused = evaluateTriggers({live, snapshot});
    expect(refused).toEqual([]);
  });
});
