import gaiaLint from '@gaia-react/lint';
import {defineConfig} from 'eslint/config';

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
    ignore: ['plain-link', 'plain-table', 'toaster'],
  }),
  ...lint.prettier,
  // Transitional: mirrors the vendored-ui exemption the lint package ships and
  // is replaced when that release is wired. The ui files are shadcn registry
  // output kept byte-identical to `shadcn add`; `react-hooks/*` and the other
  // correctness rules stay on.
  {
    files: ['app/components/ui/*.tsx'],
    name: 'gaia/vendored-ui-transitional',
    rules: {
      '@stylistic/quotes': 'off',
      '@typescript-eslint/array-type': 'off',
      '@typescript-eslint/naming-convention': 'off',
      '@typescript-eslint/no-unnecessary-condition': 'off',
      '@typescript-eslint/no-use-before-define': 'off',
      '@typescript-eslint/promise-function-async': 'off',
      'better-tailwindcss/enforce-canonical-classes': 'off',
      'better-tailwindcss/enforce-shorthand-classes': 'off',
      'canonical/export-specifier-newline': 'off',
      eqeqeq: 'off',
      'import-x/consistent-type-specifier-style': 'off',
      'jsx-a11y/click-events-have-key-events': 'off',
      'jsx-a11y/label-has-associated-control': 'off',
      'jsx-a11y/no-noninteractive-element-interactions': 'off',
      'no-null-render/no-null-render': 'off',
      'no-underscore-dangle': 'off',
      'perfectionist/sort-imports': 'off',
      'perfectionist/sort-intersection-types': 'off',
      'perfectionist/sort-jsx-props': 'off',
      'perfectionist/sort-modules': 'off',
      'perfectionist/sort-named-exports': 'off',
      'perfectionist/sort-named-imports': 'off',
      'perfectionist/sort-object-types': 'off',
      'perfectionist/sort-objects': 'off',
      'perfectionist/sort-union-types': 'off',
      'prefer-arrow-functions/prefer-arrow-functions': 'off',
      'prettier/prettier': 'off',
      'react/boolean-prop-naming': 'off',
      'react/no-array-index-key': 'off',
      'sonarjs/prefer-read-only-props': 'off',
      'unicorn/prevent-abbreviations': 'off',
    },
  },
]);
