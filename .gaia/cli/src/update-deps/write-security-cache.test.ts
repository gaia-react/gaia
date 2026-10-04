import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {run} from './write-security-cache.js';

const NOW = new Date('2026-10-04T12:00:00Z');
const NOW_SECONDS = Math.floor(NOW.getTime() / 1000);

let root: string;
let cacheDirectory: string;
let cacheFile: string;
let lockDirectory: string;
let outputs: string[];

beforeEach(() => {
  root = realpathSync(mkdtempSync(path.join(tmpdir(), 'gaia-cache-')));
  cacheDirectory = path.join(root, '.gaia/local/cache/shared');
  cacheFile = path.join(cacheDirectory, 'update-check.json');
  lockDirectory = path.join(cacheDirectory, '.update-check.lock');
  mkdirSync(cacheDirectory, {recursive: true});
  outputs = [];
  vi.spyOn(process.stdout, 'write').mockImplementation((chunk: unknown) => {
    outputs.push(String(chunk));

    return true;
  });
  vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
});

afterEach(() => {
  vi.restoreAllMocks();
  rmSync(root, {force: true, recursive: true});
});

const fullCache = (): Record<string, unknown> => ({
  auditMemoryBaseline: {count: 3, hash: 'abc'},
  checkedAt: 1,
  gaiaCurrent: '1.6.1',
  hardenNudgeReason: 'recurring',
  outdatedCount: 4,
  securityCount: 2,
  securitySource: 'pnpm-audit',
  securityUnavailableReason: 'forbidden',
  serenaLangDrift: ['python'],
  unknownFutureKey: {nested: [1, 2]},
});

const writeCache = (value: Record<string, unknown>): string => {
  const text = `${JSON.stringify(value)}\n`;

  writeFileSync(cacheFile, text);

  return text;
};

const readCache = (): Record<string, unknown> =>
  JSON.parse(readFileSync(cacheFile, 'utf8')) as Record<string, unknown>;

const call = (argv: string[], lockWaitMs = 200): number =>
  run(argv, {
    cwd: root,
    lockWaitMs,
    now: () => NOW,
    resolveMainRoot: () => root,
  });

const result = (): Record<string, unknown> =>
  JSON.parse(outputs.join('')) as Record<string, unknown>;

describe('write-security-cache writes', () => {
  test('changes only the security fields and checkedAt', () => {
    const before = fullCache();

    writeCache(before);

    expect(call(['--count', '1', '--source', 'dependabot'])).toBe(
      EXIT_CODES.OK
    );
    expect(result()).toStrictEqual({written: true});
    expect(readCache()).toStrictEqual({
      ...before,
      checkedAt: NOW_SECONDS,
      securityCount: 1,
      securitySource: 'dependabot',
      securityUnavailableReason: '',
    });
  });

  test('records comma-joined reason tokens for the fallback source', () => {
    writeCache(fullCache());

    call([
      '--count',
      '0',
      '--source',
      'pnpm-audit',
      '--reason',
      'ci,forbidden',
    ]);

    expect(readCache().securityCount).toBe(0);
    expect(readCache().securityUnavailableReason).toBe('ci,forbidden');
  });

  test('no cache file is a no-op that creates nothing', () => {
    expect(call(['--count', '1', '--source', 'dependabot'])).toBe(
      EXIT_CODES.OK
    );
    expect(result()).toStrictEqual({reason: 'no-cache', written: false});
    expect(existsSync(cacheFile)).toBe(false);
    expect(existsSync(lockDirectory)).toBe(false);
  });

  test('a run that took the lock removes it afterwards', () => {
    writeCache(fullCache());
    call(['--count', '1', '--source', 'dependabot']);

    expect(existsSync(lockDirectory)).toBe(false);
  });
});

describe('write-security-cache refusals leave the cache byte-identical', () => {
  test.each([
    ['--source unavailable', ['--count', '1', '--source', 'unavailable']],
    ['--count -1', ['--count', '-1', '--source', 'dependabot']],
    ['--count 1.5', ['--count', '1.5', '--source', 'dependabot']],
    [
      '--count null with dependabot',
      ['--count', 'null', '--source', 'dependabot'],
    ],
    [
      '--count null with a reason',
      ['--count', 'null', '--source', 'pnpm-audit', '--reason', 'forbidden'],
    ],
    [
      '--reason not-a-token',
      ['--count', '1', '--source', 'dependabot', '--reason', 'not-a-token'],
    ],
    ['an unknown flag', ['--count', '1', '--source', 'dependabot', '--x', 'y']],
    ['a missing --count', ['--source', 'dependabot']],
  ])('%s exits 2', (_label, argv) => {
    const before = writeCache(fullCache());

    expect(call(argv)).toBe(EXIT_CODES.INVALID_ARGUMENTS);
    expect(readFileSync(cacheFile, 'utf8')).toBe(before);
  });

  test('an unparsable cache is refused and left byte-identical', () => {
    const garbage = '{"checkedAt": 1, oops';

    writeFileSync(cacheFile, garbage);

    expect(call(['--count', '1', '--source', 'dependabot'])).toBe(1);
    expect(result()).toStrictEqual({
      reason: 'unreadable-cache',
      written: false,
    });
    expect(readFileSync(cacheFile, 'utf8')).toBe(garbage);
    expect(existsSync(lockDirectory)).toBe(false);
  });

  test('a cache holding an array is unreadable, not overwritten', () => {
    writeFileSync(cacheFile, '[1,2]');

    expect(call(['--count', '1', '--source', 'dependabot'])).toBe(1);
    expect(readFileSync(cacheFile, 'utf8')).toBe('[1,2]');
  });
});

describe('write-security-cache lock', () => {
  test('a lock held by another pid yields lock-held, is never removed, and the write succeeds once it clears', () => {
    const before = writeCache(fullCache());

    mkdirSync(lockDirectory);
    writeFileSync(path.join(lockDirectory, 'owner'), `${process.ppid}\n`);

    expect(call(['--count', '1', '--source', 'dependabot'])).toBe(
      EXIT_CODES.OK
    );
    expect(result()).toStrictEqual({reason: 'lock-held', written: false});
    expect(readFileSync(cacheFile, 'utf8')).toBe(before);
    expect(readFileSync(path.join(lockDirectory, 'owner'), 'utf8').trim()).toBe(
      String(process.ppid)
    );

    rmSync(lockDirectory, {recursive: true});
    outputs.length = 0;

    expect(call(['--count', '1', '--source', 'dependabot'])).toBe(
      EXIT_CODES.OK
    );
    expect(result()).toStrictEqual({written: true});
  });
});

describe('write-security-cache help', () => {
  test('--help prints usage naming the verb and exits 0', () => {
    expect(call(['--help'])).toBe(EXIT_CODES.OK);
    expect(outputs.join('')).toContain(
      'Usage: gaia update-deps write-security-cache'
    );
  });
});
