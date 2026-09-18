/**
 * `isMaterialRise` (`material-rise.ts`) is the only place the rise ratio's
 * constants may appear (AUDIT directive 12): every caller compares through
 * the function, never by re-deriving the ratio inline. This scans the harden
 * module tree for a stray reference to either constant, which would signal a
 * caller bypassing the shared function.
 */
import {describe, expect, test} from 'vitest';
import {readdirSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const HARDEN_DIR = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  '..'
);

const RATIO_IDENTIFIER = /\bRISE_RATIO_(NUM|DEN)\b/;

// Recursively lists every `.ts` file under `dir`, excluding any `__tests__`
// directory.
const listTsFiles = (dir: string): string[] => {
  const files: string[] = [];

  for (const entry of readdirSync(dir, {withFileTypes: true})) {
    if (entry.name === '__tests__') {
      // Excluded: fixtures and this scanner itself legitimately name the
      // identifiers under test.
    } else {
      const fullPath = path.join(dir, entry.name);

      if (entry.isDirectory()) {
        files.push(...listTsFiles(fullPath));
      } else if (entry.isFile() && entry.name.endsWith('.ts')) {
        files.push(fullPath);
      }
    }
  }

  return files;
};

describe('RISE_RATIO_NUM / RISE_RATIO_DEN stay single-sourced in material-rise.ts', () => {
  test('24: no other file under harden/ (excluding __tests__/) references either constant', () => {
    const offenders = listTsFiles(HARDEN_DIR)
      .filter((file) => path.basename(file) !== 'material-rise.ts')
      .filter((file) => RATIO_IDENTIFIER.test(readFileSync(file, 'utf8')));

    expect(offenders).toEqual([]);
  });

  test('25: refusal — the scanner reports a hit on an inline reimplementation', () => {
    const inlineReimplementation =
      'const r = liveCount * RISE_RATIO_DEN >= RISE_RATIO_NUM * baseCount;';

    expect(RATIO_IDENTIFIER.test(inlineReimplementation)).toBe(true);
  });
});
