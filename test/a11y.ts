import axeCore from 'axe-core';
import type {AxeResults, RunOptions} from 'axe-core';
import {expect} from 'vitest';

// Callers must use `// @vitest-environment jsdom`; happy-dom breaks axe-core (capricorn86/happy-dom#978).

const assertJsdomEnvironment = (): void => {
  // jsdom includes "jsdom" in userAgent; happy-dom does not.
  if (!globalThis.navigator.userAgent.includes('jsdom')) {
    throw new Error(
      'expectNoA11yViolations requires the jsdom test environment. ' +
        'Add `// @vitest-environment jsdom` as the first line of this test file. ' +
        'happy-dom is incompatible with axe-core (capricorn86/happy-dom#978).'
    );
  }
};

/** Raw axe runner for tests that need to inspect the result manually. */
export const runAxe = async (
  container: Document | Element,
  options?: RunOptions
): Promise<AxeResults> => {
  assertJsdomEnvironment();

  // Omit options when undefined; axe.run treats trailing undefined as callback mode.
  return options === undefined ?
      axeCore.run(container)
    : axeCore.run(container, options);
};

export const expectNoA11yViolations = async (
  container: Document | Element,
  options?: RunOptions
): Promise<void> => {
  const results = await runAxe(container, options);
  expect(results.violations).toEqual([]);
};
