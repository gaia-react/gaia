import type {StorybookConfig} from '@storybook/react-vite';

// The preview inlines no environment values. `window.process.env` stays the
// empty object `preview-head.html` seeds, so a story reading a client env var
// reads `undefined` under `storybook dev` exactly as it does in a built
// preview, and no deployment value reaches a published snapshot. Give a story
// the values it needs as args instead.

const config: StorybookConfig = {
  addons: [
    '@storybook/addon-a11y',
    '@storybook/addon-links',
    '@storybook/addon-vitest',
    'storybook-react-i18next',
    '@vueless/storybook-dark-mode',
    'msw-storybook-addon',
  ],

  docs: {},

  features: {
    backgrounds: false,
    measure: false,
    outline: false,
  },

  framework: {
    name: '@storybook/react-vite',
    options: {
      builder: {
        viteConfigPath: '.storybook/vite.config.ts',
      },
    },
  },

  // `mockServiceWorker.js` lives in `public/`; a built Storybook only serves it
  // when the folder is a static dir.
  staticDirs: ['../public'],

  stories: ['../app/**/*.stories.tsx'],
};

export default config;
