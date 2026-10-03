import type {Preview} from '@storybook/react-vite';
import {setProjectAnnotations} from '@storybook/react-vite';
import path from 'node:path';
import * as globalStorybookConfig from '../.storybook/preview';
import '@testing-library/jest-dom/vitest';
// eslint-disable-next-line no-restricted-imports -- this is the global Vitest setupFile (vitest.config.ts setupFiles); the single sanctioned place to start the MSW server harness for the whole suite, not a consumer test reaching into server surface
import './test.server';

// `@react-router/fs-routes` resolves route files through `getAppDirectory()`
// from `@react-router/dev/routes`, which reads this global. The React Router
// Vite plugin and typegen set it; Vitest loads neither, so the suite sets it
// to the real app directory and tests keep resolving the real route config.
// eslint-disable-next-line no-underscore-dangle -- React Router's app-directory global, read by getAppDirectory()
(
  globalThis as {__reactRouterAppDirectory?: string}
).__reactRouterAppDirectory ??= path.resolve(import.meta.dirname, '../app');

// Fallback values for required server env vars: env.server.ts parses
// process.env at import time; tests that import it transitively fail
// in clean environments (no .env) without these defaults. npm_package_version
// needs one too: pnpm sets it only for processes it launches from a
// package.json script, so `pnpm exec vitest` and editor integrations, which
// spawn the binary directly, have none.
process.env.API_URL ??= 'http://localhost:3001';
process.env.npm_package_version ??= '0.0.0';
process.env.SESSION_SECRET ??= 'test-secret';
process.env.SITE_URL ??= 'http://localhost:3000';

setProjectAnnotations(globalStorybookConfig as Preview);
