import {useTranslation} from 'react-i18next';
import {cn} from 'cn';
import {Copy} from 'lucide-react';
import {Button} from '~/components/ui/button';
import {tryCatch} from '~/utils/function';

type ErrorStackProps = {
  className?: string;
  stack?: string;
  status?: number;
  statusText?: string;
};

const ErrorStack = ({
  className,
  stack,
  status,
  statusText,
}: ErrorStackProps) => {
  const {t} = useTranslation('common');

  if (stack) {
    const handleCopyStackButton = async () => {
      await tryCatch(async () => navigator.clipboard.writeText(stack));
    };

    const statusDiv =
      status || statusText ?
        <div className="text-muted-foreground space-x-1 pt-px pr-1.5 pl-1 font-sans text-xs leading-none">
          {status !== undefined && <span>{status}</span>}
          {statusText && <span>{statusText}</span>}
        </div>
      : undefined;

    return (
      <div
        className={cn(
          'border-destructive bg-card text-card-foreground relative border-2 text-left text-sm',
          className
        )}
      >
        <div
          className={cn(
            'sticky top-0 flex w-full',
            statusDiv ? 'bg-card items-center justify-between' : 'justify-end'
          )}
        >
          {statusDiv}
          <Button
            onClick={handleCopyStackButton}
            size="xs"
            type="button"
            variant="destructive"
          >
            <Copy aria-hidden={true} />
            {t('copyToClipboard')}
          </Button>
        </div>
        <pre className="px-4 pt-2 pb-4 whitespace-pre-wrap">{stack}</pre>
      </div>
    );
  }

  return undefined;
};

export default ErrorStack;
