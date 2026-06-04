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
  const actionData = useActionData<FormActionData>();
  const [dismissed, setDismissed] = useState<FormActionData>();

  const error = actionData?.error;

  // Dismissal is keyed to the action-data object identity, not the message
  // text; a later action returns a fresh object, so an identical message
  // re-shows instead of staying hidden.
  const result =
    !hide && error !== undefined && actionData !== dismissed ? error : '';

  const handleDismissErrorButton = () => {
    setDismissed(actionData);
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
      onClick={handleDismissErrorButton}
      type="button"
    >
      <span role="alert">{result}</span>
      <IoClose />
    </button>
  );
};

export default FormError;
