import type {ChangeEvent, ComponentProps, FC} from 'react';
import {
  useCallback,
  useEffect,
  useImperativeHandle,
  useRef,
  useState,
} from 'react';
import autosize from 'autosize';
import {twMerge} from 'tailwind-merge';
import Field from '~/components/Form/Field';
import type {SharedInputProps} from '~/components/Form/types';

const RESIZE = {
  auto: 'resize-none',
  y: 'resize-y',
};

type TextAreaProps = ComponentProps<'textarea'> &
  SharedInputProps & {
    classNameTextArea?: string;
    name: string;
    onAutoSize?: () => void;
    resize?: 'auto' | 'y';
  };

const TextArea: FC<TextAreaProps> = ({
  className,
  classNameDescription,
  classNameLabel,
  classNameTextArea,
  description,
  disabled,
  error,
  extra,
  hideMaxLength,
  id,
  label,
  maxLength,
  name,
  onAutoSize,
  onChange,
  readOnly,
  ref,
  required,
  resize = 'auto',
  rows = 1,
  value,
  ...props
}) => {
  const innerRef = useRef<HTMLTextAreaElement | null>(null);
  useImperativeHandle(ref, () => innerRef.current!, []);

  const [length, setLength] = useState(
    () => String(value ?? props.defaultValue ?? '').length
  );

  const handleChange = useCallback(
    (event: ChangeEvent<HTMLTextAreaElement>) => {
      if (maxLength) {
        setLength(event.currentTarget.value.length);
      }
      onChange?.(event);
    },
    [maxLength, onChange]
  );

  useEffect(() => {
    if (resize === 'auto' && innerRef.current) {
      const textArea = innerRef.current;

      autosize(textArea);

      if (onAutoSize) {
        textArea.addEventListener('autosize:resized', onAutoSize);
      }

      return () => {
        if (onAutoSize) {
          textArea.removeEventListener('autosize:resized', onAutoSize);
        }
      };
    }
  }, [onAutoSize, resize]);

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
      type="textarea"
    >
      <textarea
        ref={innerRef}
        aria-describedby={description ? `${id ?? name}-description` : undefined}
        aria-label={label ? undefined : name}
        className={twMerge(
          'w-full',
          RESIZE[resize],
          error && 'input-invalid',
          classNameTextArea
        )}
        disabled={disabled}
        id={id ?? name}
        maxLength={maxLength}
        name={name}
        onChange={handleChange}
        readOnly={readOnly}
        rows={rows}
        tabIndex={readOnly ? -1 : undefined}
        {...props}
      />
    </Field>
  );
};

export default TextArea;
