import {afterEach, describe, expect, test} from 'vitest';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {
  clearCursor,
  emptyAttributionCache,
  readAttributionCache,
  readCursor,
  writeAttributionCache,
  writeCursor,
} from '../cache.js';

describe('attribution cache', () => {
  const dirs: string[] = [];

  const makeRoot = (): string => {
    const dir = mkdtempSync(path.join(tmpdir(), 'gaia-residue-cache-'));

    dirs.push(dir);

    return dir;
  };

  afterEach(() => {
    for (const dir of dirs.splice(0))
      rmSync(dir, {force: true, recursive: true});
  });

  test('a missing cache file reads as empty, no throw', () => {
    const root = makeRoot();

    expect(readAttributionCache(root)).toEqual(emptyAttributionCache());
  });

  test('a corrupt (truncated) cache file reads as empty, no throw', () => {
    const root = makeRoot();

    mkdirSync(path.join(root, '.gaia', 'local', 'cache'), {recursive: true});
    writeFileSync(
      path.join(root, '.gaia', 'local', 'cache', 'residual-attribution.json'),
      '{"schema":"v2","prs":{"1":',
      {flag: 'w'}
    );

    expect(() => readAttributionCache(root)).not.toThrow();
    expect(readAttributionCache(root)).toEqual(emptyAttributionCache());
  });

  // v2 attributions carry a failure_mode cut at the bullet's first line, so a
  // v2 cache must re-attribute rather than serve that text forever.
  test('a cache stamped v2 reads as empty', () => {
    const root = makeRoot();

    writeAttributionCache(root, {
      ...emptyAttributionCache(),
      high_water_merged_at: '2026-01-01T00:00:00Z',
    });

    const cachePath = path.join(
      root,
      '.gaia',
      'local',
      'cache',
      'residual-attribution.json'
    );

    writeFileSync(
      cachePath,
      readFileSync(cachePath, 'utf8').replace('"schema":"v3"', '"schema":"v2"')
    );

    expect(readAttributionCache(root)).toEqual(emptyAttributionCache());
  });

  test('writeAttributionCache then readAttributionCache round-trips', () => {
    const root = makeRoot();
    const cache = {
      ...emptyAttributionCache(),
      high_water_merged_at: '2026-01-01T00:00:00Z',
    };

    writeAttributionCache(root, cache);

    expect(readAttributionCache(root)).toEqual(cache);
  });

  test('an unwritten cache directory is created on write', () => {
    const root = makeRoot();

    writeAttributionCache(root, emptyAttributionCache());

    expect(
      existsSync(
        path.join(root, '.gaia', 'local', 'cache', 'residual-attribution.json')
      )
    ).toBe(true);
  });
});

describe('cursor', () => {
  const dirs: string[] = [];

  const makeRoot = (): string => {
    const dir = mkdtempSync(path.join(tmpdir(), 'gaia-residue-cursor-'));

    dirs.push(dir);

    return dir;
  };

  afterEach(() => {
    for (const dir of dirs.splice(0))
      rmSync(dir, {force: true, recursive: true});
  });

  test('a missing cursor file reads as null, no throw', () => {
    const root = makeRoot();

    expect(readCursor(root)).toBeNull();
  });

  test('writeCursor then readCursor round-trips; clear removes it', () => {
    const root = makeRoot();
    const cursor = {line: 42, path: 'app/x.ts', pr_number: 1234};

    writeCursor(root, cursor);
    expect(readCursor(root)).toEqual(cursor);

    clearCursor(root);
    expect(readCursor(root)).toBeNull();
  });

  test('clearing an already-absent cursor is a no-op, not a throw', () => {
    const root = makeRoot();

    expect(() => clearCursor(root)).not.toThrow();
  });
});
