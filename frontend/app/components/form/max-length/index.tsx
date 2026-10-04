import {cva} from 'class-variance-authority';
import {cn} from 'cn';

type MaxLengthProps = {
  className?: string;
  length: number;
  maxLength: number;
};

// Reserves the width of the widest "length / maxLength" text for the digit
// count of maxLength, so the counter does not shift as the length grows.
const maxLengthVariants = cva(
  'flex-initial px-1 pt-0.5 text-right text-xs select-none',
  {
    defaultVariants: {digits: 1, isAtLimit: false},
    variants: {
      digits: {
        1: 'min-w-9',
        2: 'min-w-12',
        3: 'min-w-16',
        4: 'min-w-20',
        5: 'min-w-24',
        6: 'min-w-25',
        7: 'min-w-28',
      },
      isAtLimit: {
        false: 'text-muted-foreground',
        true: 'text-destructive',
      },
    },
  }
);

const MAX_DIGITS = 7;

const MaxLength = ({className, length, maxLength}: MaxLengthProps) => {
  const digits = Math.min(String(maxLength).length, MAX_DIGITS) as
    1 | 2 | 3 | 4 | 5 | 6 | 7;

  return (
    <output
      className={cn(
        maxLengthVariants({digits, isAtLimit: length >= maxLength}),
        className
      )}
    >
      {length} / {maxLength}
    </output>
  );
};

export default MaxLength;
