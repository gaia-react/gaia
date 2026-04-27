import gaiaLint from '@gaia-react/lint';
import {defineConfig} from 'eslint/config';

export default defineConfig([
  ...gaiaLint.ignores({gitignore: '.gitignore'}),
  ...gaiaLint.base,
  ...gaiaLint.react,
  ...gaiaLint.testing,
  ...gaiaLint.storybook,
  ...gaiaLint.playwright,
  ...gaiaLint.styleHygiene,
  ...gaiaLint.guardrails,
  ...gaiaLint.betterTailwind({
    entryPoint: './app/styles/tailwind.css',
    ignore: ['plain-link', 'plain-table'],
  }),
  ...gaiaLint.prettier,
]);
