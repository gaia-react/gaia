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

  // Without the canvas package, jsdom's getContext returns null but first
  // reports "not implemented" through its own virtual console, which writes
  // straight to stderr, past vitest's onConsoleLog. The stub returns the same
  // null silently for the duration of the run, then puts the original back so
  // a canvas test later in the file is unaffected. With the canvas package
  // installed, the stub also hides the real context from axe, so
  // color-contrast skips there too.
  const {getContext} = HTMLCanvasElement.prototype;
  HTMLCanvasElement.prototype.getContext = () => null;

  try {
    // Omit options when undefined; axe.run treats trailing undefined as callback mode.
    return await (options === undefined ?
      axeCore.run(container)
    : axeCore.run(container, options));
  } finally {
    HTMLCanvasElement.prototype.getContext = getContext;
  }
};

// Passes on `violations` alone. Under jsdom, axe cannot evaluate some rules
// and records them in `incomplete` instead: color-contrast (no 2D canvas
// context) and landmark-one-main / page-has-heading-one (no
// document.elementFromPoint). color-contrast is covered by the Playwright
// scan in .playwright/a11y.ts; the other two are best-practice rules that
// scan's WCAG tag filter does not run.
export const expectNoA11yViolations = async (
  container: Document | Element,
  options?: RunOptions
): Promise<void> => {
  const results = await runAxe(container, options);
  expect(results.violations).toEqual([]);
};
