import type {ComponentProps, FC, ReactNode} from 'react';
import CheckboxRadioGroup from '~/components/Form/CheckboxRadioGroup';
import InputRadio from '~/components/Form/InputRadio';
import type {RadioOption} from '~/components/Form/types';
import type {Size} from '~/types';

export type BaseRadioButtonsProps = Omit<
  ComponentProps<'input'>,
  'size' | 'type'
> & {
  classNameLabel?: string;
  error?: ReactNode;
  isHorizontal?: boolean;
  name: string;
  options: RadioOption[];
  size?: Size;
};

const BaseRadioButtons: FC<BaseRadioButtonsProps> = ({
  children,
  className,
  classNameLabel,
  isHorizontal,
  options,
  ...props
}) => (
  <CheckboxRadioGroup className={className} isHorizontal={isHorizontal}>
    {options.map((option) => (
      <InputRadio
        key={option.value}
        className={classNameLabel}
        option={option}
        {...props}
      />
    ))}
    {children}
  </CheckboxRadioGroup>
);

export default BaseRadioButtons;
