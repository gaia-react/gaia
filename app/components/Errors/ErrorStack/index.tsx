import type {FC} from 'react';
import {IoCopyOutline} from 'react-icons/io5';
import {twJoin, twMerge} from 'tailwind-merge';

type ErrorStackProps = {
  className?: string;
  stack?: string;
  status?: number;
  statusText?: string;
};

const ErrorStack: FC<ErrorStackProps> = ({
  className,
  stack,
  status,
  statusText,
}) => {
  if (stack) {
    const handleClick = async () => {
      await navigator.clipboard.writeText(stack);
    };

    const statusDiv =
      status || statusText ?
        <div className="space-x-1 pt-px pr-1.5 pl-1 font-sans text-xs leading-none text-white">
          {status && <span>{status}</span>}
          {statusText && <span>{statusText}</span>}
        </div>
      : undefined;

    return (
      <pre
        className={twMerge(
          'relative border-2 border-red-700 bg-gray-900 text-left text-sm whitespace-pre-wrap text-white',
          className
        )}
      >
        <div
          className={twJoin(
            'sticky top-0 flex w-full',
            statusDiv ?
              'items-center justify-between bg-gray-900'
            : 'justify-end'
          )}
        >
          {statusDiv}
          <button
            className="flex items-center gap-1 rounded-bl-sm bg-red-700 pt-px pr-1 pb-1 pl-1.5 font-sans text-xs leading-none text-white hover:bg-red-600"
            onClick={handleClick}
            type="button"
          >
            <IoCopyOutline />
            <span>Copy to clipboard</span>
          </button>
        </div>
        <div className="px-4 pt-2 pb-4">{stack}</div>
      </pre>
    );
  }
};

export default ErrorStack;
