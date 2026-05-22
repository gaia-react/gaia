import type {ChangeEvent, ComponentProps, FC, ReactNode} from 'react';
import {useCallback, useMemo, useRef} from 'react';
import {useTranslation} from 'react-i18next';
import {
  addDays,
  differenceInDays,
  endOfMonth,
  set,
  startOfMonth,
} from 'date-fns';
import {
  formatAbbreviatedMonth,
  formatFullYear,
  formatOrdinalDay,
} from '~/utils/date';
import FieldLabel from '../Field/FieldLabel';
import Select from '../Select';
import {
  DEFAULT_DATE,
  DEFAULT_VALUE,
  getSafeValue,
  getValues,
  MONTHS,
  YEARS,
} from './utils';

export type YearMonthDayProps = Omit<ComponentProps<'select'>, 'onChange'> & {
  className?: string;
  classNameSelect?: string;
  error?: ReactNode;
  label?: string;
  name?: string;
  onBlur?: () => void;
  onChange: (value: string) => void;
  required?: boolean;
  value: string;
};

const YearMonthDay: FC<YearMonthDayProps> = ({
  className,
  classNameSelect,
  error,
  label,
  name = 'dob',
  onBlur,
  onChange,
  ref,
  required,
  value = DEFAULT_VALUE,
}) => {
  const {
    i18n: {language},
    t,
  } = useTranslation('common');

  const hiddenRef = useRef<HTMLInputElement>(null);
  const [year, month, date] = getValues(value);

  // Use a native event listener to stop input events from reaching Conform's
  // document-level handler, which reads stale FormData and resets controlled
  // select values. React's onInput doesn't work for this because SSR hydrates
  // on `document`, so both React and Conform handlers are on the same node
  // and stopPropagation has no effect between handlers on the same element.
  const containerRef = useCallback((node: HTMLDivElement | null) => {
    if (!node) {
      return;
    }

    const stopPropagation = (event: Event) => event.stopPropagation();

    node.addEventListener('input', stopPropagation);

    return () => {
      node.removeEventListener('input', stopPropagation);
    };
  }, []);

  const handleUpdateDateSelect = useCallback(
    (event: ChangeEvent<HTMLSelectElement>) => {
      const newValue =
        event.currentTarget.name.includes('Date') ?
          `${year}-${month}-${event.currentTarget.value}`
        : getSafeValue(value, event.currentTarget);

      // Sync the hidden input's DOM value before onChange dispatches events,
      // so Conform reads the correct value during revalidation.
      if (hiddenRef.current) {
        hiddenRef.current.value = newValue;
      }

      onChange(newValue);
    },
    [month, onChange, value, year]
  );

  const years = useMemo(
    () =>
      YEARS.map((y) => ({
        label: formatFullYear(set(DEFAULT_DATE, {year: y}), language),
        value: String(y),
      })),
    [language]
  );

  const months = useMemo(
    () =>
      MONTHS.map((m) => ({
        label: formatAbbreviatedMonth(
          set(DEFAULT_DATE, {month: m - 1}),
          language
        ),
        value: String(m).padStart(2, '0'),
      })),
    [language]
  );

  const dates = useMemo(() => {
    const current = set(DEFAULT_DATE, {
      month: month ? +month - 1 : 0,
      year: year ? +year : 2000,
    });
    const start = startOfMonth(current);
    const end = endOfMonth(current);

    return Array(differenceInDays(end, start) + 1)
      .fill(start)
      .map((s, index) => {
        const d: Date = addDays(s, index);

        return {
          label:
            language === 'en' ?
              String(d.getDate())
            : formatOrdinalDay(d, language),
          value: String(d.getDate()).padStart(2, '0'),
        };
      });
  }, [language, month, year]);

  return (
    <fieldset className={className} onBlur={onBlur}>
      <FieldLabel error={error} isLegend={true} required={required}>
        {label ?? t('form.dateOfBirth')}
      </FieldLabel>
      <div
        ref={containerRef}
        className="mt-2 flex justify-between gap-4 md:gap-6"
      >
        <input ref={hiddenRef} name={name} type="hidden" value={value} />
        <Select
          ref={ref}
          aria-label={t('date.year')}
          className="flex-1"
          classNameSelect={classNameSelect}
          name={`${name}Year`}
          onChange={handleUpdateDateSelect}
          options={years}
          value={year}
        />
        <Select
          aria-label={t('date.month')}
          className="flex-1"
          classNameSelect={classNameSelect}
          name={`${name}Month`}
          onChange={handleUpdateDateSelect}
          options={months}
          value={month}
        />
        <Select
          aria-label={t('date.day')}
          className="flex-1"
          classNameSelect={classNameSelect}
          name={`${name}Date`}
          onChange={handleUpdateDateSelect}
          options={dates}
          value={date}
        />
      </div>
    </fieldset>
  );
};

export default YearMonthDay;
