import axeCore from 'axe-core';
import type {AxeResults, RunOptions} from 'axe-core';
import {expect} from 'vitest';

/**
 * Runs axe-core against the given container and asserts no violations.
 * Uses the project-wide axe ruleset; pass `options` to scope or filter
 * (e.g. exclude rules, restrict tags).
 *
 * Test files calling this MUST opt into jsdom via:
 *   // @vitest-environment jsdom
 * placed as the first line of the file. happy-dom's Node.prototype.isConnected
 * (getter-only) breaks axe-core's polyfill (capricorn86/happy-dom#978).
 */

const assertJsdomEnvironment = (): void => {
  // jsdom sets navigator.userAgent to a Mozilla string containing "jsdom".
  // happy-dom does not. The user agent is the canonical signal across both.
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

  // axe.run treats a trailing undefined as callback mode; forward options
  // only when the caller supplied them so we always get a Promise back.
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
