import type {MouseEventHandler} from 'react';
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

// Dismissing unmounts the alert along with its focused button, which drops
// focus to <body>; hand it to the form's first control first.
const focusFirstFormControl = (dismissButton: HTMLButtonElement) => {
  const firstControl = [...(dismissButton.form?.elements ?? [])].find(
    (element): element is HTMLElement =>
      element instanceof HTMLElement &&
      element.tabIndex >= 0 &&
      !element.matches(':disabled, [type="hidden"]') &&
      element !== dismissButton
  );

  firstControl?.focus();
};

const FormError = ({className, isHidden}: FormErrorProps) => {
  const {t} = useTranslation('common');
  const actionData = useActionData<FormActionData>();
  const [dismissedActionData, setDismissedActionData] =
    useState<FormActionData>();

  const error = actionData?.error;

  // Dismissal is keyed to the action-data object identity, not the message
  // text; a later action returns a fresh object, so an identical message
  // re-shows instead of staying hidden.
  const visibleErrorMessage =
    !isHidden && error !== undefined && actionData !== dismissedActionData ?
      error
    : '';

  const handleDismissErrorButton: MouseEventHandler<HTMLButtonElement> = (
    event
  ) => {
    // Mobile browsers open the on-screen keyboard when a tap's click handler
    // focuses a text field, and a touch user has no Tab position to keep.
    const isTouchActivation =
      'pointerType' in event.nativeEvent &&
      event.nativeEvent.pointerType === 'touch';

    if (!isTouchActivation) {
      focusFirstFormControl(event.currentTarget);
    }

    setDismissedActionData(actionData);
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
