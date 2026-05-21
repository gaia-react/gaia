import type {ComponentProps, FC, ReactNode} from 'react';
import {twMerge} from 'tailwind-merge';
import type {Size} from '~/types';
import FieldStatus from '../Field/FieldStatus';

const SIZE: Record<Size, string> = {
  base: 'size-4 rounded-sm',
  lg: 'size-4.5 rounded-sm',
  sm: 'size-3.5 rounded-sm',
  xl: 'size-5 rounded-sm',
  xs: 'size-3 rounded-xs',
};

const TEXT_SIZE: Record<Size, string> = {
  base: 'gap-2 text-base',
  lg: 'gap-2 text-lg',
  sm: 'gap-1.5 text-sm',
  xl: 'gap-2 text-xl',
  xs: 'gap-1.5 text-xs',
};

export type CheckboxProps = Omit<ComponentProps<'input'>, 'size' | 'type'> & {
  classNameDescription?: string;
  classNameInput?: string;
  classNameLabel?: string;
  description?: ReactNode;
  error?: ReactNode;
  label?: ReactNode;
  name: string;
  size?: Size;
  type?: never;
};

const Checkbox: FC<CheckboxProps> = ({
  className,
  classNameDescription,
  classNameInput,
  classNameLabel,
  description,
  disabled,
  error,
  id,
  label,
  name,
  readOnly,
  ref,
  required,
  size = 'base',
  ...props
}) => {
  const checkbox = (
    <input
      ref={ref}
      className={twMerge(SIZE[size], classNameInput)}
      id={id ?? name}
      name={name}
      required={required}
      type="checkbox"
      {...props}
      disabled={disabled ?? readOnly}
    />
  );

  const status =
    (description ?? error) ?
      <FieldStatus
        className={twMerge('mt-0', classNameDescription)}
        description={description}
        disabled={disabled}
        error={error}
        id={id}
      />
    : null;

  if (!label) {
    return (
      <>
        {checkbox}
        {status}
      </>
    );
  }

  const field = (
    <label
      className={twMerge(
        'group inline-flex w-fit select-none items-center [&_a]:underline',
        disabled ? 'cursor-not-allowed' : 'cursor-pointer',
        TEXT_SIZE[size],
        classNameLabel
      )}
      htmlFor={id ?? name}
    >
      {checkbox}
      <div className={(disabled ?? readOnly) ? 'text-disabled' : 'text-body'}>
        {label}
      </div>
    </label>
  );

  if (!status) {
    return field;
  }

  return (
    <div className={className}>
      {field}
      {status}
    </div>
  );
};

export default Checkbox;
