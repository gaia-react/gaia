import type {Preview} from '@storybook/react-vite';
import {mswLoader} from 'msw-storybook-addon/csf3';
import {themes} from 'storybook/theming';
import a11y from './a11y';
import {decorators} from './chromatic';
import i18n from './i18next';
import {allModes} from './modes';
import viewport from './viewport';
import '~/styles/tailwind.css';

const BRAND = {
  brandTarget: '_blank',
  brandTitle: 'GAIA',
  brandUrl: 'https://gaiareact.com/docs/',
};

const preview: Preview = {
  decorators,
  initialGlobals: {
    locale: 'en',
    locales: {
      en: {left: '🇺🇸', right: 'en', title: 'English'},
    },
    // Read only by the Chromatic decorator. Declared here because Storybook
    // drops a global it has no initial value for, which would silently turn
    // the dark mode into a second light snapshot.
    theme: 'light',
  },
  loaders: [mswLoader()],
  parameters: {
    a11y,
    chromatic: {modes: allModes},
    controls: {
      expanded: false,
      hideNoControlsWarning: true,
      matchers: {
        color: /(background|color)$/i,
        date: /Date$/,
      },
    },
    darkMode: {
      dark: {
        ...themes.dark,
        ...BRAND,
      },
      darkClass: ['dark', 'bg-background', 'text-foreground'],
      light: {
        ...themes.light,
        ...BRAND,
      },
      lightClass: ['light', 'bg-background', 'text-foreground'],
      stylePreview: true,
    },
    i18n,
    layout: 'fullscreen',
    viewport,
  },
};

export default preview;
