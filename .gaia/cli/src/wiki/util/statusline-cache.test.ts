import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {execFileSync} from 'node:child_process';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {invalidateStatuslineCache} from './statusline-cache.js';

describe('invalidateStatuslineCache', () => {
  let root: string;
  let cacheDirectory: string;
  let cachePath: string;

  beforeEach(() => {
    root = mkdtempSync(path.join(tmpdir(), 'gaia-statusline-cache-'));
    execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});
    execFileSync('git', ['config', 'user.email', 'test@example.com'], {
      cwd: root,
    });
    execFileSync('git', ['config', 'user.name', 'Test'], {cwd: root});
    execFileSync('git', ['config', 'commit.gpgsign', 'false'], {cwd: root});
    execFileSync('git', ['commit', '-q', '--allow-empty', '-m', 'initial'], {
      cwd: root,
    });
    cacheDirectory = path.join(root, '.gaia', 'local', 'cache', 'shared');
    cachePath = path.join(cacheDirectory, 'update-check.json');
  });

  afterEach(() => {
    rmSync(root, {force: true, recursive: true});
  });

  const seed = (contents: string): void => {
    mkdirSync(cacheDirectory, {recursive: true});
    writeFileSync(cachePath, contents, 'utf8');
  };

  test('sets checkedAt to 0 and preserves every other key', () => {
    seed(
      JSON.stringify({
        checkedAt: 1_700_000_000,
        latestVersion: '1.2.3',
        residueCandidateCount: 4,
        wikiDriftCount: 31,
      })
    );

    invalidateStatuslineCache(root);

    expect(JSON.parse(readFileSync(cachePath, 'utf8'))).toEqual({
      checkedAt: 0,
      latestVersion: '1.2.3',
      residueCandidateCount: 4,
      wikiDriftCount: 31,
    });
  });

  test('adds checkedAt 0 when the cache object has no checkedAt', () => {
    seed(JSON.stringify({wikiDriftCount: 2}));

    invalidateStatuslineCache(root);

    expect(JSON.parse(readFileSync(cachePath, 'utf8'))).toEqual({
      checkedAt: 0,
      wikiDriftCount: 2,
    });
  });

  test('leaves no temporary file behind', () => {
    seed(JSON.stringify({checkedAt: 5}));

    invalidateStatuslineCache(root);

    expect(readdirSync(cacheDirectory)).toEqual(['update-check.json']);
  });

  test('creates nothing when the cache file is absent', () => {
    invalidateStatuslineCache(root);

    expect(existsSync(path.join(root, '.gaia'))).toBe(false);
  });

  test.each([
    ['unparseable JSON', '{not json'],
    ['a JSON array', '[1, 2]'],
    ['a JSON scalar', '42'],
    ['JSON null', 'null'],
  ])('leaves the file untouched for %s', (_label, contents) => {
    seed(contents);

    expect(() => {
      invalidateStatuslineCache(root);
    }).not.toThrow();
    expect(readFileSync(cachePath, 'utf8')).toBe(contents);
  });

  test('does not throw outside a git repository', () => {
    const outside = mkdtempSync(path.join(tmpdir(), 'gaia-statusline-bare-'));

    try {
      expect(() => {
        invalidateStatuslineCache(outside);
      }).not.toThrow();
    } finally {
      rmSync(outside, {force: true, recursive: true});
    }
  });

  test('from a linked worktree, rewrites the main checkout cache', () => {
    seed(JSON.stringify({checkedAt: 99, wikiDriftCount: 8}));
    const linked = path.join(root, '.claude', 'worktrees', 'linked');
    execFileSync('git', ['worktree', 'add', '-q', '-b', 'linked', linked], {
      cwd: root,
    });

    invalidateStatuslineCache(linked);

    expect(JSON.parse(readFileSync(cachePath, 'utf8'))).toEqual({
      checkedAt: 0,
      wikiDriftCount: 8,
    });
    expect(existsSync(path.join(linked, '.gaia'))).toBe(false);
  });
});
