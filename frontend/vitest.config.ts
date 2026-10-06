/// <reference types="vitest" />
/// <reference types="vite/client" />

import {storybookTest} from '@storybook/addon-vitest/vitest-plugin';
import tailwindcss from '@tailwindcss/vite';
import react from '@vitejs/plugin-react';
import {playwright} from '@vitest/browser-playwright';
import {defineConfig} from 'vitest/config';
import type {BrowserConfigOptions} from 'vitest/node';
import {
  isReactCompilerEnabled,
  reactCompiler,
} from './react-compiler.config.ts';

const ignoreWarnings = ['React DevTools', 'React Router Future Flag Warning'];

// The viewport matches the `Desktop Chrome` device the Playwright story scan
// uses, so a story is judged at the same size by both.
// Each browser project names its one instance: two projects on the same
// browser need distinct instance names or Vitest refuses to start.
const createBrowserOptions = (instanceName: string): BrowserConfigOptions => ({
  enabled: true,
  headless: true,
  instances: [{browser: 'chromium', name: instanceName}],
  provider: playwright({
    // Animated stories are asserted and scanned in their settled state.
    contextOptions: {reducedMotion: 'reduce'},
  }),
  viewport: {height: 720, width: 1280},
});

// The suite deliberately does not read `.env`. Workers inherit the shell's own
// `process.env`, and `test/setup.ts` supplies defaults for the keys
// `app/env.server.ts` requires, so a test sees the same environment locally as
// it does in CI, where `.env` is gitignored and absent. Loading `.env` here
// would instead put every value in it, `SESSION_SECRET` included, in reach of
// every test file and every transitive dependency loaded in this process.
//
// Projects inherit this root, so plugins live only on the project that needs
// them: a root plugin would register twice on any project that lists it too.
export default defineConfig({
  define: {
    REACT_COMPILER_ENABLED: JSON.stringify(isReactCompilerEnabled),
  },
  resolve: {
    conditions: ['module-sync'],
    tsconfigPaths: true,
  },
  ssr: {
    noExternal: ['lodash', '@fortawesome/react-fontawesome'],
  },
  test: {
    coverage: {
      exclude: [
        '**/node_modules/**',
        '**/public/**',
        '**/.{idea,git,cache,output,temp}/**',
        '**/{playwright,react-router,vite,vitest}.config.*',
        '.{playwright,storybook}/**/*',
        'app/{languages,routes,sessions.server,state,types}/**/*',
        'app/{entry.client,entry.server,env.server,i18n,i18next.server,root}.*',
        'app/services/api/{index,uris}.ts',
        'app/services/**/{parsers,queries,requests,state,types,urls}.*',
        'app/utils/http.server.ts',
        'app/**/{state,tests}/*',
        'docs/**',
        'test/**/*',
      ],
      provider: 'v8',
    },
    forceRerunTriggers: [
      '**/package.json/**',
      '**/{vitest,vite}.config.*/**',
      '.storybook/**',
      'test/setup.ts',
      'test/setup.browser.ts',
    ],
    onConsoleLog: (message) => {
      if (ignoreWarnings.some((warning) => message.includes(warning))) {
        return false;
      }
    },
    projects: [
      {
        test: {
          environment: 'node',
          exclude: ['app/**/hooks/**'],
          globals: true,
          include: ['app/**/*.test.ts', 'test/**/*.test.ts'],
          name: 'node',
          setupFiles: ['./test/setup.ts'],
        },
      },
      {
        plugins: [react(), tailwindcss(), reactCompiler],
        // The root's `module-sync` condition replaces Vite's default client
        // conditions, so without `browser` msw resolves its Node interceptors.
        resolve: {conditions: ['browser']},
        test: {
          browser: createBrowserOptions('browser'),
          globals: true,
          include: [
            'app/**/*.test.tsx',
            'app/**/hooks/**/*.test.ts',
            'test/**/*.test.tsx',
          ],
          name: 'browser',
          setupFiles: ['./test/setup.browser.ts'],
        },
      },
      {
        // Vite discovers these while the first story loads, and the re-bundle it
        // triggers reloads the page under every other story on a cold cache.
        // No stock story imports the service layer (`ky`, `query-string`), so
        // without them the first story of a newly scaffolded service triggers
        // the same reload against an already warm cache.
        optimizeDeps: {
          include: [
            '@vueless/storybook-dark-mode',
            'chromatic/isChromatic',
            'i18next',
            'ky',
            'msw-storybook-addon',
            'msw-storybook-addon/csf3',
            'msw/browser',
            'msw/http',
            'query-string',
            'storybook/theming',
          ],
        },
        plugins: [
          storybookTest({configDir: '.storybook'}),
          tailwindcss(),
          reactCompiler,
        ],
        test: {
          browser: createBrowserOptions('storybook'),
          name: 'storybook',
        },
      },
    ],
  },
});
