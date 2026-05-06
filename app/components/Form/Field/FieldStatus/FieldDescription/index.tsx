import type {FC, ReactNode} from 'react';
import {twJoin} from 'tailwind-merge';

type FieldDescriptionProps = {
  description?: ReactNode;
  disabled?: boolean;
  id?: string;
  maxLength?: number;
};

const FieldDescription: FC<FieldDescriptionProps> = ({
  description,
  disabled,
  id,
  maxLength,
}) => (
  <div
    className={twJoin(
      'whitespace-pre-line text-xs',
      maxLength && 'flex-1 pr-1',
      disabled ? 'text-disabled' : 'text-secondary'
    )}
    id={id ? `${id}-description` : undefined}
    role="note"
  >
    {description}
  </div>
);

export default FieldDescription;
