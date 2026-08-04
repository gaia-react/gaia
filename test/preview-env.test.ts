import {describe, expect, test} from 'vitest';

// Runs in the project default (happy-dom) environment, where `window.process`
// IS Node's `process` rather than the `{env: {}}` object
// `.storybook/preview-head.html` seeds in a real browser. `test/setup.ts` loads
// `.storybook/preview` as the global setup file, so every module that preview
// imports runs once per test file before any assertion here. A preview module
// that *assigns* to `window.process.env` therefore replaces the worker's real
// environment for the whole suite, silently dropping every variable it does not
// name. `PATH` is the witness: always present in a real environment, and never
// a key a preview shim has any reason to inline.

describe('storybook preview env', () => {
  test('the preview does not replace the worker process.env', () => {
    expect(window.process).toBe(process);
    expect(
      process.env.PATH,
      'PATH is absent, so something replaced process.env rather than adding to it'
    ).toBeTruthy();
  });
});
