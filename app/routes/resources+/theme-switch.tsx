import {data, redirect} from 'react-router';
import {z} from 'zod';
import {isLocalRedirect} from '~/utils/http';
import {setTheme} from '~/utils/theme.server';
import type {Route} from './+types/theme-switch';

export const ThemeFormSchema = z.object({
  redirectTo: z.string().refine(isLocalRedirect).optional(),
  theme: z.literal(['dark', 'light', 'system']),
});

export const action = async ({request}: Route.ActionArgs) => {
  const formData = await request.formData();
  const submission = ThemeFormSchema.safeParse({
    redirectTo: formData.get('redirectTo') ?? undefined,
    theme: formData.get('theme'),
  });

  if (!submission.success) {
    return data(
      {errors: z.flattenError(submission.error), result: 'error'} as const,
      {status: 400}
    );
  }

  const {redirectTo, theme} = submission.data;
  const headers = {'set-cookie': setTheme(theme)};

  if (redirectTo) {
    return redirect(redirectTo, {headers});
  }

  return data({result: 'success'} as const, {headers});
};
