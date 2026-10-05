import {reactRouter} from '@react-router/dev/vite';
import tailwindcss from '@tailwindcss/vite';
import {defineConfig} from 'vite';
import {fileURLToPath} from 'node:url';
import {devPortsPlugin} from './dev-ports-vite-plugin.ts';
import {resolveDevPorts, resolveSiteUrl} from './dev-ports.ts';
import {reactCompiler} from './react-compiler.config.ts';

const packageDirectory = fileURLToPath(new URL('.', import.meta.url));

// The SSR app reads SITE_URL from process.env, and React Router's env loading
// lets an existing value win, so set it here, before any plugin loads env, to
// this tree's port-file value. A shell export is left alone.
const portResolution = resolveDevPorts(packageDirectory);

if (portResolution.kind === 'resolved') {
  const siteUrl = resolveSiteUrl({
    exportedSiteUrl: process.env.SITE_URL,
    ports: portResolution.ports,
  });

  if (siteUrl !== undefined) process.env.SITE_URL = siteUrl;
}

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
      'spark-md5',
      'zod',
    ],
  },
  plugins: [
    tailwindcss(),
    devPortsPlugin(packageDirectory),
    reactRouter(),
    reactCompiler,
  ],
  resolve: {
    tsconfigPaths: true,
  },
  server: {
    open: canOpenBrowser,
  },
});
