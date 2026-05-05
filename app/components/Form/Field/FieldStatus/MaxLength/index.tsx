import type {FC} from 'react';
import {twJoin} from 'tailwind-merge';

type MaxLengthProps = {
  className?: string;
  length: number;
  maxLength: number;
};

const MIN_WIDTHS = [0, 34, 49, 65, 80, 95, 100, 111];

const MaxLength: FC<MaxLengthProps> = ({className, length, maxLength}) => {
  const minWidth = MIN_WIDTHS[String(maxLength).length];

  return (
    <div
      className={twJoin(
        'flex-initial select-none px-1 pt-0.5 text-right text-xs',
        length < maxLength ? 'text-secondary' : 'text-invalid',
        className
      )}
      style={{minWidth}}
    >
      {length} / {maxLength}
    </div>
  );
};

export default MaxLength;
