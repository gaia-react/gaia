import type {ChangeEvent, FC} from 'react';
import {useCallback, useEffect, useState} from 'react';
import {twJoin, twMerge} from 'tailwind-merge';
import Field from '../Field';
import type {InputProps} from '../types';

const InputText: FC<InputProps> = ({
  children,
  className,
  classNameDescription,
  classNameIcon,
  classNameInput,
  classNameLabel,
  description,
  disabled,
  error,
  extra,
  hideMaxLength,
  icon,
  iconPosition = 'left',
  id,
  label,
  maxLength,
  name,
  onChange,
  readOnly,
  ref,
  required,
  type = 'text',
  ...props
}) => {
  const [length, setLength] = useState(
    () => String(props.value ?? props.defaultValue ?? '').length
  );

  useEffect(() => {
    if (props.value !== undefined) {
      // eslint-disable-next-line react-hooks/set-state-in-effect
      setLength(String(props.value).length);
    }
  }, [props.value]);

  const handleUpdateLength = useCallback(
    (event: ChangeEvent<HTMLInputElement>) => {
      if (maxLength) {
        setLength(event.currentTarget.value.length);
      }
      onChange?.(event);
    },
    [maxLength, onChange]
  );

  const Icon = icon;

  return (
    <Field
      className={className}
      classNameDescription={classNameDescription}
      classNameLabel={classNameLabel}
      description={description}
      disabled={disabled ?? readOnly}
      error={error}
      extra={extra}
      hideMaxLength={hideMaxLength}
      id={id ?? name}
      label={label}
      length={length}
      maxLength={maxLength}
      name={name}
      required={required}
      type="input"
    >
      <div className={twJoin((icon ?? children) && 'relative')}>
        <input
          ref={ref}
          aria-describedby={
            description ? `${id ?? name}-description` : undefined
          }
          aria-label={label ? undefined : name}
          className={twJoin(
            'w-full',
            icon && (iconPosition === 'left' ? 'pl-[2.3rem]' : 'pr-[2.3rem]'),
            error && 'input-invalid',
            classNameInput
          )}
          disabled={disabled}
          id={id ?? name}
          maxLength={maxLength}
          name={name}
          onChange={handleUpdateLength}
          readOnly={readOnly}
          required={required}
          tabIndex={readOnly ? -1 : undefined}
          type={type}
          {...props}
        />
        {Icon && (
          <Icon
            className={twMerge(
              'absolute top-[0.825rem] text-gray-400 dark:text-gray-600',
              iconPosition === 'left' ? 'left-3' : 'right-3',
              classNameIcon
            )}
          />
        )}
      </div>
    </Field>
  );
};

export default InputText;
