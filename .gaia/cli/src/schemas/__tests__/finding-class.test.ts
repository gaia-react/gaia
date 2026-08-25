import {describe, expect, test} from 'vitest';
import {
  FINDING_CLASS_PREFIXES,
  FindingClassSchema,
  HOLISTIC_FINDING_CLASSES,
  isOracleFindingClass,
  isValidFindingClass,
  OUT_OF_SCOPE_FALLBACK_FINDING_CLASS,
  PROSE_FINDING_CLASSES,
  RULE_FINDING_CLASSES,
  WORKFLOW_FINDING_CLASSES,
} from '../finding-class.js';

/**
 * The holistic members seeded from the maintainer surface, the tail of
 * `HOLISTIC_FINDING_CLASSES` that begins at `holistic/hollow-assertion`. New
 * members are appended, so a newly seeded one lands in this slice on its own
 * and the coverage test below demands its near-miss entries.
 */
const MAINTAINER_SURFACE_HOLISTIC_CLASSES = HOLISTIC_FINDING_CLASSES.slice(
  HOLISTIC_FINDING_CLASSES.indexOf('holistic/hollow-assertion')
);

/**
 * Two near-miss spellings per maintainer-surface member: a plural and a
 * differently-worded neighbour. Held as pairs rather than a flat list so one
 * table feeds both the rejection cases and the coverage test that fails when a
 * member has no entries, or an entry names a member no longer seeded.
 */
const MAINTAINER_SURFACE_MEMBERS: readonly (readonly [
  string,
  readonly string[],
])[] = [
  [
    'holistic/hollow-assertion',
    ['holistic/hollow-assertions', 'holistic/hollow_assertion'],
  ],
  [
    'holistic/uncoupled-restatement',
    ['holistic/uncoupled-restatements', 'holistic/uncoupled-restatement-prose'],
  ],
  ['holistic/stale-figure', ['holistic/stale-figures', 'holistic/stale-count']],
  [
    'holistic/unarmed-guard',
    ['holistic/unarmed-guards', 'holistic/unarmed-check'],
  ],
  [
    'holistic/fail-open-discovery',
    ['holistic/fail-open-discoveries', 'holistic/failopen-discovery'],
  ],
  [
    'holistic/partial-cause-reporting',
    ['holistic/partial-cause-report', 'holistic/partial-cause-reporting-2'],
  ],
  [
    'holistic/dangling-reference',
    ['holistic/dangling-references', 'holistic/dangling-ref'],
  ],
  [
    'holistic/drifting-duplicate',
    ['holistic/drifting-duplicates', 'holistic/drifted-duplicate'],
  ],
  [
    'holistic/ambient-context-resolution',
    ['holistic/ambient-context-resolutions', 'holistic/ambient-context'],
  ],
  [
    'holistic/shared-state-collision',
    ['holistic/shared-state-collisions', 'holistic/shared-state-race'],
  ],
  [
    'holistic/unbounded-invocation',
    ['holistic/unbounded-invocations', 'holistic/unbounded-call'],
  ],
];

