import type {FC, ReactNode} from 'react';

type FieldErrorProps = {
  error?: ReactNode;
};

const FieldError: FC<FieldErrorProps> = ({error}) => (
  <div className="text-invalid whitespace-pre-wrap text-sm" role="alert">
    {error}
  </div>
);

export default FieldError;
