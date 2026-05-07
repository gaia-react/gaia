import {describe, expect, test} from 'vitest';
import {
  FADE_IMPROVEMENT_FULL,
  fadeFactor,
  FLAKE_DOWNWEIGHT,
  RATE_TARGET,
  rateStrength,
  STRENGTH_THRESHOLD,
  weightForUatFail,
} from '../strength.js';

describe('rateStrength', () => {
  test('returns 0 for non-positive rate', () => {
    expect(rateStrength(0, RATE_TARGET)).toBe(0);
    expect(rateStrength(-0.1, RATE_TARGET)).toBe(0);
  });

  test('returns 0 for non-positive target', () => {
    expect(rateStrength(0.5, 0)).toBe(0);
    expect(rateStrength(0.5, -1)).toBe(0);
  });

  test('saturates at 1 at the target rate', () => {
    expect(rateStrength(RATE_TARGET, RATE_TARGET)).toBe(1);
  });

  test('saturates at 1 above the target rate', () => {
    expect(rateStrength(0.9, RATE_TARGET)).toBe(1);
  });

  test('scales linearly below the target', () => {
    // rate = 0.15, target = 0.30 -> 0.5
    expect(rateStrength(0.15, RATE_TARGET)).toBeCloseTo(0.5, 5);
  });

  test('strength threshold is 0.5', () => {
    expect(STRENGTH_THRESHOLD).toBe(0.5);
  });
});

describe('fadeFactor', () => {
  test('no improvement -> no fade (factor 1)', () => {
    expect(fadeFactor(0)).toBe(1);
    expect(fadeFactor(-0.1)).toBe(1);
  });

  test('full improvement -> full fade (factor 0)', () => {
    expect(fadeFactor(FADE_IMPROVEMENT_FULL)).toBe(0);
    expect(fadeFactor(0.99)).toBe(0);
  });

  test('half improvement -> half fade', () => {
    expect(fadeFactor(FADE_IMPROVEMENT_FULL / 2)).toBeCloseTo(0.5, 5);
  });
});

describe('weightForUatFail (UAT-032)', () => {
  test('flake_suspected weight is 0.25', () => {
    expect(weightForUatFail('flake_suspected')).toBe(FLAKE_DOWNWEIGHT);
    expect(FLAKE_DOWNWEIGHT).toBe(0.25);
  });

  test('non-flake failure classes weight 1', () => {
    expect(weightForUatFail('assertion')).toBe(1);
    expect(weightForUatFail('exception')).toBe(1);
    expect(weightForUatFail('timeout')).toBe(1);
    expect(weightForUatFail('setup')).toBe(1);
  });
});
