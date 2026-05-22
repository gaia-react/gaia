import {useSyncExternalStore} from 'react';
import {useFetchers} from 'react-router';
import {useOptionalRequestInfo} from '~/utils/request-info';
import type {Theme} from '~/utils/theme.server';

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

export const useSystemTheme = (): Theme | undefined =>
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
