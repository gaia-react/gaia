/**
 * Strategy: drives the Node reader of the package registry
 * (`.gaia/scripts/lib/gaia-packages.mjs`) over the same corpus as the bash and
 * TypeScript readers, the way `classifier/classify-determinism.test.ts` drives
 * the classifier helper. The module is imported dynamically through a computed
 * URL because it lives outside this package's `rootDir`, so a static import
 * would fail the typecheck without making the test any stronger.
 *
 * Maintainer-only by construction: `.gaia/scripts` is the helper's home and
 * this test never ships to adopters.
 */
import {afterAll, beforeAll, describe, expect, test} from 'vitest';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {
  corpusDisagreements,
  listCorpusCases,
  materializeCase,
  readExpected,
} from './gaia-packages-corpus-fixture.js';
import type {CorpusReader} from './gaia-packages-corpus-fixture.js';
import {resolveRepoRootFromImportMeta} from './repo-root-fixture.js';

type NodeReader = {
  BUILTIN_DESCRIPTOR: unknown;
  BUILTIN_REGISTRY: unknown;
  globToRegExp: (glob: string) => RegExp;
  joinGlob: (packagePath: string, glob: string) => string;
  loadPackages: (repoRoot: string) => ReturnType<CorpusReader['load']>;
  packageForPath: CorpusReader['forPath'];
  repoRegExps: CorpusReader['regExps'];
};

const REPO_ROOT = resolveRepoRootFromImportMeta(import.meta.url);
const SCRATCH = mkdtempSync(path.join(tmpdir(), 'gaia-packages-mjs-'));
let reader: NodeReader;

beforeAll(async () => {
  const modulePath = path.join(
    REPO_ROOT,
    '.gaia/scripts/lib/gaia-packages.mjs'
  );
  reader = (await import(pathToFileURL(modulePath).href)) as NodeReader;
});

afterAll(() => {
  rmSync(SCRATCH, {force: true, recursive: true});
});

const asCorpusReader = (): CorpusReader => ({
  forPath: reader.packageForPath,
  load: reader.loadPackages,
  regExps: reader.repoRegExps,
});

const rootFor = (caseName: string): string => {
  const root = path.join(SCRATCH, caseName);
  materializeCase(caseName, root);

  return root;
};

describe('corpus conformance (Node reader)', () => {
  const cases = listCorpusCases();

  test('the corpus is not empty', () => {
    expect(cases.length).toBeGreaterThanOrEqual(35);
  });

  test.each(cases)('%s', (caseName) => {
    expect(
      corpusDisagreements(
        readExpected(caseName),
        rootFor(caseName),
        asCorpusReader()
      )
    ).toEqual([]);
  });

  test('the check fails on a wrong expectation (guard can fail)', () => {
    const root = rootFor('path-frontend');
    const expected = readExpected('path-frontend');

    expect(corpusDisagreements(expected, root, asCorpusReader())).toEqual([]);
    expect(
      corpusDisagreements({...expected, load: 2}, root, asCorpusReader())
    ).toEqual(['load: want 2, got 0']);
    expect(
      corpusDisagreements(
        {
          ...expected,
          globs: {tddUnitTests: {noMatch: ['frontend/app/x.test.ts']}},
        },
        root,
        asCorpusReader()
      )
    ).toEqual(['tddUnitTests: want NO match for [frontend/app/x.test.ts]']);
  });
});

describe('fail-closed results (Node reader)', () => {
  test('a malformed registry is REGISTRY_MALFORMED and never ok', () => {
    const result = reader.loadPackages(rootFor('registry-malformed-json'));

    expect(result.ok).toBe(false);
    expect(result).toMatchObject({code: 'REGISTRY_MALFORMED'});
    expect(!result.ok && result.message).toMatch(
      /^gaia-packages: .*\.gaia\/packages\.json is malformed.*Next step: /
    );
  });

  test('a missing descriptor is DESCRIPTOR_INVALID naming the descriptor path', () => {
    const result = reader.loadPackages(rootFor('descriptor-missing'));

    expect(result.ok).toBe(false);
    expect(result).toMatchObject({code: 'DESCRIPTOR_INVALID'});
    expect(!result.ok && result.message).toContain(
      'frontend/gaia.package.json is missing'
    );
  });

  test('a registry that is a directory is malformed, not the built-in default', () => {
    const root = path.join(SCRATCH, 'registry-is-directory');
    mkdirSync(path.join(root, '.gaia/packages.json'), {recursive: true});

    expect(reader.loadPackages(root)).toMatchObject({
      code: 'REGISTRY_MALFORMED',
      ok: false,
    });
  });

  test('a hostile registry path is malformed and runs nothing', () => {
    const root = path.join(SCRATCH, 'hostile');
    const marker = path.join(SCRATCH, 'pwned');
    mkdirSync(path.join(root, '.gaia'), {recursive: true});
    writeFileSync(
      path.join(root, '.gaia/packages.json'),
      JSON.stringify([{name: 'frontend', path: `frontend"; touch ${marker}`}])
    );

    expect(reader.loadPackages(root)).toMatchObject({
      code: 'REGISTRY_MALFORMED',
      ok: false,
    });
    expect(existsSync(marker)).toBe(false);
  });
});

describe('built-in default (Node reader)', () => {
  test('registry absent: source is builtin and frontend/app matches, root app does not', () => {
    const root = path.join(SCRATCH, 'absent');
    mkdirSync(root, {recursive: true});
    const result = reader.loadPackages(root);

    expect(result.ok && result.source).toBe('builtin');
    const patterns =
      result.ok ?
        reader.repoRegExps(result.packages as never[], 'tddUnitTests')
      : [];
    expect(patterns.some((p) => p.test('frontend/app/utils/x.test.ts'))).toBe(
      true
    );
    expect(patterns.some((p) => p.test('app/utils/x.test.ts'))).toBe(false);
  });

  test('the built-in registry is frontend at frontend', () => {
    expect(reader.BUILTIN_REGISTRY).toEqual([
      {name: 'frontend', path: 'frontend'},
    ]);
  });

  test('the built-in descriptor equals the committed descriptor located through the committed registry', () => {
    const registry = JSON.parse(
      readFileSync(path.join(REPO_ROOT, '.gaia/packages.json'), 'utf8')
    ) as {name: string; path: string}[];
    const entry = registry.find((candidate) => candidate.name === 'frontend');
    expect(entry).toBeDefined();
    const committed = JSON.parse(
      readFileSync(
        path.join(REPO_ROOT, entry?.path ?? '', 'gaia.package.json'),
        'utf8'
      )
    ) as unknown;

    expect(committed).toEqual(reader.BUILTIN_DESCRIPTOR);
  });

  test('joinGlob keeps a root-package glob and prefixes any other', () => {
    expect(reader.joinGlob('.', 'app/**')).toBe('app/**');
    expect(reader.joinGlob('apps/web', 'app/**')).toBe('apps/web/app/**');
  });
});
