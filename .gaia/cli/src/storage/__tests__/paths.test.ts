/* eslint-disable sonarjs/publicly-writable-directories -- the *constant-string*
   test exercises path-construction logic with a `/tmp/fake-...` synthetic
   prefix; nothing is written. */
import {describe, expect, test} from 'vitest';
import {resolveStorageRoots} from '../paths.js';

describe('resolveStorageRoots', () => {
  test('produces the SPEC-mandated projectIdPath under repoRoot', () => {
    const repoRoot = '/tmp/fake-repo';
    const roots = resolveStorageRoots({repoRoot});

    expect(roots.projectIdPath).toBe('/tmp/fake-repo/.gaia/local/.project-id');
  });
});
