import type {KnipConfig} from 'knip';

export default {
  entry: [
    '.playwright/**/*.ts',
    '.storybook/**/*.{ts,tsx}',
    'app/components/**/*.{ts,tsx}',
    'app/hooks/**/*.ts',
    'app/languages/index.ts',
    'app/middleware/**/*.ts',
    'app/services/**/*.{ts,tsx}',
    'app/types/**/*.ts',
    'app/utils/**/*.ts',
    'test/**/*.{ts,tsx}',
  ],
  ignoreBinaries: ['bats'],
  ignoreDependencies: [
    // remix-i18next's Accept-Language SSR fallback pulls accept-language-parser
    // transitively; it's pre-bundled in vite optimizeDeps and has no direct
    // import, so knip can't see the usage (and its @types pairs with it).
    '@types/accept-language-parser',
    'accept-language-parser',
    '@epic-web/invariant',
    '@msw/data',
    '@playwright-testing-library/test',
    '@react-router/fs-routes',
    '@storybook/addon-docs',
    '@tailwindcss/forms',
    '@tailwindcss/typography',
    'lru-cache',
    'msw-storybook-addon',
    'nanoid',
    'remix-utils',
    'stylelint-config-clean-order',
    'stylelint-config-standard',
    'stylelint-config-tailwindcss',
    'stylelint-order',
    'tailwindcss',
  ],
  ignoreUnresolved: [/\/\+types\//],
  project: ['app/**/*.{ts,tsx}', 'test/**/*.{ts,tsx}'],
} satisfies KnipConfig;
