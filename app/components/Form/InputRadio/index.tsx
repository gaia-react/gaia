import type {ComponentProps, FC, ReactNode} from 'react';
import {twMerge} from 'tailwind-merge';
import type {Size} from '~/types';
import type {RadioOption} from '../types';

const SIZE: Record<Size, string> = {
  base: 'size-4',
  lg: 'size-4.5',
  sm: 'size-3.5',
  xl: 'size-5',
  xs: 'size-3',
};

const TEXT_SIZE: Record<Size, string> = {
  base: 'text-base',
  lg: 'text-lg',
  sm: 'text-sm',
  xl: 'text-xl',
  xs: 'text-xs',
};

export type InputRadioProps = Omit<ComponentProps<'input'>, 'size' | 'type'> & {
  classNameLabel?: string;
  error?: ReactNode;
  isHorizontal?: boolean;
  name: string;
  option: RadioOption;
  size?: Size;
};

const InputRadio: FC<InputRadioProps> = ({
  className,
  classNameLabel,
  defaultValue,
  disabled,
  error,
  id,
  name,
  option,
  readOnly,
  required,
  size = 'base',
  ...props
}) => (
  <label
    key={option.value}
    className={twMerge(
      'flex w-fit select-none items-center gap-1.5',
      disabled || option.disabled ? 'cursor-not-allowed' : 'cursor-pointer',
      className
    )}
    htmlFor={`${id ?? name}-${option.value}`}
  >
    <input
      className={SIZE[size]}
      defaultChecked={defaultValue === option.value}
      disabled={disabled ?? option.disabled ?? readOnly}
      id={`${id ?? name}-${option.value}`}
      name={name}
      readOnly={readOnly}
      required={!!(required && (error ?? option.error))}
      tabIndex={readOnly ? -1 : undefined}
      type="radio"
      value={option.value}
      {...props}
    />
    <div
      className={twMerge(
        disabled || option.disabled || readOnly ? 'text-disabled' : 'text-body',
        TEXT_SIZE[size],
        classNameLabel
      )}
    >
      {option.label}
    </div>
  </label>
);

export default InputRadio;
