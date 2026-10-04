import type {FC, ReactNode} from 'react';
import {cn} from 'cn';

export type FormActionsProps = {
  align?: 'left' | 'right';
  children: ReactNode;
  className?: string;
};

const FormActions: FC<FormActionsProps> = ({
  align = 'right',
  children,
  className,
}) => (
  <div
    className={cn(
      'flex gap-4',
      align === 'right' ? 'justify-end' : 'pl-0.5',
      className
    )}
  >
    {children}
  </div>
);

export default FormActions;
