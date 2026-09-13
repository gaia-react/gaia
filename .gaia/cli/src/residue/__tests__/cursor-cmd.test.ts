import {afterEach, describe, expect, test, vi} from 'vitest';
import {existsSync, mkdtempSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {run} from '../cursor-cmd.js';
import {encodeToken} from '../token.js';

const captureStdout = () => {
  const lines: string[] = [];
  const spy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      lines.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {lines, spy};
};

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

  test('show prints "null" when no cursor is recorded', () => {
    const root = makeRoot();
    const {lines} = captureStdout();

    const exitCode = run(['show'], {cwd: root});

    expect(exitCode).toBe(0);
    expect(lines.join('')).toBe('null\n');
  });

  test('advance then show round-trips the coordinate; clear removes it', () => {
    const root = makeRoot();
    const token = encodeToken({line: 42, path: 'app/x.ts', pr_number: 1234});

    expect(run(['advance', '--token', token], {cwd: root})).toBe(0);

    const {lines} = captureStdout();

    expect(run(['show'], {cwd: root})).toBe(0);
    expect(JSON.parse(lines.join(''))).toEqual({
      line: 42,
      path: 'app/x.ts',
      pr_number: 1234,
      token,
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
