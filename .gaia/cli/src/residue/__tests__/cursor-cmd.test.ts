import {afterEach, describe, expect, test, vi} from 'vitest';
import {existsSync, mkdtempSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {readCursor} from '../cache.js';
import {run} from '../cursor-cmd.js';
import {encodeToken} from '../token.js';

describe('residue-cursor', () => {
  const dirs: string[] = [];

  const makeRoot = (): string => {
    const dir = mkdtempSync(path.join(tmpdir(), 'gaia-residue-cursor-cmd-'));

    dirs.push(dir);

    return dir;
  };

  afterEach(() => {
    vi.restoreAllMocks();

    for (const dir of dirs.splice(0))
      rmSync(dir, {force: true, recursive: true});
  });

  test('advance records the coordinate; clear removes it', () => {
    const root = makeRoot();
    const token = encodeToken({line: 42, path: 'app/x.ts', pr_number: 1234});

    expect(run(['advance', '--token', token], {cwd: root})).toBe(0);

    expect(readCursor(root)).toEqual({
      line: 42,
      path: 'app/x.ts',
      pr_number: 1234,
    });

    expect(run(['clear'], {cwd: root})).toBe(0);

    const cursorFile = path.join(
      root,
      '.gaia',
      'local',
      'cache',
      'residual-cursor.json'
    );

    expect(existsSync(cursorFile)).toBe(false);
  });

  test('advance with a malformed token is refused with a non-zero exit and writes no cursor file', () => {
    const root = makeRoot();

    const exitCode = run(['advance', '--token', 'not a token'], {cwd: root});

    expect(exitCode).not.toBe(0);
    expect(
      existsSync(
        path.join(root, '.gaia', 'local', 'cache', 'residual-cursor.json')
      )
    ).toBe(false);
  });

  test('advance with a well-formed token whose decoded path is a traversal is refused, and writes no cursor file', () => {
    const root = makeRoot();
    const forged = Buffer.from('9:../../etc/passwd:1', 'utf8')
      .toString('base64')
      .replaceAll('+', '-')
      .replaceAll('/', '_')
      .replaceAll('=', '');

    const exitCode = run(['advance', '--token', forged], {cwd: root});

    expect(exitCode).not.toBe(0);
    expect(
      existsSync(
        path.join(root, '.gaia', 'local', 'cache', 'residual-cursor.json')
      )
    ).toBe(false);
  });

  test('a valid token on the same call shape is accepted, proving the refusal above is a match rather than a blanket', () => {
    const root = makeRoot();
    const token = encodeToken({line: 1, path: 'app/ok.ts', pr_number: 1});

    expect(run(['advance', '--token', token], {cwd: root})).toBe(0);
    expect(
      existsSync(
        path.join(root, '.gaia', 'local', 'cache', 'residual-cursor.json')
      )
    ).toBe(true);
  });
});
