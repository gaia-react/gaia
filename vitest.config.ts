/// <reference types="vitest" />
/// <reference types="vite/client" />
/// <reference types="@testing-library/jest-dom" />

import react from '@vitejs/plugin-react';
import {loadEnv} from 'vite';
import {defineConfig} from 'vitest/config';

const ignoreWarnings = ['React DevTools', 'React Router Future Flag Warning'];

export default defineConfig(({mode}) => {
  Object.assign(process.env, loadEnv(mode, process.cwd(), ''));

  return {
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
      env: process.env,
      environment: 'happy-dom',
      globals: true,
      include: ['./app/**/*.test.{ts,tsx}'],
      onConsoleLog: (message) => {
        if (ignoreWarnings.some((warning) => message.includes(warning))) {
          return false;
        }
      },
      setupFiles: ['./test/setup.ts'],
    },
  };
});
