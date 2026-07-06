import gaiaLint from '@gaia-react/lint';
import {defineConfig} from 'eslint/config';

/*
 * ESLint config for the gaia CLI (@gaia-react/cli).
 *
 * The CLI is a Node/TypeScript program (NodeNext ESM, esbuild-bundled), not a
 * React app. It consumes @gaia-react/lint's base/testing/styleHygiene/
 * guardrails/prettier presets and OMITS the React-app-only presets (storybook,
 * playwright, betterTailwind). `react` is spread in only because `base`
 * transitively references `react/*` rules through airbnb's shared TypeScript
 * config; the React ruleset is inert on the CLI's non-JSX TypeScript.
 */
const lint = gaiaLint({sourceDir: 'src'});

export default defineConfig([
  ...lint.ignores(),
  ...lint.base,
  ...lint.react,
  ...lint.testing,
  ...lint.styleHygiene,
  ...lint.guardrails,
  ...lint.prettier,
  {
    name: 'gaia-cli/node-context',
    rules: {
      // The CLI orchestrates git/gh/pnpm/node by name off PATH; requiring
      // absolute binary paths is impractical and machine-specific.
      'sonarjs/no-os-command-from-path': 'off',
      // The CLI uses NodeNext relative '.js' imports and defines no '~' alias;
      // this rule's autofix rewrites deep imports to '~/…', which does not
      // resolve and breaks both typecheck and the esbuild bundle.
      'no-relative-import-paths/no-relative-import-paths': 'off',
      // GAIA-React convention: test/story files must sit in a `tests/` folder.
      // The CLI co-locates tests and uses `__tests__/`, so this fires on every
      // test file.
      'check-file/folder-match-with-fex': 'off',
      // prevent-abbreviations: extend the shared ignore list (this override
      // replaces it) with Node/CLI-idiomatic abbreviations.
      'unicorn/prevent-abbreviations': [
        'error',
        {
          ignore: [
            'acc', 'ctx', 'e2e', 'env', 'obj', 'prev', 'req', 'res',
            'dir', 'err', 'pkg', 'idx', 'doc', 'rel', 'cmd', 'msg',
            'str', 'num', 'val', 'fs', 'os', 'db', 'tmp', 'arg',
            /args/i, /fn/i, /param/i, /params/i, /props/i, /ref/i,
            /src/i, /utils/i, /dir/i, /var/i,
          ],
        },
      ],
    },
  },
  {
    // testing-library targets React Testing Library; the CLI's Vitest suites
    // are Node unit tests. render-result-naming-convention false-fires on the
    // CLI's own render* helpers.
    files: ['**/*.test.ts'],
    name: 'gaia-cli/no-testing-library',
    rules: {
      'testing-library/render-result-naming-convention': 'off',
    },
  },
]);
