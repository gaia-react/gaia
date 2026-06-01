import {set} from 'date-fns';

const base = set(new Date(), {
  date: 1,
  hours: 12,
  milliseconds: 0,
  minutes: 0,
  month: 0,
  seconds: 0,
  year: new Date().getFullYear() + 1,
});

export const date = (values?: Parameters<typeof set>[1]): Date =>
  values ? set(base, values) : base;
