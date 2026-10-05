import type {Preview} from '@storybook/react-vite';
import {themes} from 'storybook/theming';
import {decorators} from './chromatic';
import i18n from './i18next';
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
  },
  parameters: {
    // The tag set matches the Playwright story scan, and any impact fails here
    // where the scan fails only critical and serious. `region` is off because a
    // story renders a fragment outside the page landmarks.
    a11y: {
      config: {rules: [{enabled: false, id: 'region'}]},
      options: {
        runOnly: {
          type: 'tag',
          values: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'],
        },
      },
      test: 'error',
    },
    chromatic: {viewports: [1280]},
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
