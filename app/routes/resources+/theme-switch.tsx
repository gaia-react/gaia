import type {FC} from 'react';
import {useSyncExternalStore} from 'react';
import {useTranslation} from 'react-i18next';
import {IoDesktopOutline, IoMoon, IoSunny} from 'react-icons/io5';
import {data, redirect, useFetcher, useFetchers} from 'react-router';
import {z} from 'zod';
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

const COLOR_SCHEME_QUERY = '(prefers-color-scheme: dark)';

const subscribeToColorScheme = (onChange: () => void): (() => void) => {
  const query = window.matchMedia(COLOR_SCHEME_QUERY);
  query.addEventListener('change', onChange);

  return () => {
    query.removeEventListener('change', onChange);
  };
};

const getColorSchemeSnapshot = (): Theme =>
  window.matchMedia(COLOR_SCHEME_QUERY).matches ? 'dark' : 'light';

const getColorSchemeServerSnapshot = (): undefined => undefined;

const useSystemTheme = (): Theme | undefined =>
  useSyncExternalStore<Theme | undefined>(
    subscribeToColorScheme,
    getColorSchemeSnapshot,
    getColorSchemeServerSnapshot
  );

export const useOptimisticThemeMode = ():
  | 'dark'
  | 'light'
  | 'system'
  | undefined => {
  const fetchers = useFetchers();
  const themeFetcher = fetchers.find(
    (f) => f.formAction === '/resources/theme-switch'
  );
  const theme = themeFetcher?.formData?.get('theme');
  if (theme === 'dark' || theme === 'light' || theme === 'system') return theme;

  return undefined;
};

export const useOptionalTheme = (): Theme | undefined => {
  const requestInfo = useOptionalRequestInfo();
  const optimisticMode = useOptimisticThemeMode();
  const systemTheme = useSystemTheme();

  if (optimisticMode) {
    return optimisticMode === 'system' ? systemTheme : optimisticMode;
  }

  return requestInfo?.userPrefs.theme ?? systemTheme;
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
        className="text-body size-4.5 relative flex items-center gap-2"
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
