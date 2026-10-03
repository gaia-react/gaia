import {reactRouter} from '@react-router/dev/vite';
import tailwindcss from '@tailwindcss/vite';
import {defineConfig} from 'vite';

// Open the browser only when a person runs `pnpm dev` in a terminal. Tools that
// spawn the dev server (Playwright, agents, CI) pipe stdout, so they get no tab.
const canOpenBrowser = !!process.stdout.isTTY && !process.env.CI;

export default defineConfig({
  build: {
    emptyOutDir: true,
    sourcemap: true,
  },
  define: {
    'process.env.COMMIT_SHA': JSON.stringify(process.env.COMMIT_SHA ?? ''),
    'process.env.npm_package_version': JSON.stringify(
      process.env.npm_package_version ?? ''
    ),
  },
  optimizeDeps: {
    include: [
      '@msw/data',
      'accept-language-parser',
      'cn',
      'date-fns',
      'i18next',
      'i18next-browser-languagedetector',
      'ky',
      'lodash-es',
      'msw',
      'msw/browser',
      'nanoid',
      'query-string',
      'react-i18next',
      'remix-i18next',
      'remix-toast',
      'sonner',
      'spark-md5',
      'zod',
    ],
  },
  plugins: [tailwindcss(), reactRouter()],
  resolve: {
    tsconfigPaths: true,
  },
  server: {
    open: canOpenBrowser,
  },
});
