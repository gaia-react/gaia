import type {FC} from 'react';
import {useCallback, useEffect, useRef, useState} from 'react';
import type {IconType} from 'react-icons';
import {useTranslation} from 'react-i18next';
import {
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
  info: 'bg-blue-600',
  success: 'bg-green-600',
  warning: 'bg-yellow-600',
};

const ICON: Record<ToastType, IconType> = {
  error: IoWarning,
  info: IoInformationCircle,
  success: IoCheckmarkCircle,
  warning: IoWarning,
};

const ICON_COLOR: Record<ToastType, string> = {
  error: 'text-red-300',
  info: 'text-blue-300',
  success: 'text-green-400',
  warning: 'text-yellow-300',
};

const DEFAULT_DURATION = 5000;
// Error notifications last longer to allow users to read/copy the stack
const DEFAULT_ERROR_DURATION = 30_000;

type ToastNotificationProps = {
  id: number | string;
  payload: Partial<ToastMessage> | string;
  type: ToastType;
};

const ToastNotification: FC<ToastNotificationProps> = ({id, payload, type}) => {
  const {t} = useTranslation('common');
  const [isHovered, setIsHovered] = useState(false);
  const timeoutRef = useRef(0);

  const {description, duration, message, stack} = parsePayload(payload);

  const toastDuration =
    duration ?? (type === 'error' ? DEFAULT_ERROR_DURATION : DEFAULT_DURATION);

  const handleClose = useCallback(() => {
    if (timeoutRef.current) {
      clearTimeout(timeoutRef.current);
    }
    toast.dismiss(id);
  }, [id]);

  useEffect(() => {
    if (timeoutRef.current) {
      clearTimeout(timeoutRef.current);
    }

    if (!isHovered) {
      timeoutRef.current = window.setTimeout(
        () => toast.dismiss(id),
        toastDuration
      );
    }

    return () => {
      if (timeoutRef.current) {
        clearTimeout(timeoutRef.current);
      }
    };
  }, [id, isHovered, toastDuration]);

  return (
    <div
      className={twJoin(
        'w-88 relative rounded-sm p-3 text-sm text-white',
        COLOR[type]
      )}
      onMouseEnter={() => {
        setIsHovered(true);
      }}
      onMouseLeave={() => {
        setIsHovered(false);
      }}
    >
      <button
        aria-label={t('close')}
        className="relative float-end ms-2 size-3 text-sm leading-none opacity-50 transition-transform hover:scale-125 hover:opacity-100"
        onClick={handleClose}
        type="button"
      >
        <IoClose className="size-4" />
      </button>
      {message && (
        <div className="flex items-start gap-1">
          {(() => {
            const ToastIcon = ICON[type];

            return <ToastIcon className={ICON_COLOR[type]} />;
          })()}
          <div className="-mt-0.5 text-pretty font-semibold leading-tight">
            {message}
          </div>
        </div>
      )}
      {description && (
        <div className={twJoin(message && 'mt-1.5')}>{description}</div>
      )}
      {stack && (
        <details className={twJoin((message ?? description) && 'mt-1.5')}>
          <summary className="cursor-pointer">{t('stackTrace')}</summary>
          <ErrorStack
            className="max-h-60 overflow-y-auto text-xs"
            stack={stack}
          />
        </details>
      )}
    </div>
  );
};

export default ToastNotification;
