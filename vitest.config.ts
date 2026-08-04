/// <reference types="vitest" />
/// <reference types="vite/client" />
/// <reference types="@testing-library/jest-dom" />

import react from '@vitejs/plugin-react';
import {defineConfig} from 'vitest/config';

const ignoreWarnings = ['React DevTools', 'React Router Future Flag Warning'];

// The suite deliberately does not read `.env`. Workers inherit the shell's own
// `process.env`, and `test/setup.ts` supplies defaults for the keys
// `app/env.server.ts` requires, so a test sees the same environment locally as
// it does in CI, where `.env` is gitignored and absent. Loading `.env` here
// would instead put every value in it, `SESSION_SECRET` included, in reach of
// every test file and every transitive dependency loaded in this process.
export default defineConfig({
  plugins: [react()],
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
          'app/services/api/**/{parsers,requests,requests.server,state,types}.*',
          'app/utils/http.server.ts',
          'app/**/{state,tests}/*',
          'docs/**',
          'test/**/*',
        ],
        provider: 'v8',
      },
      environment: 'happy-dom',
      globals: true,
      include: ['./app/**/*.test.{ts,tsx}', './test/**/*.test.{ts,tsx}'],
      onConsoleLog: (message) => {
        if (ignoreWarnings.some((warning) => message.includes(warning))) {
          return false;
        }
      },
      setupFiles: ['./test/setup.ts'],
  },
});
