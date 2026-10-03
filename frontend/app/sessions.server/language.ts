import {createCookie} from 'react-router';
import {env} from '~/env.server';

export const languageCookie = createCookie('lng', {
  httpOnly: true,
  maxAge: 31_536_000,
  path: '/',
  sameSite: 'lax',
  secrets: [env.SESSION_SECRET],
  // You cannot set true in Safari unless you're in production
  secure: env.NODE_ENV === 'production',
});
