import type {FC} from 'react';
import {useState} from 'react';
import {IoClose} from 'react-icons/io5';
import {useActionData} from 'react-router';
import {twMerge} from 'tailwind-merge';

type FormActionData = {
  error?: string;
};

type FormResultProps = {
  className?: string;
  hide?: boolean;
};

const FormError: FC<FormResultProps> = ({className, hide}) => {
  const {error} = useActionData<FormActionData>() ?? {};
  const [dismissed, setDismissed] = useState<string | undefined>();

  const result =
    !hide && error !== undefined && error !== dismissed ? error : '';

  const handleClick = () => {
    setDismissed(error);
  };

  if (!result) {
    return null;
  }

  return (
    <button
      className={twMerge(
        'flex w-full items-center justify-between rounded-sm border-red-600 bg-red-500 px-4 py-2 text-white dark:border-red-400',
        className
      )}
      onClick={handleClick}
      type="button"
    >
      <span role="alert">{result}</span>
      <IoClose />
    </button>
  );
};

export default FormError;
