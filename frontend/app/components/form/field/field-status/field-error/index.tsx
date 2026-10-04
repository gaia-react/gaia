import type {FC, ReactNode} from 'react';

type FieldErrorProps = {
  error?: ReactNode;
};

const FieldError: FC<FieldErrorProps> = ({error}) => (
  <div className="text-invalid text-sm whitespace-pre-wrap" role="alert">
    {error}
  </div>
);

export default FieldError;
