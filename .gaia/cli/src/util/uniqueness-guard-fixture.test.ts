import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {CLI_SRC, scanCorpus} from './uniqueness-guard-fixture.js';

const DECLARING_MODULE = 'util/declared-once.ts';

// The detector belongs to the caller, so these fixtures drive the scan with the
// simplest one that can report at all: the first line carrying a marker word.
const findMarker = (source: string): null | number => {
  const line = source.split('\n').findIndex((text) => text.includes('MARKER'));

  return line === -1 ? null : line + 1;
};

const seed = (root: string, relative: string, body: string): void => {
  const absolute = path.join(root, relative);
  mkdirSync(path.dirname(absolute), {recursive: true});
  writeFileSync(absolute, body, 'utf8');
};

describe('scanCorpus', () => {
  let corpusRoot: string;

  const scan = () =>
    scanCorpus({
      corpusRoot,
      declaringModule: DECLARING_MODULE,
      findOffense: findMarker,
    });

  beforeEach(() => {
    corpusRoot = mkdtempSync(path.join(tmpdir(), 'gaia-uniqueness-'));
  });

  afterEach(() => {
    rmSync(corpusRoot, {force: true, recursive: true});
  });

  test('reports an offending file at its 1-based line', () => {
    seed(
      corpusRoot,
      'copy.ts',
      ['const a = 1;', 'const b = MARKER;'].join('\n')
    );

    const {offenses} = scan();

    expect(offenses).toHaveLength(1);
    expect(offenses[0]?.endsWith('copy.ts:2')).toBe(true);
    // A maintainer reading a red guard acts on the path it prints, so it has to
    // be repo-relative. The suffix above cannot see that: an absolute path ends
    // the same way, so dropping the relativization would leave it green.
    expect(path.isAbsolute(offenses[0] ?? '')).toBe(false);
  });

  // The exemption every scan carries, and the only one a caller cannot opt out
  // of. Without it the shared declaration is reported as a copy of itself,
  // which reads as the guard working.
  test('exempts the declaring module', () => {
    seed(corpusRoot, DECLARING_MODULE, 'const declared = MARKER;');

    expect(scan().offenses).toEqual([]);
  });

  test('exempts what the caller predicate spares, and nothing else', () => {
    seed(corpusRoot, 'spared.ts', 'const spared = MARKER;');
    seed(corpusRoot, 'copy.ts', 'const copied = MARKER;');

    const {offenses} = scanCorpus({
      corpusRoot,
      declaringModule: DECLARING_MODULE,
      findOffense: findMarker,
      isExempt: (relative) => relative === 'spared.ts',
    });

    expect(offenses).toHaveLength(1);
    expect(offenses[0]?.endsWith('copy.ts:1')).toBe(true);
  });

  test('reports nothing when no file carries the offense', () => {
    seed(corpusRoot, 'clean.ts', 'export const x = 1;');

    expect(scan().offenses).toEqual([]);
  });

  // The size is what a caller floors, so a broken walk or extension filter
  // cannot pass itself off as a clean corpus.
  test('reports the size of the corpus it actually scanned', () => {
    seed(corpusRoot, 'a.ts', '');
    seed(corpusRoot, 'nested/b.ts', '');
    seed(corpusRoot, 'skipped.md', 'MARKER');

    expect(scan().size).toBe(2);
  });
});

describe('CLI_SRC', () => {
  // Derived from this module's own location rather than handed in by its
  // caller, so it cannot drift onto a different root.
  test('resolves to the corpus the uniqueness guards scan', () => {
    expect(existsSync(path.join(CLI_SRC, 'util', 'tree-walk.ts'))).toBe(true);
  });
});
