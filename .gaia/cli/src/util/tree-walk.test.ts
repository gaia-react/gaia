import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {
  mkdirSync,
  mkdtempSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {
  collectTreeFiles,
  EVERY_EXTENSION,
  normalizeEntry,
  TS_SOURCE_EXTENSIONS,
} from './tree-walk.js';

const seed = (root: string, relative: string): void => {
  const abs = path.join(root, relative);
  mkdirSync(path.dirname(abs), {recursive: true});
  writeFileSync(abs, '', 'utf8');
};

// The separator is passed rather than read from `path.sep`, so these assert on
// input the walk cannot produce on any platform this repository runs on. That
// is the point: through `collectTreeFiles` alone the rewrite is the identity
// function here and deleting it would leave every test green.
describe('normalizeEntry', () => {
  test('rewrites a Windows separator to POSIX', () => {
    expect(normalizeEntry(String.raw`nested\deep\leaf.ts`, '\\')).toBe(
      'nested/deep/leaf.ts'
    );
  });

  test('leaves an entry that carries no separator alone', () => {
    expect(normalizeEntry('leaf.ts', '\\')).toBe('leaf.ts');
  });

  test('leaves an already-POSIX entry alone', () => {
    expect(normalizeEntry('nested/leaf.ts', '/')).toBe('nested/leaf.ts');
  });
});

describe('collectTreeFiles', () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(path.join(tmpdir(), 'gaia-collect-'));
  });

  afterEach(() => {
    rmSync(dir, {force: true, recursive: true});
  });

  test('keeps only the entries whose extension is in the set', () => {
    seed(dir, 'kept.ts');
    seed(dir, 'skipped.md');
    seed(dir, 'skipped');

    expect(collectTreeFiles(dir, TS_SOURCE_EXTENSIONS)).toEqual(['kept.ts']);
  });

  test('reaches nested entries and reports them relative to the root', () => {
    seed(dir, 'nested/deep/leaf.ts');

    expect(collectTreeFiles(dir, TS_SOURCE_EXTENSIONS)).toEqual([
      'nested/deep/leaf.ts',
    ]);
  });

  test('reports entries POSIX-separated', () => {
    seed(dir, path.join('nested', 'leaf.ts'));

    const [entry] = collectTreeFiles(dir, TS_SOURCE_EXTENSIONS);

    expect(entry).toBe('nested/leaf.ts');
  });

  test('sorts the entries', () => {
    seed(dir, 'b.ts');
    seed(dir, 'a.ts');
    seed(dir, 'nested/a.ts');

    expect(collectTreeFiles(dir, TS_SOURCE_EXTENSIONS)).toEqual([
      'a.ts',
      'b.ts',
      'nested/a.ts',
    ]);
  });

  test('matches the extension case-insensitively', () => {
    seed(dir, 'shouty.TS');

    expect(collectTreeFiles(dir, TS_SOURCE_EXTENSIONS)).toEqual(['shouty.TS']);
  });

  test('honors a caller-supplied extension set', () => {
    seed(dir, 'prose.md');
    seed(dir, 'code.ts');

    expect(collectTreeFiles(dir, new Set(['.md']))).toEqual(['prose.md']);
  });

  // An extensionless file and a dotfile are the entries an extension set can
  // never name, so they are what tells "every file" from "every extension
  // anyone listed".
  test('keeps every regular file when handed every extension', () => {
    seed(dir, 'code.ts');
    seed(dir, 'Makefile');
    seed(dir, '.gitignore');
    seed(dir, 'nested/prose.md');
    mkdirSync(path.join(dir, 'empty'));

    expect(collectTreeFiles(dir, EVERY_EXTENSION)).toEqual([
      '.gitignore',
      'code.ts',
      'Makefile',
      'nested/prose.md',
    ]);
  });

  // Reported, this would reach a caller's `readFileSync` and throw EISDIR.
  test('excludes a directory whose name carries a matching extension', () => {
    mkdirSync(path.join(dir, 'looks-like-a-file.ts'));
    seed(dir, 'real.ts');

    expect(collectTreeFiles(dir, TS_SOURCE_EXTENSIONS)).toEqual(['real.ts']);
  });

  test('excludes a symlink rather than following it', () => {
    seed(dir, 'real.ts');
    symlinkSync(path.join(dir, 'real.ts'), path.join(dir, 'link.ts'));

    expect(collectTreeFiles(dir, TS_SOURCE_EXTENSIONS)).toEqual(['real.ts']);
  });

  test('throws when the root does not exist', () => {
    expect(() =>
      collectTreeFiles(path.join(dir, 'absent'), TS_SOURCE_EXTENSIONS)
    ).toThrow(/ENOENT/);
  });
});
