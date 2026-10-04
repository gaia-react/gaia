import type {ComponentProps, ReactNode} from 'react';
import type {IconType} from 'react-icons';

export type InputProps = ComponentProps<'input'> &
  SharedInputProps & {
    classNameIcon?: string;
    classNameInput?: string;
    icon?: IconType;
    iconPosition?: 'left' | 'right';
  };

export type Option = {
  disabled?: boolean;
  label: ReactNode;
  value: string;
};

export type RadioOption = Option & {error?: boolean};

export type SharedInputProps = {
  classNameDescription?: string;
  classNameLabel?: string;
  description?: ReactNode;
  error?: ReactNode;
  extra?: ReactNode;
  hideMaxLength?: boolean;
  label?: ReactNode;
  name: string;
};
