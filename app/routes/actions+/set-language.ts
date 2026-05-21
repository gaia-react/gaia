import {data, redirect, replace} from 'react-router';
import {LANGUAGES} from '~/languages';
import {languageCookie} from '~/sessions.server/language';
import {isLocalRedirect} from '~/utils/http';
import type {Route} from './+types/set-language';

export const action = async ({request}: Route.ActionArgs) => {
  const requestText = await request.text();
  const form = new URLSearchParams(requestText);
  const language = form.get('language');
  const redirectUrl = form.get('redirectUrl');

  if (
    language == null ||
    !LANGUAGES.includes(language) ||
    !isLocalRedirect(redirectUrl)
  ) {
    return data(
      {
        message: `language value of ${language} is not a valid language`,
        ok: false,
      },
      {status: 400}
    );
  }

  return replace(redirectUrl, {
    headers: {
      'Set-Cookie': await languageCookie.serialize(language),
    },
  });
};

export const loader = async () => redirect('/', {status: 404});
