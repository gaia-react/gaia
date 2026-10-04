import type {ToastMessage} from 'remix-toast';

type ToastPayload = Partial<ToastMessage> & {stack?: string};

export const parsePayload = (
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
