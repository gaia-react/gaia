import type {FC} from 'react';
import type {IconType} from 'react-icons';
import {useTranslation} from 'react-i18next';
import {
  IoAlertCircle,
  IoCheckmarkCircle,
  IoClose,
  IoInformationCircle,
  IoWarning,
} from 'react-icons/io5';
import type {ToastMessage} from 'remix-toast';
import {toast} from 'sonner';
import {twJoin} from 'tailwind-merge';
import ErrorStack from '~/components/Errors/ErrorStack';
import {parsePayload} from './utils';

type ToastType = 'error' | 'info' | 'success' | 'warning';

const COLOR: Record<ToastType, string> = {
  error: 'bg-red-700',
  info: 'bg-primary-600',
  success: 'bg-green-600',
  warning: 'bg-yellow-600',
};

const ICON: Record<ToastType, IconType> = {
  error: IoAlertCircle,
  info: IoInformationCircle,
  success: IoCheckmarkCircle,
  warning: IoWarning,
};

const ICON_CLASS: Record<ToastType, string> = {
  error: 'shrink-0 text-red-300',
  info: 'shrink-0 text-primary-200',
  success: 'shrink-0 text-green-400',
  warning: 'shrink-0 text-yellow-300',
};

type ToastNotificationProps = {
  id: number | string;
  payload: Partial<ToastMessage> | string;
  type: ToastType;
};

const ToastNotification: FC<ToastNotificationProps> = ({id, payload, type}) => {
  const {t} = useTranslation('common');

  const {description, message, stack} = parsePayload(payload);

  const ToastIcon = ICON[type];
  const hasContent = Boolean(message) || Boolean(description) || Boolean(stack);
  const hasTextAboveStack = Boolean(message) || Boolean(description);

  const handleCloseButton = () => {
    toast.dismiss(id);
  };

  return (
    <div
      className={twJoin(
        'relative w-88 rounded-sm p-3 text-sm text-white',
        COLOR[type]
      )}
    >
      <button
        aria-label={t('close')}
        className="relative float-end ms-2 size-3 text-sm leading-none opacity-50 transition-transform hover:scale-125 hover:opacity-100"
        onClick={handleCloseButton}
        type="button"
      >
        <IoClose className="size-4" />
      </button>
      {hasContent && (
        <div className="flex items-start gap-1">
          <ToastIcon aria-hidden="true" className={ICON_CLASS[type]} />
          <div className="min-w-0">
            <span className="sr-only">{t(`toast.${type}`)}</span>
            {message && (
              <div className="-mt-0.5 leading-tight font-semibold text-pretty">
                {message}
              </div>
            )}
            {description && (
              <div className={twJoin(message && 'mt-1.5')}>{description}</div>
            )}
            {stack && (
              <details className={twJoin(hasTextAboveStack && 'mt-1.5')}>
                <summary className="cursor-pointer">{t('stackTrace')}</summary>
                <ErrorStack
                  className="max-h-60 overflow-y-auto text-xs"
                  stack={stack}
                />
              </details>
            )}
          </div>
        </div>
      )}
    </div>
  );
};

export default ToastNotification;
