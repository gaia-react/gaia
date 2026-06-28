import type {Preview} from '@storybook/react-vite';
import {themes} from 'storybook/theming';
import {decorators} from './chromatic';
import i18n from './i18next';
import viewport from './viewport';
import './env';
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
      darkClass: ['dark', 'bg-gray-900', 'text-white'],
      light: {
        ...themes.light,
        ...BRAND,
      },
      lightClass: ['light', 'bg-white', 'text-gray-900'],
      stylePreview: true,
    },
    i18n,
    layout: 'fullscreen',
    viewport,
  },
};

export default preview;
