import {describe, expect, test} from 'vitest';
import {date} from 'test/utils';
import {
  formatAbbreviatedMonthDay,
  formatAbbreviatedMonthOrdinalDay,
  formatFullDate,
  formatISO8601Date,
  formatMY,
  formatTime,
  formatTime24,
} from '../date';

const TEST_DATE = date({date: 15, month: 2, year: 2022});

describe('date utilities', () => {
  test('formatAbbreviatedMonthDay', () => {
    expect(formatAbbreviatedMonthDay(TEST_DATE, 'en')).toBe('Mar 15');
    expect(formatAbbreviatedMonthDay(TEST_DATE, 'ja')).toBe('3月 15日');
  });

  test('formatAbbreviatedMonthOrdinalDay', () => {
    expect(formatAbbreviatedMonthOrdinalDay(TEST_DATE, 'en')).toBe('Mar 15th');
    expect(formatAbbreviatedMonthOrdinalDay(TEST_DATE, 'ja')).toBe('3月 15日');
  });

  test('formatISO8601Date', () => {
    expect(formatISO8601Date(TEST_DATE)).toBe('2022-03-15');
  });

  test('formatFullDate', () => {
    expect(formatFullDate(TEST_DATE, 'en')).toBe('Tuesday, March 15th, 2022');
    expect(formatFullDate(TEST_DATE, 'ja')).toBe('2022年3月15日火曜日');
  });

  test('formatMY', () => {
    expect(formatMY(TEST_DATE)).toBe('03/22');
  });

  test('formatTime', () => {
    expect(formatTime(TEST_DATE, 'en')).toBe('12:00 PM');
    expect(formatTime(TEST_DATE, 'ja')).toBe('12:00');
  });

  test('formatTime24', () => {
    expect(formatTime24(TEST_DATE)).toBe('12:00');
    expect(formatTime24(TEST_DATE)).toBe('12:00');
  });

  test('falls back to en-US for a language with no registered locale', () => {
    expect(formatAbbreviatedMonthDay(TEST_DATE, 'fr')).toBe('Mar 15th');
    expect(formatFullDate(TEST_DATE, 'fr')).toBe('Tuesday, March 15th, 2022');
  });
});
