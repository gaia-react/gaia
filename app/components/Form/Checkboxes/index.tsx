import type {FC, ReactNode} from 'react';
import {useId} from 'react';
import type {Size} from '~/types';
import Checkbox from '../Checkbox';
import CheckboxRadioGroup from '../CheckboxRadioGroup';
import Field from '../Field';

export type CheckboxesProps = {
  className?: string;
  classNameGroup?: string;
  description?: ReactNode;
  disabled?: boolean;
  error?: ReactNode;
  isHorizontal?: boolean;
  label?: ReactNode;
  options: CheckboxOption[];
  required?: boolean;
  size?: Size;
};

type CheckboxOption = {
  disabled?: boolean;
  error?: boolean;
  label: ReactNode;
  name: string;
  required?: boolean | string;
};

const Checkboxes: FC<CheckboxesProps> = ({
  className,
  classNameGroup,
  description,
  disabled,
  error,
  isHorizontal,
  label,
  options,
  required,
  ...rest
}) => {
  const groupId = useId();

  const isDisabled =
    disabled ??
    (options.length > 0 && options.every((option) => option.disabled));
  const isRequired =
    options.length > 0 && options.every((option) => option.required);

  return (
    <Field
      className={className}
      description={description}
      disabled={isDisabled}
      error={error}
      id={groupId}
      label={label}
      required={isRequired}
      type="radio"
    >
      <CheckboxRadioGroup
        className={classNameGroup}
        isHorizontal={isHorizontal}
      >
        {options.map((option) => (
          <Checkbox
            key={option.name}
            aria-describedby={
              description ? `${groupId}-description` : undefined
            }
            disabled={isDisabled || option.disabled}
            label={option.label}
            name={option.name}
            required={!!(option.required && error && option.error)}
            {...rest}
          />
        ))}
      </CheckboxRadioGroup>
    </Field>
  );
};

export default Checkboxes;
