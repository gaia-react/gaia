import type {FC} from 'react';
import {useTranslation} from 'react-i18next';
import {IoDesktopOutline, IoMoon, IoSunny} from 'react-icons/io5';
import {useFetcher} from 'react-router';
import {useOptimisticThemeMode} from '~/hooks/useTheme';
import type {action} from '~/routes/resources+/theme-switch';
import type {Theme} from '~/utils/theme.server';

export type ThemeSwitchProps = {
  userPreference?: Theme;
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

const ThemeSwitch: FC<ThemeSwitchProps> = ({userPreference}) => {
  const {t} = useTranslation('common', {keyPrefix: 'theme'});
  const fetcher = useFetcher<typeof action>();
  const optimisticMode = useOptimisticThemeMode();

  const mode = optimisticMode ?? userPreference ?? 'system';
  const next = NEXT_MODE[mode];
  const ThemeIcon = ICONS[mode];

  return (
    <fetcher.Form action="/resources/theme-switch" method="POST">
      <input name="theme" type="hidden" value={next} />
      <button
        aria-label={t(LABEL_KEYS[mode])}
        className="text-body relative flex size-4.5 items-center gap-2"
        type="submit"
      >
        <ThemeIcon aria-hidden={true} />
      </button>
    </fetcher.Form>
  );
};

export default ThemeSwitch;
