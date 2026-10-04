import {useTranslation} from 'react-i18next';
import {useFetcher} from 'react-router';
import {Monitor, Moon, Sun} from 'lucide-react';
import {ACTION_PATHS} from '~/action-paths';
import {Button} from '~/components/ui/button';
import {useOptimisticThemeMode} from '~/hooks/use-theme';
import type {action} from '~/routes/resources.theme-switch';
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
  dark: Moon,
  light: Sun,
  system: Monitor,
} as const;

const LABEL_KEYS = {
  dark: 'useSystemTheme',
  light: 'enableDarkMode',
  system: 'enableLightMode',
} as const;

const ThemeSwitch = ({userPreference}: ThemeSwitchProps) => {
  const {t} = useTranslation('common', {keyPrefix: 'theme'});
  const fetcher = useFetcher<typeof action>();
  const optimisticMode = useOptimisticThemeMode();

  const mode = optimisticMode ?? userPreference ?? 'system';
  const next = NEXT_MODE[mode];
  const ThemeIcon = ICONS[mode];

  return (
    <fetcher.Form action={ACTION_PATHS.themeSwitch} method="POST">
      <input name="theme" type="hidden" value={next} />
      <Button
        aria-label={t(LABEL_KEYS[mode])}
        size="icon"
        type="submit"
        variant="ghost"
      >
        <ThemeIcon aria-hidden={true} />
      </Button>
    </fetcher.Form>
  );
};

export default ThemeSwitch;
