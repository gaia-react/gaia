import {describe, expect, test} from 'vitest';
import {
  FINDING_CLASS_PREFIXES,
  FindingClassSchema,
  HOLISTIC_FINDING_CLASSES,
  isValidFindingClass,
  OUT_OF_SCOPE_FALLBACK_FINDING_CLASS,
  RULE_FINDING_CLASSES,
} from '../finding-class.js';

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

    test('rejects an unseeded holistic member (closed bucket)', () => {
      expect(
        FindingClassSchema.safeParse('holistic/something-made-up').success
      ).toBe(false);
      expect(isValidFindingClass('holistic/something-made-up')).toBe(false);
    });

    test('rejects an unseeded rule member (closed bucket)', () => {
      expect(
        FindingClassSchema.safeParse('rule/totally-invented').success
      ).toBe(false);
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
    test('exposes the six known prefixes', () => {
      expect(new Set(FINDING_CLASS_PREFIXES)).toEqual(
        new Set(['axe', 'cve', 'holistic', 'knip', 'react-doctor', 'rule'])
      );
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
