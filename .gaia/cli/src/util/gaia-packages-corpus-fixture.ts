/**
 * The shared driver for the package-registry conformance corpus under
 * `.gaia/tests/fixtures/gaia-packages/`.
 *
 * The corpus is the oracle for three implementations of one contract: the bash
 * reader (driven by `.gaia/tests/hooks/gaia-packages-lib.bats`), the Node
 * reader (`gaia-packages-mjs.test.ts`) and the TypeScript reader
 * (`packages.test.ts`). The two vitest suites share this one driver so the
 * comparison logic cannot drift between them: a suite that compared more
 * loosely than its sibling would green over a disagreement the corpus exists to
 * catch. Each case directory holds an optional `packages.json` (installed as
 * `.gaia/packages.json`), descriptor files at their package paths, and
 * `expected.json`.
 */
import {
  cpSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
} from 'node:fs';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from './repo-root-fixture.js';

export type CorpusExpected = {
  dir?: Record<string, null | string>;
  error?: string;
  forPath?: Record<string, string>;
  globs?: Record<
    string,
    {empty?: boolean; match?: string[]; noMatch?: string[]}
  >;
  list?: [string, string][];
  load: number;
  source?: string;
};

/** The slice of a reader the driver needs, so both vitest suites adapt to it. */
export type CorpusReader = {
  forPath: (
    packages: never[],
    repoRelativePath: string
  ) => null | ReaderPackage;
  load: (
    repoRoot: string
  ) =>
    | {code: string; message: string; ok: false}
    | {ok: true; packages: ReaderPackage[]; source: string};
  regExps: (packages: never[], key: string) => RegExp[];
};

type ReaderPackage = {name: string; path: string};

const LOAD_STATUS_BY_CODE: Record<string, number> = {
  DESCRIPTOR_INVALID: 3,
  REGISTRY_MALFORMED: 2,
};

export const CORPUS_DIRECTORY = path.join(
  resolveRepoRootFromImportMeta(import.meta.url),
  '.gaia/tests/fixtures/gaia-packages'
);

export const listCorpusCases = (): string[] =>
  readdirSync(CORPUS_DIRECTORY, {withFileTypes: true})
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .toSorted((a, b) => a.localeCompare(b));

export const readExpected = (caseName: string): CorpusExpected =>
  JSON.parse(
    readFileSync(path.join(CORPUS_DIRECTORY, caseName, 'expected.json'), 'utf8')
  ) as CorpusExpected;

/** Copy a case into `destination` as a repo root, without its oracle. */
export const materializeCase = (
  caseName: string,
  destination: string
): void => {
  rmSync(destination, {force: true, recursive: true});
  mkdirSync(path.join(destination, '.gaia'), {recursive: true});
  cpSync(path.join(CORPUS_DIRECTORY, caseName), destination, {recursive: true});
  rmSync(path.join(destination, 'expected.json'), {force: true});

  if (readdirSync(destination).includes('packages.json')) {
    renameSync(
      path.join(destination, 'packages.json'),
      path.join(destination, '.gaia/packages.json')
    );
  }
};

type Loaded = {packages: ReaderPackage[]; source: string};

const globDisagreements = (
  expected: CorpusExpected,
  loaded: Loaded,
  reader: CorpusReader
): string[] =>
  Object.entries(expected.globs ?? {}).flatMap(([key, queries]) => {
    const patterns = reader.regExps(loaded.packages as never[], key);
    const hits = (candidate: string): boolean =>
      patterns.some((pattern) => pattern.test(candidate));

    if (queries.empty === true) {
      return patterns.length > 0 ?
          [`${key}: want no patterns, got ${String(patterns.length)}`]
        : [];
    }

    return [
      ...(queries.match ?? [])
        .filter((candidate) => !hits(candidate))
        .map((candidate) => `${key}: want match for [${candidate}]`),
      ...(queries.noMatch ?? [])
        .filter((candidate) => hits(candidate))
        .map((candidate) => `${key}: want NO match for [${candidate}]`),
    ];
  });

const ownershipDisagreements = (
  expected: CorpusExpected,
  loaded: Loaded,
  reader: CorpusReader
): string[] => {
  const owners = Object.entries(expected.forPath ?? {}).flatMap(
    ([candidate, owner]) => {
      const got =
        reader.forPath(loaded.packages as never[], candidate)?.name ?? '';

      return got === owner ?
          []
        : [`for_path [${candidate}]: want [${owner}], got [${got}]`];
    }
  );
  const directories = Object.entries(expected.dir ?? {}).flatMap(
    ([name, directory]) => {
      const got = loaded.packages.find((p) => p.name === name)?.path ?? null;

      return got === directory ?
          []
        : [`dir [${name}]: want [${String(directory)}], got [${String(got)}]`];
    }
  );

  return [...owners, ...directories];
};

/** One line per way the reader disagrees with the oracle; empty when it agrees. */
export const corpusDisagreements = (
  expected: CorpusExpected,
  repoRoot: string,
  reader: CorpusReader
): string[] => {
  const result = reader.load(repoRoot);
  const status = result.ok ? 0 : (LOAD_STATUS_BY_CODE[result.code] ?? -1);

  if (status !== expected.load) {
    return [`load: want ${String(expected.load)}, got ${String(status)}`];
  }

  if (!result.ok) {
    return result.message === expected.error ?
        []
      : [
          `error text: want [${String(expected.error)}], got [${result.message}]`,
        ];
  }
  const list = JSON.stringify(result.packages.map((p) => [p.name, p.path]));

  return [
    ...(result.source === expected.source ?
      []
    : [`source: got ${result.source}`]),
    ...(list === JSON.stringify(expected.list) ? [] : [`list: got ${list}`]),
    ...globDisagreements(expected, result, reader),
    ...ownershipDisagreements(expected, result, reader),
  ];
};
