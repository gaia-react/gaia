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

export const getValues = (value: string) => {
  const result = iso8601DateSchema.safeParse(value);
  const [year, month, date] = (
    result.success ?
      result.data
    : DEFAULT_VALUE).split('-');

  return [year, month, date];
};

type NumericYMD = {
  date: number;
  month: number;
  year: number;
};

const getDateFromNumericYMD = ({date, month, year}: NumericYMD) =>
  new Date(+year, +month, +date, 12, 0, 0, 0);

const getNumericYMDFromISO8601Date = (value: string) => {
  const [year, month, date] = value.split('-').map(Number);

  return {date, month: +month - 1, year};
};

// ensure date is valid (i.e. no June 31, Feb 30, Feb 29 on non-leap years, etc.)
export const getSafeValue = (
  prevValue: string,
  {name, value: fieldValue}: EventTarget & HTMLSelectElement
) => {
  const which = name.includes('Month') ? 'month' : 'year';

  const prevYMD = getNumericYMDFromISO8601Date(prevValue);

  const nextYMD = {
    date: 1, // prevent date from being out of bounds for daysInMonth check
    month: which === 'month' ? +fieldValue - 1 : +prevYMD.month,
    year: which === 'year' ? +fieldValue : +prevYMD.year,
  };

  const prevDate = getDateFromNumericYMD(prevYMD);

  const daysInMonth = getDaysInMonth(set(prevDate, nextYMD));

  let nextDate: Date;

  if (+prevYMD.date > daysInMonth) {
    nextDate = set(prevDate, {
      ...nextYMD,
      date: lastDayOfMonth(set(prevDate, nextYMD)).getDate(),
    });
  } else {
    nextDate = set(prevDate, {
      [which]: which === 'month' ? +fieldValue - 1 : +fieldValue,
    });
  }

  return formatISO8601Date(nextDate);
};
