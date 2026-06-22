import { set } from 'date-fns';
import { range } from 'lodash';

/**
 * Returns a date object set to noon with seconds and milliseconds zeroed out.
 * @param date - The input date.
 */
export const setToNoon = (date: Date): Date => {
  return set(date, { hours: 12, milliseconds: 0, minutes: 0, seconds: 0 });
};

/**
 * Returns the range of birth years from current year minus 120 to current year minus 12.
 * @param currentYear - The current year used to calculate the range.
 */
export const getYearsRange = (currentYear: number): number[] => {
  return range(currentYear - 120, currentYear - 12).toReversed();
};

// Exported constants using the above helpers
const TODAY = setToNoon(new Date());
const THIS_YEAR = TODAY.getFullYear();
export const YEARS = getYearsRange(THIS_YEAR);

/**
 * Ensures that a value is safe and falls within optional min/max bounds.
 * @param value - The value to validate.
 * @param min - Minimum allowed value.
 * @param max - Maximum allowed value.
 */
export const getSafeValue = (value: number, min = -Infinity, max = Infinity): number => {
  return Math.min(max, Math.max(min, value));
};

/**
 * Some placeholder description for getValues.
 */
export const getValues = (): unknown => {
  // Existing implementation, copied from old utils file.
};