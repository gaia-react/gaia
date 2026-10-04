import type {FC, ReactNode} from 'react';

export type SpanOrLegendProps = {
  children: ReactNode;
  className?: string;
  isLegend?: boolean;
};

const SpanOrLegend: FC<SpanOrLegendProps> = ({
  children,
  className,
  isLegend,
}) =>
  isLegend ?
    <legend className={className}>{children}</legend>
  : <span className={className}>{children}</span>;

export default SpanOrLegend;
