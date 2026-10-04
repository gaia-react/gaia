import {getDaysInMonth, lastDayOfMonth, set} from 'date-fns';
import {z} from 'zod';
import {range} from '~/utils/array';
import {formatISO8601Date} from '~/utils/date';

const TODAY = set(new Date(), {
  hours: 12,
  milliseconds: 0,
  minutes: 0,
  seconds: 0,
});

const THIS_YEAR = TODAY.getFullYear();

export const YEARS = range(THIS_YEAR - 120, THIS_YEAR - 12).toReversed();

export const MONTHS = range(1, 12);

export const DEFAULT_DATE = set(TODAY, {
  date: 1,
  month: 0,
  year: 2000,
});

export const DEFAULT_VALUE = formatISO8601Date(DEFAULT_DATE);

const iso8601DateSchema = z.iso.date();

export const getValues = (value: string): string[] => {
  const parseResult = iso8601DateSchema.safeParse(value);
  const [year, month, date] = (
    parseResult.success ?
      parseResult.data
    : DEFAULT_VALUE).split('-');

  return [year, month, date];
};

type NumericYearMonthDate = {
  date: number;
  month: number;
  year: number;
};

const getDateFromNumericYearMonthDate = ({
  date,
  month,
  year,
}: NumericYearMonthDate) => new Date(+year, +month, +date, 12, 0, 0, 0);

const getNumericYearMonthDateFromISO8601Date = (value: string) => {
  const [year, month, date] = value.split('-').map(Number);

  return {date, month: +month - 1, year};
};

// ensure date is valid (i.e. no June 31, Feb 30, Feb 29 on non-leap years, etc.)
export const getSafeValue = (
  previousValue: string,
  {name, value: fieldValue}: EventTarget & HTMLSelectElement
): string => {
  const changedUnit = name.includes('Month') ? 'month' : 'year';

  const previousYearMonthDate =
    getNumericYearMonthDateFromISO8601Date(previousValue);

  const nextYearMonthDate = {
    date: 1, // prevent date from being out of bounds for daysInMonth check
    month:
      changedUnit === 'month' ? +fieldValue - 1 : +previousYearMonthDate.month,
    year: changedUnit === 'year' ? +fieldValue : +previousYearMonthDate.year,
  };

  const previousDate = getDateFromNumericYearMonthDate(previousYearMonthDate);

  const daysInMonth = getDaysInMonth(set(previousDate, nextYearMonthDate));

  let nextDate: Date;

  if (+previousYearMonthDate.date > daysInMonth) {
    nextDate = set(previousDate, {
      ...nextYearMonthDate,
      date: lastDayOfMonth(set(previousDate, nextYearMonthDate)).getDate(),
    });
  } else {
    nextDate = set(previousDate, {
      [changedUnit]: changedUnit === 'month' ? +fieldValue - 1 : +fieldValue,
    });
  }

  return formatISO8601Date(nextDate);
};
