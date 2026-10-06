import semver from 'semver';
import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {existsSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {
  dataLayerTemplatePath,
  hasTanstackQuery,
  TANSTACK_QUERY_PACKAGE,
  TANSTACK_QUERY_VERSION,
} from './data-layer.js';

const DATA_LAYER_TEMPLATES = [
  'query-client.ts.tmpl',
  'query-provider.tsx.tmpl',
  'QueryClientDecorator.tsx.tmpl',
];

describe('hasTanstackQuery', () => {
  let packageDir: string;

  beforeEach(() => {
    packageDir = mkdtempSync(path.join(tmpdir(), 'gaia-data-layer-'));
  });

  afterEach(() => {
    rmSync(packageDir, {force: true, recursive: true});
  });

  const writePackageJson = (contents: unknown): void => {
    writeFileSync(
      path.join(packageDir, 'package.json'),
      JSON.stringify(contents)
    );
  };

  test('is true when the package is a dependency', () => {
    writePackageJson({
      dependencies: {[TANSTACK_QUERY_PACKAGE]: TANSTACK_QUERY_VERSION},
    });

    expect(hasTanstackQuery(packageDir)).toBe(true);
  });

  test('is true when the package is a devDependency', () => {
    writePackageJson({
      devDependencies: {[TANSTACK_QUERY_PACKAGE]: TANSTACK_QUERY_VERSION},
    });

    expect(hasTanstackQuery(packageDir)).toBe(true);
  });

  test('is false when the package is absent', () => {
    writePackageJson({
      dependencies: {react: '19.0.0'},
      devDependencies: {'@tanstack/query-core': TANSTACK_QUERY_VERSION},
    });

    expect(hasTanstackQuery(packageDir)).toBe(false);
  });

  test('is false when package.json is missing', () => {
    expect(hasTanstackQuery(packageDir)).toBe(false);
  });
});

describe('dataLayerTemplatePath', () => {
  test.each(DATA_LAYER_TEMPLATES)('%s exists on disk', (fileName) => {
    const templatePath = dataLayerTemplatePath(fileName);

    expect(
      templatePath.endsWith(path.join('templates', 'data-layer', fileName))
    ).toBe(true);
    expect(existsSync(templatePath)).toBe(true);
  });
});

describe('TANSTACK_QUERY_VERSION', () => {
  test('is an exact version', () => {
    expect(TANSTACK_QUERY_VERSION).toMatch(/^\d+\.\d+\.\d+$/u);
  });

  test('is at least the first release with queryClient.query', () => {
    expect(semver.gte(TANSTACK_QUERY_VERSION, '5.104.0')).toBe(true);
  });
});
