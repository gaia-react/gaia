import type {StorybookConfig} from '@storybook/react-vite';
import {mergeConfig} from 'vite';

const config: StorybookConfig = {
  addons: [
    '@storybook/addon-links',
    'storybook-react-i18next',
    '@vueless/storybook-dark-mode',
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

  stories: ['../app/**/*.stories.tsx'],

  viteFinal: async (viteConfig) =>
    mergeConfig(viteConfig, {
      define: {
        'import.meta.env.API_URL': JSON.stringify(process.env.API_URL),
        'import.meta.env.COMMIT_SHA': JSON.stringify(process.env.COMMIT_SHA),
        'import.meta.env.MSW_ENABLED': JSON.stringify(process.env.MSW_ENABLED),
        'import.meta.env.NODE_ENV': JSON.stringify(process.env.NODE_ENV),
        'import.meta.env.npm_package_version': JSON.stringify(
          process.env.npm_package_version
        ),
        'import.meta.env.SITE_URL': JSON.stringify(process.env.SITE_URL),
      },
      resolve: {tsconfigPaths: true},
    }),
};

export default config;
