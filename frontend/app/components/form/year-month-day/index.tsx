import type {ChangeEventHandler, ComponentProps} from 'react';
import {useCallback, useMemo, useRef} from 'react';
import {useTranslation} from 'react-i18next';
import {
  addDays,
  differenceInDays,
  endOfMonth,
  set,
  startOfMonth,
} from 'date-fns';
import {FieldLegend, FieldSet} from '~/components/ui/field';
import {NativeSelect, NativeSelectOption} from '~/components/ui/native-select';
import {
  formatAbbreviatedMonth,
  formatFullYear,
  formatOrdinalDay,
} from '~/utils/date';
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
  label?: string;
  name?: string;
  onBlur?: () => void;
  onChange: (value: string) => void;
  required?: boolean;
  value: string;
};

const YearMonthDay = ({
  'aria-describedby': ariaDescribedBy,
  'aria-invalid': ariaInvalid,
  className,
  id,
  label,
  name = 'dob',
  onBlur,
  onChange,
  ref,
  required,
  value = DEFAULT_VALUE,
}: YearMonthDayProps) => {
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

  const handleUpdateDateSelect: ChangeEventHandler<HTMLSelectElement> = (
    event
  ) => {
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
  };

  const years = useMemo(
    () =>
      YEARS.map((yearNumber) => ({
        label: formatFullYear(set(DEFAULT_DATE, {year: yearNumber}), language),
        value: String(yearNumber),
      })),
    [language]
  );

  const months = useMemo(
    () =>
      MONTHS.map((monthNumber) => ({
        label: formatAbbreviatedMonth(
          set(DEFAULT_DATE, {month: monthNumber - 1}),
          language
        ),
        value: String(monthNumber).padStart(2, '0'),
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
      .map((monthStartDate, index) => {
        const dayDate: Date = addDays(monthStartDate, index);

        return {
          label:
            language === 'en' ?
              String(dayDate.getDate())
            : formatOrdinalDay(dayDate, language),
          value: String(dayDate.getDate()).padStart(2, '0'),
        };
      });
  }, [language, month, year]);

  const sharedSelectProps = {
    'aria-describedby': ariaDescribedBy,
    'aria-invalid': ariaInvalid,
    onChange: handleUpdateDateSelect,
    required,
  };

  return (
    <FieldSet className={className} onBlur={onBlur}>
      {label && <FieldLegend>{label}</FieldLegend>}
      <div ref={containerRef} className="flex gap-4 md:gap-6">
        <input ref={hiddenRef} name={name} type="hidden" value={value} />
        <NativeSelect
          {...sharedSelectProps}
          ref={ref}
          aria-label={t('date.year')}
          className="flex-1"
          id={id}
          name={`${name}Year`}
          value={year}
        >
          {years.map((option) => (
            <NativeSelectOption key={option.value} value={option.value}>
              {option.label}
            </NativeSelectOption>
          ))}
        </NativeSelect>
        <NativeSelect
          {...sharedSelectProps}
          aria-label={t('date.month')}
          className="flex-1"
          name={`${name}Month`}
          value={month}
        >
          {months.map((option) => (
            <NativeSelectOption key={option.value} value={option.value}>
              {option.label}
            </NativeSelectOption>
          ))}
        </NativeSelect>
        <NativeSelect
          {...sharedSelectProps}
          aria-label={t('date.day')}
          className="flex-1"
          name={`${name}Date`}
          value={date}
        >
          {dates.map((option) => (
            <NativeSelectOption key={option.value} value={option.value}>
              {option.label}
            </NativeSelectOption>
          ))}
        </NativeSelect>
      </div>
    </FieldSet>
  );
};

export default YearMonthDay;
