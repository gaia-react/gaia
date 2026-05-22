import * as cookie from 'cookie';
import {env} from '~/env.server';

const COOKIE_NAME = '__theme';

export type Theme = 'dark' | 'light';

export const getTheme = (request: Request): null | Theme => {
  const cookieHeader = request.headers.get('Cookie');
  if (!cookieHeader) return null;
  const parsed = cookie.parse(cookieHeader)[COOKIE_NAME];
  if (parsed === 'light' || parsed === 'dark') return parsed;

  return null;
};

export const setTheme = (theme: 'system' | Theme): string => {
  if (theme === 'system') {
    return cookie.serialize(COOKIE_NAME, '', {
      httpOnly: true,
      maxAge: -1,
      path: '/',
      sameSite: 'lax',
      secure: env.NODE_ENV === 'production',
    });
  }

  return cookie.serialize(COOKIE_NAME, theme, {
    httpOnly: true,
    maxAge: 31_536_000,
    path: '/',
    sameSite: 'lax',
    secure: env.NODE_ENV === 'production',
  });
};
