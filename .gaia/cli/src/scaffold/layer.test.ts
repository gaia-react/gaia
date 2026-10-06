import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {mkdirSync, mkdtempSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {resolveLayer} from './layer.js';

describe('resolveLayer', () => {
  let packageDir: string;

  beforeEach(() => {
    packageDir = mkdtempSync(path.join(tmpdir(), 'gaia-layer-'));
  });

  afterEach(() => {
    rmSync(packageDir, {force: true, recursive: true});
  });

  const makeServiceFolders = (...names: string[]): void => {
    for (const name of names) {
      mkdirSync(path.join(packageDir, 'app', 'services', name), {
        recursive: true,
      });
    }
  };

  test('picks the single folder other than api', () => {
    makeServiceFolders('api', 'acme');

    expect(resolveLayer(packageDir, undefined)).toEqual({layer: 'acme'});
  });

  test('returns the requested folder when it exists', () => {
    makeServiceFolders('api', 'acme', 'billing');

    expect(resolveLayer(packageDir, 'billing')).toEqual({layer: 'billing'});
  });

  test('errors when the requested folder is missing', () => {
    makeServiceFolders('api', 'acme');

    expect(resolveLayer(packageDir, 'billing')).toEqual({
      error: '--layer folder not found: app/services/billing/',
    });
  });

  test('errors naming none when there is no candidate', () => {
    makeServiceFolders('api');

    expect(resolveLayer(packageDir, undefined)).toEqual({
      error:
        'cannot pick the domain-layer folder under app/services/ (found: none); pass --layer <folder>',
    });
  });

  test('errors naming none when app/services is missing', () => {
    expect(resolveLayer(packageDir, undefined)).toEqual({
      error:
        'cannot pick the domain-layer folder under app/services/ (found: none); pass --layer <folder>',
    });
  });

  test('errors naming every candidate when there are several', () => {
    makeServiceFolders('api', 'billing', 'acme');

    expect(resolveLayer(packageDir, undefined)).toEqual({
      error:
        'cannot pick the domain-layer folder under app/services/ (found: acme, billing); pass --layer <folder>',
    });
  });
});
