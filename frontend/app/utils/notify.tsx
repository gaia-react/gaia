import type {ReactNode} from 'react';
import {useTranslation} from 'react-i18next';
import type {ToastMessage} from 'remix-toast';
import type {ToasterProps} from 'sonner';
import {toast} from 'sonner';
// eslint-disable-next-line import-x/no-restricted-paths -- notify is specified to live in app/utils (its callers import it from there) while rendering a component-layer ErrorStack in the toast description
import ErrorStack from '~/components/errors/error-stack';
import {md5} from '~/utils/object';

// Reference
// https://sonner.emilkowal.ski/toaster
// Hover-pause: Sonner sets expanded=true on the <ol> onMouseEnter, which pauses
// all toast timers via its internal useEffect. No manual hover handling needed.

type ToastPayload = Partial<ToastMessage> & {stack?: string};

const DEFAULT_DURATION = 5000;
// Error notifications last longer to allow users to read/copy the stack
const DEFAULT_ERROR_DURATION = 30_000;

// Spreading `toastOptions` over the vendored Toaster replaces its stock object
// wholesale, so `toast` re-declares the vendored class. Error is the only type
// with its own color (destructive); the others stay on the neutral surface and
// are told apart by their icon. Sonner's own styles are unlayered, so the
// destructive utilities need `!` to win over its border and text variables.
export const toasterProps: ToasterProps = {
  expand: true,
  offset: 8,
  position: 'top-right',
  toastOptions: {
    classNames: {
      error: 'border-destructive! text-destructive!',
      toast: 'cn-toast',
    },
  },
  visibleToasts: 10,
};

const parsePayload = (
  payload: Partial<ToastMessage> | string
): ToastPayload => {
  if (typeof payload === 'string') {
    return {message: payload};
  }

  if (payload.message) {
    try {
      const parsed = JSON.parse(payload.message) as ToastMessage;

      if (parsed.message) {
        return {
          ...parsed,
          type: payload.type,
        };
      }
    } catch {
      // message is not JSON
    }
  }

  return payload;
};

const ToastStack = ({
  description,
  stack,
}: {
  description?: string;
  stack: string;
}) => {
  const {t} = useTranslation('common');

  return (
    <>
      {description}
      <details className={description ? 'mt-1.5' : undefined}>
        <summary className="cursor-pointer">{t('stackTrace')}</summary>
        <ErrorStack
          className="max-h-60 overflow-y-auto text-xs"
          stack={stack}
        />
      </details>
    </>
  );
};

type NotifyType = 'error' | 'info' | 'success' | 'warning';

const show = (
  type: NotifyType,
  payload: Partial<ToastMessage> | string,
  defaultDuration: number
) => {
  const {description, duration, message, stack} = parsePayload(payload);
  const showStack = Boolean(stack) && process.env.NODE_ENV !== 'production';

  // Sonner needs a title; a payload with only a description promotes it.
  const title = message ?? description;
  const detail = message ? description : undefined;
  const body: ReactNode =
    showStack && stack ?
      <ToastStack description={detail} stack={stack} />
    : detail;

  return toast[type](title, {
    description: body,
    duration: duration ?? defaultDuration,
    id: md5({payload}),
  });
};

export const notify = {
  error: (payload: Partial<ToastMessage> | string): number | string =>
    show('error', payload, DEFAULT_ERROR_DURATION),
  info: (payload: Partial<ToastMessage> | string): number | string =>
    show('info', payload, DEFAULT_DURATION),
  success: (payload: Partial<ToastMessage> | string): number | string =>
    show('success', payload, DEFAULT_DURATION),
  warning: (payload: Partial<ToastMessage> | string): number | string =>
    show('warning', payload, DEFAULT_DURATION),
};
