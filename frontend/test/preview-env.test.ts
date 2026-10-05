import {describe, expect, test} from 'vitest';
import {readFileSync} from 'node:fs';
import path from 'node:path';

// Runs in the node project. A setup file that loads `.storybook/preview` there,
// or a DOM emulation (happy-dom, jsdom) configured on the project, once let a
// preview module that assigned to `window.process.env` replace the worker's
// real environment for the whole suite, silently dropping every variable it did
// not name. `PATH` is the witness: always present in a real environment, and
// never a key a preview shim has any reason to inline.

describe('node project environment', () => {
  test('the worker keeps its real process.env', () => {
    expect(
      process.env.PATH,
      'PATH is absent, so something replaced process.env rather than adding to it'
    ).toBeTruthy();
  });

  test('no DOM is emulated in the node project', () => {
    expect(
      globalThis.window,
      'window exists, so a DOM emulation was added to the node project; component and DOM tests belong in the browser or storybook project'
    ).toBeUndefined();
    expect(
      globalThis.document,
      'document exists, so a DOM emulation was added to the node project; component and DOM tests belong in the browser or storybook project'
    ).toBeUndefined();
  });

  test('the node setup file does not load the storybook preview', () => {
    const setupSource = readFileSync(
      path.resolve(import.meta.dirname, 'setup.ts'),
      'utf8'
    );

    expect(
      setupSource,
      'test/setup.ts imports from .storybook, which runs preview modules in every node test file and can replace process.env'
    ).not.toMatch(/\.storybook/);
  });
});
