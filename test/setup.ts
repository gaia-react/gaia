import type {Preview} from '@storybook/react-vite';
import {setProjectAnnotations} from '@storybook/react-vite';
import * as globalStorybookConfig from '../.storybook/preview';
import '@testing-library/jest-dom/vitest';
import './test.server';

// Fallback values for required server env vars: env.server.ts parses
// process.env at import time; tests that import it transitively fail
// in clean environments (no .env) without these defaults.
process.env.API_URL ??= 'http://localhost:3001';
process.env.SESSION_SECRET ??= 'test-secret';
process.env.SITE_URL ??= 'http://localhost:3000';

setProjectAnnotations(globalStorybookConfig as Preview);
