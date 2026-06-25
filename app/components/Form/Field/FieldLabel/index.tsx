import type {FC, ReactNode} from 'react';
import {twJoin} from 'tailwind-merge';
import SpanOrLegend from '~/components/Form/Field/FieldLabel/SpanOrLegend';
import FieldExtra from './FieldExtra';
import FieldRequiredText from './FieldRequiredText';

type FieldLabelProps = {
  children: ReactNode;
  className?: string;
  disabled?: boolean;
  error?: ReactNode;
  extra?: ReactNode;
  htmlFor?: string;
  isLegend?: boolean;
  required?: boolean;
};

const FieldLabel: FC<FieldLabelProps> = ({
  children,
  className,
  disabled,
  error,
  extra,
  htmlFor,
  isLegend,
  required,
}) => {
  const innerClassName = twJoin(htmlFor && 'flex-initial');

  const label = (
    <SpanOrLegend
      className={twJoin(
        innerClassName,
        'text-sm',
        disabled ? 'text-disabled' : 'text-secondary'
      )}
      isLegend={isLegend}
    >
      {children}
    </SpanOrLegend>
  );

  const requiredExtra = (!!required || !!extra) && (
    <div>
      {required && <FieldRequiredText disabled={disabled} error={error} />}
      {!!extra && <FieldExtra>{extra}</FieldExtra>}
    </div>
  );

  const outerClassName = twJoin(
    'mb-1 ml-px flex items-center justify-between',
    className
  );

  if (htmlFor) {
    return (
      <label className={outerClassName} htmlFor={htmlFor}>
        {label}
        {requiredExtra}
      </label>
    );
  }

  return (
    <div className={outerClassName}>
      {label}
      {requiredExtra}
    </div>
  );
};

export default FieldLabel;
