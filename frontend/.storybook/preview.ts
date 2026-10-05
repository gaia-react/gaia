import type {Preview} from '@storybook/react-vite';
import {themes} from 'storybook/theming';
import {AXE_WCAG_TAGS} from '../test/axe-tags';
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
  parameters: {
    // Any impact fails here, where the Playwright scan fails only critical and
    // serious. `region` is off because a
    // story renders a fragment outside the page landmarks.
    a11y: {
      config: {rules: [{enabled: false, id: 'region'}]},
      options: {
        runOnly: {
          type: 'tag',
          values: AXE_WCAG_TAGS,
        },
      },
      test: 'error',
    },
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
