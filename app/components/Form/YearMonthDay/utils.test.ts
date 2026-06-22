import { describe, it, expect } from 'vitest';
import { getSafeValue, getYearsRange } from './utils';

describe('getSafeValue', () => {
  it('returns the value when within bounds', () => {
    expect(getSafeValue(10, 0, 20)).toBe(10);
  });
  
  it('clips the value to the minimum bound', () => {
    expect(getSafeValue(-5, 0, 20)).toBe(0);
  });

  it('clips the value to the maximum bound', () => {
    expect(getSafeValue(25, 0, 20)).toBe(20);
  });

  it('handles no min/max bounds gracefully', () => {
    expect(getSafeValue(10)).toBe(10);
  });
});

describe('getYearsRange', () => {
  it('generates the expected year range', () => {
    const currentYear = 2023;
    const expectedRange = Array.from({ length: 109 }, (_, i) => 2011 - i);
    expect(getYearsRange(currentYear)).toEqual(expectedRange);
  });
});