import gaiaLint from '@gaia-react/lint';
import {defineConfig} from 'eslint/config';
import noImperativeQueryFetch from './eslint/no-imperative-query-fetch.mjs';

const lint = gaiaLint();

export default defineConfig([
  ...lint.ignores({extra: ['.gaia/**']}),
  ...lint.base,
  ...lint.react,
  ...lint.reactRouter,
  ...lint.testing,
  ...lint.storybook,
  ...lint.playwright,
  ...lint.styleHygiene,
  ...lint.guardrails,
  ...lint.betterTailwind({
    entryPoint: './app/styles/tailwind.css',
    ignore: ['dark'],
  }),
  ...lint.prettier,
  ...lint.shadcn({ui: '~/components/ui'}),
  {
    files: ['app/**/*.{ts,tsx}'],
    plugins: {
      local: {rules: {'no-imperative-query-fetch': noImperativeQueryFetch}},
    },
    rules: {'local/no-imperative-query-fetch': 'error'},
  },
]);
