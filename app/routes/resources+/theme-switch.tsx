import type {FC} from 'react';
import {useTranslation} from 'react-i18next';
import {IoDesktopOutline, IoMoon, IoSunny} from 'react-icons/io5';
import {data, redirect, useFetcher, useFetchers} from 'react-router';
import {z} from 'zod';
import {useOptionalHints} from '~/utils/client-hints';
import {useOptionalRequestInfo} from '~/utils/request-info';
import type {Theme} from '~/utils/theme.server';
import {setTheme} from '~/utils/theme.server';
import type {Route} from './+types/theme-switch';

export const ThemeFormSchema = z.object({
  redirectTo: z.string().optional(),
  theme: z.enum(['light', 'dark', 'system']),
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

export const useOptimisticThemeMode = ():
  | 'dark'
  | 'light'
  | 'system'
  | undefined => {
  const fetchers = useFetchers();
  const themeFetcher = fetchers.find(
    (f) => f.formAction === '/resources/theme-switch'
  );

  if (themeFetcher?.formData) {
    const submission = ThemeFormSchema.safeParse({
      redirectTo: themeFetcher.formData.get('redirectTo') ?? undefined,
      theme: themeFetcher.formData.get('theme'),
    });
    if (submission.success) return submission.data.theme;
  }

  return undefined;
};

export const useOptionalTheme = (): Theme | undefined => {
  const hints = useOptionalHints();
  const requestInfo = useOptionalRequestInfo();
  const optimisticMode = useOptimisticThemeMode();

  if (optimisticMode) {
    return optimisticMode === 'system' ? hints?.theme : optimisticMode;
  }

  return requestInfo?.userPrefs.theme ?? hints?.theme;
};

type ThemeSwitchProps = {
  userPreference?: null | Theme;
};

const NEXT_MODE: Record<
  'dark' | 'light' | 'system',
  'dark' | 'light' | 'system'
> = {
  dark: 'system',
  light: 'dark',
  system: 'light',
};

const ICONS = {
  dark: IoMoon,
  light: IoSunny,
  system: IoDesktopOutline,
} as const;

const LABEL_KEYS = {
  dark: 'useSystemTheme',
  light: 'enableDarkMode',
  system: 'enableLightMode',
} as const;

export const ThemeSwitch: FC<ThemeSwitchProps> = ({userPreference}) => {
  const {t} = useTranslation('common', {keyPrefix: 'theme'});
  const fetcher = useFetcher<typeof action>();
  const optimisticMode = useOptimisticThemeMode();

  const mode = optimisticMode ?? userPreference ?? 'system';
  const next = NEXT_MODE[mode];

  return (
    <fetcher.Form action="/resources/theme-switch" method="POST">
      <input name="theme" type="hidden" value={next} />
      <button
        aria-label={t(LABEL_KEYS[mode])}
        className="text-body relative flex size-4.5 items-center gap-2"
        type="submit"
      >
        {(() => {
          const ThemeIcon = ICONS[mode];

          return <ThemeIcon />;
        })()}
      </button>
    </fetcher.Form>
  );
};
