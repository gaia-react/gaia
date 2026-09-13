import {afterEach, describe, expect, test} from 'vitest';
import {mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {run} from '../record-cmd.js';
import {encodeToken} from '../token.js';

const storeFile = (root: string): string =>
  path.join(root, '.gaia', 'audit-residual-dismissals.jsonl');

const readStoreLines = (root: string): string[] => {
  try {
    return readFileSync(storeFile(root), 'utf8').split('\n').filter(Boolean);
  } catch {
    return [];
  }
};

const writeReasonFile = (root: string, text: string): string => {
  const file = path.join(root, 'reason.txt');

  writeFileSync(file, text);

  return file;
};

describe('residue-record', () => {
  const dirs: string[] = [];

  const makeRoot = (): string => {
    const dir = mkdtempSync(path.join(tmpdir(), 'gaia-residue-record-'));

    dirs.push(dir);

    return dir;
  };

  afterEach(() => {
    for (const dir of dirs.splice(0))
      rmSync(dir, {force: true, recursive: true});
  });

  test('appends exactly one record carrying the nine contracted fields, with class/source_pr/cited_line_text derived rather than supplied', () => {
    const root = makeRoot();
    const token = encodeToken({line: 10, path: 'app/x.ts', pr_number: 5});
    const reasonFile = writeReasonFile(root, 'not worth fixing\n');

    const exitCode = run(
      [
        '--disposition',
        'dismissed',
        '--token',
        token,
        '--reason-file',
        reasonFile,
      ],
      {cwd: root, now: () => new Date('2026-01-01T00:00:00Z')}
    );

    expect(exitCode).toBe(0);

    const lines = readStoreLines(root);

    expect(lines).toHaveLength(1);

    const record = JSON.parse(lines[0] ?? '{}');

    expect(Object.keys(record).toSorted((a, b) => a.localeCompare(b))).toEqual([
      'cited_line_text',
      'class',
      'date',
      'disposition',
      'line',
      'path',
      'reason',
      'schema',
      'source_pr',
    ]);
    expect(record).toMatchObject({
      cited_line_text: '',
      class: '',
      disposition: 'dismissed',
      line: 10,
      path: 'app/x.ts',
      reason: 'not worth fixing',
      schema: 'v1',
      source_pr: 5,
    });
  });

  test('two --token flags in one call append two records in one write', () => {
    const root = makeRoot();
    const tokenA = encodeToken({line: 1, path: 'app/a.ts', pr_number: 1});
    const tokenB = encodeToken({line: 2, path: 'app/b.ts', pr_number: 1});
    const reasonFile = writeReasonFile(root, 'batch reason');

    const exitCode = run(
      [
        '--disposition',
        'kept',
        '--token',
        tokenA,
        '--token',
        tokenB,
        '--reason-file',
        reasonFile,
      ],
      {cwd: root}
    );

    expect(exitCode).toBe(0);
    expect(readStoreLines(root)).toHaveLength(2);
  });

  test('a reason file with an embedded newline is refused, non-zero exit, store byte-unchanged; a one-line reason on the same shape is accepted', () => {
    const root = makeRoot();
    const token = encodeToken({line: 1, path: 'app/a.ts', pr_number: 1});
    const multilineReasonFile = writeReasonFile(root, 'line one\nline two');

    const refused = run(
      [
        '--disposition',
        'kept',
        '--token',
        token,
        '--reason-file',
        multilineReasonFile,
      ],
      {cwd: root}
    );

    expect(refused).not.toBe(0);
    expect(readStoreLines(root)).toHaveLength(0);

    const oneLineReasonFile = writeReasonFile(root, 'a single line reason\n');
    const accepted = run(
      [
        '--disposition',
        'kept',
        '--token',
        token,
        '--reason-file',
        oneLineReasonFile,
      ],
      {cwd: root}
    );

    expect(accepted).toBe(0);
    expect(readStoreLines(root)).toHaveLength(1);
  });

  test('a malformed token exits non-zero and writes nothing', () => {
    const root = makeRoot();
    const reasonFile = writeReasonFile(root, 'reason');

    const exitCode = run(
      [
        '--disposition',
        'kept',
        '--token',
        'not a token',
        '--reason-file',
        reasonFile,
      ],
      {cwd: root}
    );

    expect(exitCode).not.toBe(0);
    expect(readStoreLines(root)).toHaveLength(0);
  });

  test('an absent --reason-file exits non-zero and writes nothing', () => {
    const root = makeRoot();
    const token = encodeToken({line: 1, path: 'app/a.ts', pr_number: 1});

    const exitCode = run(['--disposition', 'kept', '--token', token], {
      cwd: root,
    });

    expect(exitCode).not.toBe(0);
    expect(readStoreLines(root)).toHaveLength(0);
  });

  test('an unreadable reason file exits non-zero and writes nothing', () => {
    const root = makeRoot();
    const token = encodeToken({line: 1, path: 'app/a.ts', pr_number: 1});

    const exitCode = run(
      [
        '--disposition',
        'kept',
        '--token',
        token,
        '--reason-file',
        path.join(root, 'does-not-exist.txt'),
      ],
      {cwd: root}
    );

    expect(exitCode).not.toBe(0);
    expect(readStoreLines(root)).toHaveLength(0);
  });
});
