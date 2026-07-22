import type {StorybookConfig} from '@storybook/react-vite';
import {loadEnv, mergeConfig} from 'vite';

// The keys the preview inlines. `clientSchema` in `app/env.server.ts` is the
// authority on what may reach a browser: it types `Window['process']['env']`,
// so this fails to compile if it names a key that schema withholds or drops one
// it allows. `.storybook/env.ts` pins its own literal against the same type.
const previewEnvKeys = {
  API_URL: true,
  COMMIT_SHA: true,
  MSW_ENABLED: true,
  NODE_ENV: true,
  npm_package_version: true,
} satisfies Record<keyof Window['process']['env'], true>;

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

  viteFinal: async (viteConfig, {configType}) => {
    // Read the env into a local binding rather than the whole `.env` file into
    // the build process's `process.env`, which every Vite plugin, Storybook
    // addon, and transitive dependency in this process can read. Prefer the
    // mode Vite resolved, so a custom `--mode` still selects its own `.env`.
    const env = loadEnv(
      viteConfig.mode ??
        (configType === 'PRODUCTION' ? 'production' : 'development'),
      process.cwd(),
      ''
    );

    return mergeConfig(viteConfig, {
      define: Object.fromEntries(
        Object.keys(previewEnvKeys).map((key) => [
          `import.meta.env.${key}`,
          JSON.stringify(env[key]),
        ])
      ),
      resolve: {tsconfigPaths: true},
    });
  },
};

export default config;
