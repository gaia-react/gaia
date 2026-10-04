import type {FC, ReactNode} from 'react';
import {Trans} from 'react-i18next';
import {cn} from 'cn';

type FieldRequiredTextProps = {
  className?: string;
  disabled?: boolean;
  error?: ReactNode;
};

const FieldRequiredText: FC<FieldRequiredTextProps> = ({
  className,
  disabled,
  error,
}) => (
  <output
    className={cn(
      'ml-4 block w-fit rounded-full border px-1.5 py-px text-xs font-normal select-none',
      disabled ? 'text-disabled'
      : error ? 'bg-invalid border-invalid text-white'
      : 'border-invalid text-invalid',
      className
    )}
    data-field-required-text={true}
  >
    <Trans ns="common">form.required</Trans>
  </output>
);

export default FieldRequiredText;
