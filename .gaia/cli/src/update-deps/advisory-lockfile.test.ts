import {describe, expect, test} from 'vitest';
import {selfLockfileDocument, twoDocumentLockfile} from './advisory-fixture.js';
import {
  installedVersions,
  LockfileReadError,
  versionsFromKeys,
} from './advisory-lockfile.js';

describe('installedVersions', () => {
  test('reads only the project document of a two-document lockfile', () => {
    const lockfile = twoDocumentLockfile({
      decoys: ['cookie@9.9.9'],
      project: ['cookie@1.0.0', 'cookie@2.1.0', 'other@1.0.0'],
    });

    expect(installedVersions(lockfile, 'cookie')).toStrictEqual([
      '1.0.0',
      '2.1.0',
    ]);
  });

  test('a decoy in the self-lockfile never counts as installed', () => {
    const lockfile = twoDocumentLockfile({
      decoys: ['cookie@0.1.0'],
      project: ['other@1.0.0'],
    });

    expect(installedVersions(lockfile, 'cookie')).toStrictEqual([]);
  });

  test('a lockfile with no project document throws LockfileReadError', () => {
    expect(() =>
      installedVersions(selfLockfileDocument(['cookie@1.0.0']), 'cookie')
    ).toThrow(LockfileReadError);
  });

  test('text that is not YAML throws LockfileReadError', () => {
    expect(() => installedVersions('importers: [unclosed', 'cookie')).toThrow(
      LockfileReadError
    );
  });

  test('a single project document without a self-lockfile is read', () => {
    const lockfile = twoDocumentLockfile({project: ['cookie@0.6.0']}).slice(
      selfLockfileDocument().length + 1
    );

    expect(installedVersions(lockfile, 'cookie')).toStrictEqual(['0.6.0']);
  });
});

describe('versionsFromKeys', () => {
  test('strips the peer suffix and keeps scoped names whole', () => {
    expect(
      versionsFromKeys(
        [
          'cookie@0.6.0(react@19.0.0)',
          'cookie@0.6.0',
          '@scope/cookie@3.0.0',
          'cookie-parser@1.0.0',
        ],
        'cookie'
      )
    ).toStrictEqual(['0.6.0']);
    expect(
      versionsFromKeys(['@scope/cookie@3.0.0'], '@scope/cookie')
    ).toStrictEqual(['3.0.0']);
  });

  test('sorts versions by semver, not lexically', () => {
    expect(
      versionsFromKeys(['a@10.0.0', 'a@9.0.0', 'a@9.10.0'], 'a')
    ).toStrictEqual(['9.0.0', '9.10.0', '10.0.0']);
  });
});
