/**
 * `isMaterialRise` (`material-rise.ts`) is the only place the rise ratio's
 * constants may appear (AUDIT directive 12): every caller compares through
 * the function, never by re-deriving the ratio inline. This scans the harden
 * module tree for a stray reference to either constant, which would signal a
 * caller bypassing the shared function.
 */
import {describe, expect, test} from 'vitest';
import path from 'node:path';
import {
  CLI_SRC,
  testDeclaredOnce,
} from '../../util/uniqueness-guard-fixture.js';

const RATIO_IDENTIFIER = /\bRISE_RATIO_(NUM|DEN)\b/;

const findRatioIdentifier = (source: string): null | number => {
  const line = source
    .split('\n')
    .findIndex((text) => RATIO_IDENTIFIER.test(text));

  return line === -1 ? null : line + 1;
};

describe('RISE_RATIO_NUM / RISE_RATIO_DEN stay single-sourced in material-rise.ts', () => {
  testDeclaredOnce({
    corpusFloor: 12,
    corpusRoot: path.join(CLI_SRC, 'harden'),
    declaringModule: 'material-rise.ts',
    findOffense: findRatioIdentifier,
    // Fixtures and this scanner itself legitimately name the identifiers under
    // test, so a private copy planted there is not the drift this guard exists
    // to catch.
    isExempt: (relative) => relative.includes('__tests__'),
    offense: 'references RISE_RATIO_NUM or RISE_RATIO_DEN',
  });

  // No `skipIf`: this runs against an assembled string, so it holds on any
  // clone and it is what establishes that the detector can report at all.
  test('refusal: the scanner reports a hit on an inline reimplementation', () => {
    const inlineReimplementation =
      'const r = liveCount * RISE_RATIO_DEN >= RISE_RATIO_NUM * baseCount;';

    expect(findRatioIdentifier(inlineReimplementation)).toBe(1);
  });
});