describe('schemas/finding-class', () => {
  describe('oracle buckets (open id space after the prefix)', () => {
    test.each([
      'react-doctor/no-generic-handler-names',
      'axe/color-contrast',
      'knip/exports',
      'knip/types',
      'knip/dependencies',
      'cve/1098765',
    ])('accepts a well-formed oracle id: %s', (value) => {
      expect(FindingClassSchema.safeParse(value).success).toBe(true);
      expect(isValidFindingClass(value)).toBe(true);
    });

    test('rejects an oracle prefix with an empty slug', () => {
      expect(FindingClassSchema.safeParse('react-doctor/').success).toBe(false);
      expect(isValidFindingClass('axe/')).toBe(false);
    });
  });

  describe('closed holistic/rule buckets (controlled vocabulary)', () => {
    test.each(HOLISTIC_FINDING_CLASSES)(
      'accepts seeded holistic member: %s',
      (value) => {
        expect(FindingClassSchema.safeParse(value).success).toBe(true);
      }
    );

    test.each(RULE_FINDING_CLASSES)(
      'accepts seeded rule member: %s',
      (value) => {
        expect(FindingClassSchema.safeParse(value).success).toBe(true);
      }
    );

    test.each(WORKFLOW_FINDING_CLASSES)(
      'accepts seeded workflow member: %s',
      (value) => {
        expect(FindingClassSchema.safeParse(value).success).toBe(true);
      }
    );

    test.each(PROSE_FINDING_CLASSES)(
      'accepts seeded prose member: %s',
      (value) => {
        expect(FindingClassSchema.safeParse(value).success).toBe(true);
      }
    );

    test('PROSE_FINDING_CLASSES is non-empty (a closed bucket with members)', () => {
      expect(PROSE_FINDING_CLASSES.length).toBeGreaterThan(0);
    });

    test('rejects an unseeded holistic member (closed bucket)', () => {
      expect(
        FindingClassSchema.safeParse('holistic/something-made-up').success
      ).toBe(false);
      expect(isValidFindingClass('holistic/something-made-up')).toBe(false);
    });

    test.each(MAINTAINER_SURFACE_MEMBERS.flatMap(([, misses]) => misses))(
      'rejects a near-miss spelling of each seeded maintainer-surface member: %s',
      (value) => {
        expect(FindingClassSchema.safeParse(value).success).toBe(false);
        expect(isValidFindingClass(value)).toBe(false);
      }
    );

    test('every maintainer-surface holistic member carries near-miss coverage', () => {
      expect(MAINTAINER_SURFACE_MEMBERS.map(([member]) => member)).toEqual([
        ...MAINTAINER_SURFACE_HOLISTIC_CLASSES,
      ]);
    });

    test('rejects an unseeded rule member (closed bucket)', () => {
      expect(
        FindingClassSchema.safeParse('rule/totally-invented').success
      ).toBe(false);
    });

    test('rejects an unseeded workflow member (closed bucket)', () => {
      expect(FindingClassSchema.safeParse('workflow/made-up').success).toBe(
        false
      );
      expect(isValidFindingClass('workflow/made-up')).toBe(false);
    });

    test('rejects an unseeded prose member (closed bucket)', () => {
      expect(FindingClassSchema.safeParse('prose/made-up').success).toBe(false);
      expect(isValidFindingClass('prose/made-up')).toBe(false);
    });
  });

  describe('free-text drift', () => {
    test.each(['just free text', '', 'no-prefix-slug', 'unknown/whatever'])(
      'rejects: %j',
      (value) => {
        expect(FindingClassSchema.safeParse(value).success).toBe(false);
        expect(isValidFindingClass(value)).toBe(false);
      }
    );
  });

  describe('exported vocabulary', () => {
    test('exposes the eight known prefixes', () => {
      expect(new Set(FINDING_CLASS_PREFIXES)).toEqual(
        new Set([
          'axe',
          'cve',
          'holistic',
          'knip',
          'prose',
          'react-doctor',
          'rule',
          'workflow',
        ])
      );
    });
  });

  describe('isOracleFindingClass (harden-tally is_oracle source)', () => {
    test.each([
      'react-doctor/no-generic-handler-names',
      'axe/color-contrast',
      'knip/exports',
      'cve/1098765',
    ])('true for an oracle-prefixed class: %s', (value) => {
      expect(isOracleFindingClass(value)).toBe(true);
    });

    test.each([
      'holistic/hardcoded-string',
      'rule/switch-statement',
      'workflow/unpinned-action',
      'prose/excessive-length',
      'not-a-real-prefix/x',
      '',
    ])('false for a non-oracle class: %j', (value) => {
      expect(isOracleFindingClass(value)).toBe(false);
    });
  });

  describe('out-of-scope dedup-key fallback', () => {
    test('has the expected value', () => {
      expect(OUT_OF_SCOPE_FALLBACK_FINDING_CLASS).toBe('holistic/unclassified');
    });

    test('is NOT a valid finding_class (dedup-key fallback only)', () => {
      expect(isValidFindingClass(OUT_OF_SCOPE_FALLBACK_FINDING_CLASS)).toBe(
        false
      );
      expect(
        FindingClassSchema.safeParse(OUT_OF_SCOPE_FALLBACK_FINDING_CLASS)
          .success
      ).toBe(false);
    });
  });
});
