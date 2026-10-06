import {describe, expect, test} from 'vitest';
// Runs in the node project.
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const WORKER_CONSTANT_NAMES = [
  'PACKAGE_VERSION',
  'INTEGRITY_CHECKSUM',
] as const;

type WorkerConstantName = (typeof WORKER_CONSTANT_NAMES)[number];

const REGENERATE_INSTRUCTION =
  'Regenerate it with `pnpm -C frontend msw:init`, or with `pnpm -C frontend exec msw init` if package.json has no msw:init script.';

const extractConstant = (
  source: string,
  name: WorkerConstantName
): string | undefined =>
  new RegExp(`const ${name} = ['"]([^'"]+)['"]`).exec(source)?.[1];

/**
 * Compares the committed worker script against the one the installed msw ships.
 * Returns one message per mismatch, empty when they agree.
 */
const compareWorkerScripts = (
  committedSource: string,
  installedSource: string,
  installedPackageVersion?: string
): string[] => {
  const mismatches: string[] = [];

  for (const name of WORKER_CONSTANT_NAMES) {
    const committed = extractConstant(committedSource, name);
    const installed = extractConstant(installedSource, name);

    if (committed === undefined || installed === undefined) {
      const missingFrom = [
        committed === undefined ? 'the committed worker script' : undefined,
        installed === undefined ? 'the installed worker script' : undefined,
      ]
        .filter(Boolean)
        .join(' and ');

      mismatches.push(`${name} was not found in ${missingFrom}.`);
    } else if (committed !== installed) {
      mismatches.push(
        `${name} differs: committed ${committed}, installed ${installed}. ${REGENERATE_INSTRUCTION}`
      );
    }
  }

  const committedVersion = extractConstant(committedSource, 'PACKAGE_VERSION');

  if (
    installedPackageVersion !== undefined &&
    committedVersion !== undefined &&
    committedVersion !== installedPackageVersion
  ) {
    mismatches.push(
      `The committed worker script is for msw ${committedVersion} but msw ${installedPackageVersion} is installed. ${REGENERATE_INSTRUCTION}`
    );
  }

  return mismatches;
};

const committedWorkerPath = path.resolve(
  import.meta.dirname,
  '../public/mockServiceWorker.js'
);
const installedWorkerPath = fileURLToPath(
  import.meta.resolve('msw/mockServiceWorker.js')
);
const installedPackagePath = fileURLToPath(
  import.meta.resolve('msw/package.json')
);

const committedSource = readFileSync(committedWorkerPath, 'utf-8');
const installedSource = readFileSync(installedWorkerPath, 'utf-8');
const installedPackageVersion = (
  JSON.parse(readFileSync(installedPackagePath, 'utf-8')) as {version: string}
).version;

const installedVersion = extractConstant(installedSource, 'PACKAGE_VERSION');
const installedChecksum = extractConstant(
  installedSource,
  'INTEGRITY_CHECKSUM'
);

describe('committed msw worker script', () => {
  test('matches the worker the installed msw ships', () => {
    expect(
      compareWorkerScripts(
        committedSource,
        installedSource,
        installedPackageVersion
      )
    ).toEqual([]);
  });

  test('reports an altered PACKAGE_VERSION with both versions and both commands', () => {
    const alteredSource = installedSource.replace(
      `const PACKAGE_VERSION = '${installedVersion}'`,
      "const PACKAGE_VERSION = '0.0.0-stale'"
    );

    const mismatches = compareWorkerScripts(
      alteredSource,
      installedSource,
      installedPackageVersion
    );

    expect(mismatches.length).toBeGreaterThan(0);
    expect(mismatches[0]).toContain('0.0.0-stale');
    expect(mismatches[0]).toContain(installedVersion);
    expect(mismatches[0]).toContain('pnpm -C frontend msw:init');
    expect(mismatches[0]).toContain('pnpm -C frontend exec msw init');
  });

  test('reports an altered INTEGRITY_CHECKSUM with both checksums and both commands', () => {
    const alteredSource = installedSource.replace(
      `const INTEGRITY_CHECKSUM = '${installedChecksum}'`,
      "const INTEGRITY_CHECKSUM = 'stale-checksum'"
    );

    const mismatches = compareWorkerScripts(
      alteredSource,
      installedSource,
      installedPackageVersion
    );

    expect(mismatches).toHaveLength(1);
    expect(mismatches[0]).toContain('stale-checksum');
    expect(mismatches[0]).toContain(installedChecksum);
    expect(mismatches[0]).toContain('pnpm -C frontend msw:init');
    expect(mismatches[0]).toContain('pnpm -C frontend exec msw init');
  });

  test('reports a committed script that lacks a constant', () => {
    const strippedSource = installedSource.replace(
      /const INTEGRITY_CHECKSUM = .*\n/,
      ''
    );

    const mismatches = compareWorkerScripts(
      strippedSource,
      installedSource,
      installedPackageVersion
    );

    expect(mismatches).toEqual([
      'INTEGRITY_CHECKSUM was not found in the committed worker script.',
    ]);
  });

  test('reports a committed version that differs from the installed msw version', () => {
    const mismatches = compareWorkerScripts(
      committedSource,
      committedSource,
      '999.0.0'
    );

    expect(mismatches).toHaveLength(1);
    expect(mismatches[0]).toContain('999.0.0');
    expect(mismatches[0]).toContain('pnpm -C frontend exec msw init');
  });
});
