import type {FC} from 'react';
import type {ToastMessage} from 'remix-toast';
import {toast, Toaster} from 'sonner';
import {md5} from '~/utils/object';
import ToastNotification from './ToastNotification';
import {parsePayload} from './ToastNotification/utils';

// Reference
// https://sonner.emilkowal.ski/toaster
// Hover-pause: Sonner sets expanded=true on the <ol> onMouseEnter, which pauses all
// toast timers (including toast.custom) via its internal useEffect. No manual
// onMouseEnter/onMouseLeave needed in ToastNotification.

const DEFAULT_DURATION = 5000;
// Error notifications last longer to allow users to read/copy the stack
const DEFAULT_ERROR_DURATION = 30_000;

const Toast: FC = () => (
  <Toaster
    className="w-90"
    expand={true}
    offset={8}
    position="top-right"
    toastOptions={{unstyled: true}}
    visibleToasts={10}
  />
);

export default Toast;

export const notify = {
  error: (payload: Partial<ToastMessage> | string) => {
    const {duration} = parsePayload(payload);

    return toast.custom(
      (id) => <ToastNotification id={id} payload={payload} type="error" />,
      {duration: duration ?? DEFAULT_ERROR_DURATION, id: md5({payload})}
    );
  },
  info: (payload: Partial<ToastMessage> | string) => {
    const {duration} = parsePayload(payload);

    return toast.custom(
      (id) => <ToastNotification id={id} payload={payload} type="info" />,
      {duration: duration ?? DEFAULT_DURATION, id: md5({payload})}
    );
  },
  success: (payload: Partial<ToastMessage> | string) => {
    const {duration} = parsePayload(payload);

    return toast.custom(
      (id) => <ToastNotification id={id} payload={payload} type="success" />,
      {duration: duration ?? DEFAULT_DURATION, id: md5({payload})}
    );
  },
  warning: (payload: Partial<ToastMessage> | string) => {
    const {duration} = parsePayload(payload);

    return toast.custom(
      (id) => <ToastNotification id={id} payload={payload} type="warning" />,
      {duration: duration ?? DEFAULT_DURATION, id: md5({payload})}
    );
  },
};
