import {describe, expect, test} from 'vitest';

// Runs in the project default (happy-dom) environment, where `window.process`
// IS Node's `process` rather than the `{env: {}}` object
// `.storybook/preview-head.html` seeds in a real browser. `test/setup.ts` loads
// `.storybook/preview` as the global setup file, so every module that preview
// imports runs once per test file before any assertion here. A preview module
// that *assigns* to `window.process.env` therefore replaces the worker's real
// environment for the whole suite, silently dropping every variable it does not
// name.

// The keys a preview env shim would install. The first five are what
// `.storybook/env.ts` assigned before it was deleted; the last two are added
// afterwards by `test/setup.ts`'s own `??=` defaults, so they survive a clobber
// and cannot witness one.
const CLOBBER_SURVIVING_KEYS = new Set([
  'API_URL',
  'COMMIT_SHA',
  'MSW_ENABLED',
  'NODE_ENV',
  'npm_package_version',
  'SESSION_SECRET',
  'SITE_URL',
]);

describe('storybook preview env', () => {
  test('the preview does not replace the worker process.env', () => {
    expect(window.process).toBe(process);
    expect(
      process.env.PATH,
      'PATH is absent, so something replaced process.env rather than adding to it'
    ).toBeTruthy();
  });

  test('variables outside a preview shim key set survive into the worker', () => {
    const surviving = Object.keys(process.env).filter(
      (key) => !CLOBBER_SURVIVING_KEYS.has(key)
    );

    expect(
      surviving.length,
      `process.env holds only [${Object.keys(process.env).join(', ')}], which is a preview shim's key set rather than the real environment`
    ).toBeGreaterThan(0);
  });
});
