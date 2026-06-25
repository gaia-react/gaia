import type {FC, ReactNode} from 'react';
import {twMerge} from 'tailwind-merge';
import FieldDescription from './FieldDescription';
import FieldError from './FieldError';
import MaxLength from './MaxLength';

type FieldStatusProps = {
  className?: string;
  description?: ReactNode;
  disabled?: boolean;
  error?: ReactNode;
  hideMaxLength?: boolean;
  id?: string;
  length?: number;
  maxLength?: number;
};

const FieldStatus: FC<FieldStatusProps> = ({
  className,
  description,
  disabled,
  error,
  hideMaxLength,
  id,
  length,
  maxLength,
}) => {
  const descriptionElement =
    description ?
      <FieldDescription
        description={description}
        disabled={disabled}
        id={id}
        maxLength={maxLength}
      />
    : undefined;

  const errorElement =
    error && error !== true ? <FieldError error={error} /> : undefined;

  return (
    <div className={twMerge('mt-1 ml-px', className)}>
      {!hideMaxLength && maxLength && length !== undefined ?
        <>
          <div className="flex items-start justify-between">
            {descriptionElement ?? errorElement}
            {!(descriptionElement ?? errorElement) && (
              <span className="flex-1 text-sm">&nbsp;</span>
            )}
            <MaxLength length={length} maxLength={maxLength} />
          </div>
          {errorElement}
        </>
      : <>
          {descriptionElement}
          {errorElement}
        </>
      }
    </div>
  );
};

export default FieldStatus;
