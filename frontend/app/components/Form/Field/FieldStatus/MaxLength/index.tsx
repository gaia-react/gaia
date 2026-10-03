import type {FC} from 'react';
import {cn} from 'cn';

type MaxLengthProps = {
  className?: string;
  length: number;
  maxLength: number;
};

// index = digit count of maxLength; pixel min-width prevents layout shift as current length changes
const MIN_WIDTHS = [0, 34, 49, 65, 80, 95, 100, 111];

const MaxLength: FC<MaxLengthProps> = ({className, length, maxLength}) => {
  const minWidth = MIN_WIDTHS[String(maxLength).length];

  return (
    <output
      className={cn(
        'flex-initial px-1 pt-0.5 text-right text-xs select-none',
        length < maxLength ? 'text-secondary' : 'text-invalid',
        className
      )}
      style={{minWidth}}
    >
      {length} / {maxLength}
    </output>
  );
};

export default MaxLength;
