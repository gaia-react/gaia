import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {mkdtempSync, realpathSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {selfLockfileDocument, twoDocumentLockfile} from './advisory-fixture.js';
import {NOT_LANDED_EXIT, run} from './advisory-landed.js';

const RANGE = '<1.2.0 || >=2.0.0 <2.1.0';

let root: string;
let outputs: string[];

beforeEach(() => {
  root = realpathSync(mkdtempSync(path.join(tmpdir(), 'gaia-landed-')));
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

const writeLockfile = (text: string): void => {
  writeFileSync(path.join(root, 'pnpm-lock.yaml'), text);
};

const report = (): unknown => JSON.parse(outputs.join('')) as unknown;

const check = (range = RANGE): number =>
  run(['--package', 'cookie', '--vulnerable-range', range], {cwd: root});

describe('advisory-landed', () => {
  test('a vulnerable copy in the project document is not landed; the decoy never counts', () => {
    writeLockfile(
      twoDocumentLockfile({
        decoys: ['cookie@2.1.0'],
        project: ['cookie@1.0.0', 'cookie@2.1.0'],
      })
    );

    expect(check()).toBe(NOT_LANDED_EXIT);
    expect(report()).toStrictEqual({
      installed: ['1.0.0', '2.1.0'],
      landed: false,
      vulnerable: ['1.0.0'],
    });
  });

  test('only patched copies in the project document is landed', () => {
    writeLockfile(
      twoDocumentLockfile({decoys: ['cookie@2.1.0'], project: ['cookie@2.1.0']})
    );

    expect(check()).toBe(EXIT_CODES.OK);
    expect(report()).toStrictEqual({
      installed: ['2.1.0'],
      landed: true,
      vulnerable: [],
    });
  });

  test('a package absent from the project document is landed, whatever the self-lockfile holds', () => {
    writeLockfile(
      twoDocumentLockfile({decoys: ['cookie@1.0.0'], project: ['other@1.0.0']})
    );

    expect(check()).toBe(EXIT_CODES.OK);
    expect(report()).toStrictEqual({
      installed: [],
      landed: true,
      vulnerable: [],
    });
  });

  test('a GitHub comma range is read as semver AND', () => {
    writeLockfile(twoDocumentLockfile({project: ['cookie@4.5.0']}));

    expect(check('>= 4.0.0, < 4.17.21')).toBe(NOT_LANDED_EXIT);
  });

  test('an invalid range exits INVALID_ARGUMENTS with landed false', () => {
    writeLockfile(twoDocumentLockfile({project: ['cookie@2.1.0']}));

    expect(check('>=1.0.0; rm')).toBe(EXIT_CODES.INVALID_ARGUMENTS);
    expect(report()).toMatchObject({landed: false});
  });

  test('a lockfile with no project document exits INVALID_ARGUMENTS with landed false', () => {
    writeLockfile(selfLockfileDocument(['cookie@2.1.0']));

    expect(check()).toBe(EXIT_CODES.INVALID_ARGUMENTS);
    expect(report()).toMatchObject({landed: false});
  });

  test('a missing lockfile exits INVALID_ARGUMENTS with landed false', () => {
    expect(check()).toBe(EXIT_CODES.INVALID_ARGUMENTS);
    expect(report()).toMatchObject({landed: false});
  });

  test('--help prints the verb usage and exits 0', () => {
    expect(run(['--help'])).toBe(EXIT_CODES.OK);
    expect(outputs.join('')).toContain('update-deps advisory-landed');
  });

  test.each([
    [
      'an unknown flag',
      ['--package', 'cookie', '--vulnerable-range', RANGE, '--bogus'],
    ],
    ['a missing --package', ['--vulnerable-range', RANGE]],
    [
      'an invalid package name',
      ['--package', 'evil pkg', '--vulnerable-range', RANGE],
    ],
  ])('%s exits INVALID_ARGUMENTS', (_label, argv) => {
    writeLockfile(twoDocumentLockfile({project: ['cookie@2.1.0']}));

    expect(run(argv, {cwd: root})).toBe(EXIT_CODES.INVALID_ARGUMENTS);
  });
});
