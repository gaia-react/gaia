import {useState} from 'react';
import {useTranslation} from 'react-i18next';
import {useActionData} from 'react-router';
import {CircleAlert, X} from 'lucide-react';
import {Alert, AlertAction, AlertDescription} from '~/components/ui/alert';
import {Button} from '~/components/ui/button';

type FormActionData = {
  error?: string;
};

type FormErrorProps = {
  className?: string;
  isHidden?: boolean;
};

const FormError = ({className, isHidden}: FormErrorProps) => {
  const {t} = useTranslation('common');
  const actionData = useActionData<FormActionData>();
  const [dismissed, setDismissed] = useState<FormActionData>();

  const error = actionData?.error;

  // Dismissal is keyed to the action-data object identity, not the message
  // text; a later action returns a fresh object, so an identical message
  // re-shows instead of staying hidden.
  const visibleErrorMessage =
    !isHidden && error !== undefined && actionData !== dismissed ? error : '';

  const handleDismissErrorButton = () => {
    setDismissed(actionData);
  };

  if (!visibleErrorMessage) {
    return undefined;
  }

  return (
    <Alert className={className} variant="destructive">
      <CircleAlert aria-hidden={true} />
      <AlertDescription>{visibleErrorMessage}</AlertDescription>
      <AlertAction>
        <Button
          aria-label={t('dismiss')}
          onClick={handleDismissErrorButton}
          size="icon-xs"
          type="button"
          variant="ghost"
        >
          <X aria-hidden={true} />
        </Button>
      </AlertAction>
    </Alert>
  );
};

export default FormError;
