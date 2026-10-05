import type {ToastMessage} from 'remix-toast';
// eslint-disable-next-line import-x/no-restricted-paths -- notify drives the toast manager the root Toaster renders, so it imports the manager from the ui layer
import {toast} from '~/components/ui/toast';
import {md5} from '~/utils/object';

type ToastPayload = Partial<ToastMessage> & {stack?: string};

const DEFAULT_DURATION = 5000;
// Error notifications stay up longer so there is time to read them.
const DEFAULT_ERROR_DURATION = 30_000;

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

type NotifyType = 'error' | 'info' | 'success' | 'warning';

const showToast = (
  type: NotifyType,
  payload: Partial<ToastMessage> | string,
  defaultDuration: number
) => {
  const {description, duration, message, stack} = parsePayload(payload);

  // The toast description renders as a <p>, which cannot hold a stack's block
  // markup, so a dev-only stack goes to the console instead of the toast.
  if (stack && process.env.NODE_ENV !== 'production') {
    // eslint-disable-next-line no-console -- dev-only: the console is where a developer reads a stack
    console.error(stack);
  }

  // A payload with no message (absent or empty) promotes its description to
  // the title. The same payload hashes to the same id, so a repeat updates the
  // live toast in place.
  const hasMessage = Boolean(message);

  return toast.add({
    description: hasMessage ? description : undefined,
    id: md5({payload}),
    timeout: duration ?? defaultDuration,
    title: hasMessage ? message : description,
    type,
  });
};

export const notify = {
  error: (payload: Partial<ToastMessage> | string): string =>
    showToast('error', payload, DEFAULT_ERROR_DURATION),
  info: (payload: Partial<ToastMessage> | string): string =>
    showToast('info', payload, DEFAULT_DURATION),
  success: (payload: Partial<ToastMessage> | string): string =>
    showToast('success', payload, DEFAULT_DURATION),
  warning: (payload: Partial<ToastMessage> | string): string =>
    showToast('warning', payload, DEFAULT_DURATION),
};
