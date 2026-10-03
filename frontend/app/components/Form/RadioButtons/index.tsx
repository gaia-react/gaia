import type {ComponentProps, FC, ReactNode} from 'react';
import Field from '~/components/Form/Field';
import type {Size} from '~/types';
import type {Option} from '../types';
import BaseRadioButtons from './BaseRadioButtons';

export type RadioButtonsProps = Omit<
  ComponentProps<'input'>,
  'size' | 'type'
> & {
  classNameGroup?: string;
  classNameLabel?: string;
  description?: ReactNode;
  error?: ReactNode;
  isHorizontal?: boolean;
  label?: ReactNode;
  name: string;
  options: Option[];
  size?: Size;
};

const RadioButtons: FC<RadioButtonsProps> = ({
  className,
  classNameGroup,
  classNameLabel,
  description,
  disabled,
  error,
  isHorizontal,
  label,
  readOnly,
  required,
  ...props
}) => (
  <Field
    className={className}
    description={description}
    disabled={disabled ?? readOnly}
    error={error}
    label={label}
    required={required}
    type="radio"
  >
    <BaseRadioButtons
      className={classNameGroup}
      classNameLabel={classNameLabel}
      disabled={disabled}
      error={error}
      isHorizontal={isHorizontal}
      readOnly={readOnly}
      required={required}
      {...props}
    />
  </Field>
);

export default RadioButtons;
