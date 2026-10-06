// Runs in the node project.
import {ESLint, RuleTester} from 'eslint';
import {describe, expect, test} from 'vitest';
import path from 'node:path';
import rule from '../../eslint/no-imperative-query-fetch.mjs';

RuleTester.describe = describe;
RuleTester.it = test;
RuleTester.itOnly = test.only;

const BANNED_METHODS = [
  'ensureQueryData',
  'fetchQuery',
  'prefetchQuery',
  'ensureInfiniteQueryData',
  'fetchInfiniteQuery',
  'prefetchInfiniteQuery',
];

const errorContaining = (method: string) => ({
  message: new RegExp(
    String.raw`${method}.*queryClient\.(query|infiniteQuery)`
  ),
});

const invalid = BANNED_METHODS.flatMap((method) => [
  {code: `queryClient.${method}(options);`, errors: [errorContaining(method)]},
  {
    code: `useQueryClient().${method}(options);`,
    errors: [errorContaining(method)],
  },
  {code: `queryClient?.${method}(options);`, errors: [errorContaining(method)]},
  {
    code: `queryClient['${method}'](options);`,
    errors: [errorContaining(method)],
  },
  {
    code: `this.client.${method}(options);`,
    errors: [errorContaining(method)],
  },
]);

new RuleTester({
  languageOptions: {ecmaVersion: 'latest', sourceType: 'module'},
}).run('no-imperative-query-fetch', rule, {
  invalid,
  valid: [
    'queryClient.query(options);',
    'queryClient.invalidateQueries({queryKey: keys.all});',
    'queryClient.getQueryData(key);',
    'fetchQueryParams();',
    'queryClient[methodName](options);',
  ],
});

// The first lintText builds the type-aware TypeScript program for the whole
// project, which outlasts the default 5s timeout when the full suite runs.
describe(
  'no-imperative-query-fetch in the resolved project config',
  {
    timeout: 60_000,
  },
  () => {
    const frontendDirectory = path.resolve(import.meta.dirname, '../..');
    const filePath = path.join(frontendDirectory, 'app/root.tsx');
    const eslint = new ESLint({cwd: frontendDirectory});

    const ruleIdsFor = async (code: string) => {
      const [result] = await eslint.lintText(code, {filePath});

      return result.messages.map((message) => message.ruleId);
    };

    test('reports an imperative fetch', async () => {
      const ruleIds = await ruleIdsFor(
        'export const load = (queryClient: {fetchQuery: (o: unknown) => unknown}) => queryClient.fetchQuery({});\n'
      );

      expect(ruleIds).toContain('local/no-imperative-query-fetch');
    });

    test('keeps the inherited no-restricted-properties entries', async () => {
      const ruleIds = await ruleIdsFor(
        'export const value = Math.pow(2, 3);\n'
      );

      expect(ruleIds).toContain('no-restricted-properties');
    });

    test('keeps the inherited no-restricted-syntax selectors', async () => {
      const ruleIds = await ruleIdsFor(
        'export default function Example() {\n  return 1;\n}\n'
      );

      expect(ruleIds).toContain('no-restricted-syntax');
    });
  }
);
