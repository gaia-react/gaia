import type {ChangeEvent, ComponentProps, FC, ReactNode} from 'react';
import {useState} from 'react';
import type {IconType} from 'react-icons';
import {twJoin, twMerge} from 'tailwind-merge';
import Field from '~/components/Form/Field';
import type {SelectOption} from './types';

export type SelectProps = ComponentProps<'select'> & {
  classNameIcon?: string;
  classNameLabel?: string;
  classNameSelect?: string;
  description?: ReactNode;
  error?: string;
  extra?: ReactNode;
  icon?: IconType;
  iconPosition?: 'left' | 'right';
  label?: ReactNode;
  name: string;
  options: SelectOption[];
  unselected?: string;
  unselectedIcon?: IconType;
};

const Select: FC<SelectProps> = ({
  className,
  classNameIcon,
  classNameLabel,
  classNameSelect,
  defaultValue,
  description,
  disabled,
  error,
  extra,
  icon,
  iconPosition = 'left',
  id,
  label,
  name,
  onChange,
  options,
  ref,
  required,
  unselected,
  unselectedIcon,
  value,
  ...props
}) => {
  const [uncontrolledValue, setUncontrolledValue] = useState(
    () => defaultValue ?? ''
  );

  // Controlled `value` wins so placeholder/icon styling tracks the prop;
  // `uncontrolledValue` only backs the uncontrolled (defaultValue) case.
  const currentValue = value ?? uncontrolledValue;

  const handleChange = (event: ChangeEvent<HTMLSelectElement>) => {
    setUncontrolledValue(event.currentTarget.value || '');
    onChange?.(event);
  };

  return (
    <Field
      className={className}
      classNameLabel={classNameLabel}
      description={description}
      disabled={disabled}
      error={error}
      extra={extra}
      id={id ?? name}
      label={label}
      name={name}
      required={required}
      type="select"
    >
      <div className={twJoin(icon && 'relative')}>
        <select
          ref={ref}
          className={twMerge(
            'w-full',
            disabled ? 'text-disabled'
            : !unselected || currentValue ? 'text-body'
            : 'text-placeholder',
            icon && (iconPosition === 'left' ? 'pl-[2.3rem]' : 'pr-[2.3rem]'),
            classNameSelect
          )}
          defaultValue={defaultValue}
          disabled={disabled}
          id={id ?? name}
          name={name}
          onChange={handleChange}
          required={required}
          value={value}
          {...props}
        >
          {unselected && (
            <option disabled={required} value="">
              {unselected}
            </option>
          )}
          {options.map((option) =>
            option.options ?
              <optgroup key={option.label} label={option.label}>
                {option.options.map((groupOption) => (
                  <option
                    key={`${option.label}-${groupOption.value}`}
                    disabled={groupOption.disabled}
                    value={groupOption.value}
                  >
                    {groupOption.label}
                  </option>
                ))}
              </optgroup>
            : <option
                key={option.value}
                disabled={option.disabled}
                value={option.value}
              >
                {option.label}
              </option>
          )}
        </select>
        {icon &&
          (() => {
            const Icon = icon;

            return (
              <div
                className={twMerge(
                  'pointer-events-none absolute left-[0.8rem]',
                  disabled ? 'text-disabled' : (
                    !currentValue && 'text-placeholder'
                  ),
                  !classNameIcon?.includes('top-') && 'top-[0.575rem]',
                  classNameIcon
                )}
              >
                <Icon />
              </div>
            );
          })()}
      </div>
    </Field>
  );
};

export default Select;
