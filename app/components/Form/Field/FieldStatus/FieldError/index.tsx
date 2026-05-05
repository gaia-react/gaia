import type {FC, ReactNode} from 'react';

type FieldErrorProps = {
  error?: ReactNode;
};

const FieldError: FC<FieldErrorProps> = ({error}) => (
  <div
    className="whitespace-pre-wrap text-sm text-red-600 dark:text-red-500"
    role="alert"
  >
    {error}
  </div>
);

export default FieldError;
