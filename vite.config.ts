import {reactRouter} from '@react-router/dev/vite';
import tailwindcss from '@tailwindcss/vite';
import {defineConfig} from 'vite';

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
      'remix-i18next/client',
      'remix-i18next/middleware',
      'remix-toast',
      'sonner',
      'spark-md5',
      'tailwind-merge',
      'zod',
    ],
  },
  plugins: [tailwindcss(), reactRouter()],
  resolve: {
    tsconfigPaths: true,
  },
  server: {
    open: true,
  },
});
