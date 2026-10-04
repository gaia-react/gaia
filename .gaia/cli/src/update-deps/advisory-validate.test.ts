import {describe, expect, test} from 'vitest';
import {
  isGhsaId,
  isManifestPath,
  isNpmPackageName,
  isPositiveInteger,
  isRangeString,
  isSemverVersion,
  normalizeRelationship,
  normalizeScope,
  normalizeSeverity,
  toSemverRange,
} from './advisory-validate.js';

describe('advisory validators', () => {
  test('isGhsaId accepts the GHSA alphabet only', () => {
    expect(isGhsaId('GHSA-pxg6-pf52-xh8x')).toBe(true);
    expect(isGhsaId('GHSA-0000-0000-0000')).toBe(false);
    expect(isGhsaId('GHSA-pxg6-pf52-xh8x; rm')).toBe(false);
    expect(isGhsaId(42)).toBe(false);
  });

  test('isNpmPackageName refuses spaces and shell metacharacters', () => {
    expect(isNpmPackageName('cookie')).toBe(true);
    expect(isNpmPackageName('@scope/name.js')).toBe(true);
    expect(isNpmPackageName('evil pkg')).toBe(false);
    expect(isNpmPackageName('pkg;rm')).toBe(false);
    expect(isNpmPackageName('$(touch x)')).toBe(false);
    expect(isNpmPackageName('a'.repeat(215))).toBe(false);
  });

  test('isSemverVersion accepts a strict version only', () => {
    expect(isSemverVersion('1.0.0')).toBe(true);
    expect(isSemverVersion('1.0.0-beta.1')).toBe(true);
    expect(isSemverVersion('1.0.0; rm')).toBe(false);
    expect(isSemverVersion('v1.0.0')).toBe(false);
    expect(isSemverVersion('^1.0.0')).toBe(false);
  });

  test('isRangeString accepts pnpm and GitHub range syntax', () => {
    expect(isRangeString('<0.7.0')).toBe(true);
    expect(isRangeString('>= 4.0.0, < 4.17.21')).toBe(true);
    expect(isRangeString('<1.2.0 || >=2.0.0 <2.1.0')).toBe(true);
    expect(isRangeString('>=1.0.0; rm')).toBe(false);
    expect(isRangeString('not a range')).toBe(false);
    expect(isRangeString('')).toBe(false);
  });

  test('toSemverRange turns GitHub comma separators into semver AND', () => {
    expect(toSemverRange('>= 4.0.0, < 4.17.21')).toBe('>= 4.0.0  < 4.17.21');
  });

  test('isManifestPath refuses traversal, absolute paths, and odd characters', () => {
    expect(isManifestPath('frontend/package.json')).toBe(true);
    expect(isManifestPath('../etc/package.json')).toBe(false);
    expect(isManifestPath('frontend/../package.json')).toBe(false);
    expect(isManifestPath('/package.json')).toBe(false);
    expect(isManifestPath('package.json; rm')).toBe(false);
  });

  test('isPositiveInteger refuses zero, negatives, and fractions', () => {
    expect(isPositiveInteger(41)).toBe(true);
    expect(isPositiveInteger(0)).toBe(false);
    expect(isPositiveInteger(-5)).toBe(false);
    expect(isPositiveInteger(1.5)).toBe(false);
    expect(isPositiveInteger('41')).toBe(false);
  });

  test('normalizers map known values and return null on unknown ones', () => {
    expect(normalizeSeverity('moderate')).toBe('medium');
    expect(normalizeSeverity('critical')).toBe('critical');
    expect(normalizeSeverity('urgent')).toBeNull();
    expect(normalizeSeverity('constructor')).toBeNull();
    expect(normalizeScope('runtime')).toBe('runtime');
    expect(normalizeScope(null)).toBe('n/a');
    expect(normalizeScope('production')).toBeNull();
    expect(normalizeRelationship('transitive')).toBe('transitive');
    expect(normalizeRelationship(null)).toBe('unknown');
    expect(normalizeRelationship('cousin')).toBeNull();
  });
});
