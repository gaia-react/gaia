import {data, redirect, replace} from 'react-router';
import {z} from 'zod';
import {LANGUAGES} from '~/languages';
import {languageCookie} from '~/sessions.server/language';
import {isLocalRedirect} from '~/utils/http';
import type {Route} from './+types/set-language';

const SetLanguageSchema = z.object({
  language: z.string().refine((lang) => LANGUAGES.includes(lang)),
  redirectUrl: z.string().startsWith('/').refine(isLocalRedirect),
});

export const action = async ({request}: Route.ActionArgs) => {
  const formData = await request.formData();
  const submission = SetLanguageSchema.safeParse({
    language: formData.get('language'),
    redirectUrl: formData.get('redirectUrl'),
  });

  if (!submission.success) {
    return data(null, {status: 400});
  }

  const {language, redirectUrl} = submission.data;

  return replace(redirectUrl, {
    headers: {
      'Set-Cookie': await languageCookie.serialize(language),
    },
  });
};

export const loader = async () => redirect('/', {status: 404});
