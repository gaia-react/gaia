import {describe, expect, test} from 'vitest';
import {getSafeValue, getValues} from '../utils';

const mockSelect = (name: string, value: string) =>
  ({name, value}) as EventTarget & HTMLSelectElement;

describe('getValues', () => {
  test('returns year, month, date split for a valid ISO-8601 date', () => {
    expect(getValues('2024-06-15')).toEqual(['2024', '06', '15']);
  });

  test('returns DEFAULT_VALUE split for an invalid string', () => {
    expect(getValues('not-a-date')).toEqual(['2000', '01', '01']);
  });

  test('returns DEFAULT_VALUE split for an empty string', () => {
    expect(getValues('')).toEqual(['2000', '01', '01']);
  });
});

describe('getSafeValue', () => {
  test('clamps day when month overflows (Jan 31 → Feb in leap year)', () => {
    expect(getSafeValue('2024-01-31', mockSelect('dobMonth', '02'))).toBe(
      '2024-02-29'
    );
  });

  test('clamps day when month overflows (Jan 31 → Feb in non-leap year)', () => {
    expect(getSafeValue('2001-01-31', mockSelect('dobMonth', '02'))).toBe(
      '2001-02-28'
    );
  });

  test('clamps day when month overflows (Mar 31 → Apr)', () => {
    expect(getSafeValue('2024-03-31', mockSelect('dobMonth', '04'))).toBe(
      '2024-04-30'
    );
  });

  test('does not clamp day when new month has enough days (Aug 31 → Sep)', () => {
    expect(getSafeValue('2024-08-31', mockSelect('dobMonth', '09'))).toBe(
      '2024-09-30'
    );
  });

  test('clamps Feb 29 when changing to a non-leap year', () => {
    expect(getSafeValue('2024-02-29', mockSelect('dobYear', '2023'))).toBe(
      '2023-02-28'
    );
  });

  test('preserves Feb 29 when staying in a leap year', () => {
    expect(getSafeValue('2024-02-29', mockSelect('dobYear', '2028'))).toBe(
      '2028-02-29'
    );
  });

  test('year change preserves day when month has enough days', () => {
    expect(getSafeValue('2024-08-31', mockSelect('dobYear', '2023'))).toBe(
      '2023-08-31'
    );
  });

  test('month change does not clamp when day is within new month bounds', () => {
    expect(getSafeValue('2024-05-15', mockSelect('dobMonth', '06'))).toBe(
      '2024-06-15'
    );
  });
});
