import type {ComponentProps, FC, ReactNode} from 'react';
import CheckboxRadioGroup from '~/components/form/checkbox-radio-group';
import InputRadio from '~/components/form/input-radio';
import type {RadioOption} from '~/components/form/types';
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
