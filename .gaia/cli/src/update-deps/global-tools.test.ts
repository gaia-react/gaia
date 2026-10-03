import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync} from 'node:child_process';
import {mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {writeFrontendRegistry} from '../util/package-fixture.js';
import {computePlaywrightCliRow, run} from './global-tools.js';
import type {GlobalToolProbes} from './global-tools.js';
import {run as runEmit} from './run.js';
import type {PnpmRunner} from './run.js';

const emptyOutdated: PnpmRunner = () => ({
  status: 0,
  stderr: '',
  stdout: '{}',
});

const INSTALL_COMMAND = 'npm install -g @playwright/cli@latest';

describe('computePlaywrightCliRow', () => {
  test('an older installed binary is outdated and offers the install', () => {
    const row = computePlaywrightCliRow({
      ci: false,
      installedVersion: '0.1.21',
      latestVersion: '0.1.22',
    });

    expect(row.status).toBe('outdated');
    expect(row.installed).toBe('0.1.21');
    expect(row.latest).toBe('0.1.22');
    expect(row.offerInstall).toBe(true);
    expect(row.reportOnly).toBe(false);
    expect(row.installCommand).toBe(INSTALL_COMMAND);
  });

  test('an absent binary is not-installed and never offers the install', () => {
    const row = computePlaywrightCliRow({
      ci: false,
      installedVersion: null,
      latestVersion: '0.1.22',
    });

    expect(row.status).toBe('not-installed');
    expect(row.message).toBe('not installed, skipped');
    expect(row.installCommand).toBe(INSTALL_COMMAND);
    expect(row.offerInstall).toBe(false);
  });

  test('CI reports an outdated binary and never offers the install', () => {
    const row = computePlaywrightCliRow({
      ci: true,
      installedVersion: '0.1.21',
      latestVersion: '0.1.22',
    });

    expect(row.status).toBe('outdated');
    expect(row.reportOnly).toBe(true);
    expect(row.offerInstall).toBe(false);
    expect(row.message).toContain('report-only in CI');
  });

  test('a failed npm lookup is unknown', () => {
    const row = computePlaywrightCliRow({
      ci: false,
      installedVersion: '0.1.21',
      latestVersion: null,
    });

    expect(row.status).toBe('unknown');
    expect(row.offerInstall).toBe(false);
    expect(row.message).toContain('npm lookup failed');
  });

  test('a non-semver installed string is unknown without throwing', () => {
    expect(() =>
      computePlaywrightCliRow({
        ci: false,
        installedVersion: 'not-a-version',
        latestVersion: '0.1.22',
      })
    ).not.toThrow();

    const row = computePlaywrightCliRow({
      ci: false,
      installedVersion: 'not-a-version',
      latestVersion: '0.1.22',
    });

    expect(row.status).toBe('unknown');
    expect(row.offerInstall).toBe(false);
  });

  test('an equal or newer installed binary is current', () => {
    for (const installedVersion of ['0.1.22', '0.2.0', '1.0.0']) {
      const row = computePlaywrightCliRow({
        ci: false,
        installedVersion,
        latestVersion: '0.1.22',
      });

      expect(row.status).toBe('current');
      expect(row.offerInstall).toBe(false);
    }
  });

  test('versions compare numerically, not lexically', () => {
    const row = computePlaywrightCliRow({
      ci: false,
      installedVersion: '0.1.9',
      latestVersion: '0.1.10',
    });

    expect(row.status).toBe('outdated');
  });
});

describe('update-deps global-tools handler', () => {
  let written: string[];

  beforeEach(() => {
    written = [];
    vi.spyOn(process.stdout, 'write').mockImplementation((chunk: unknown) => {
      written.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  const parseRows = (): {status: string}[] =>
    (JSON.parse(written.join('')) as {rows: {status: string}[]}).rows;

  test('prints rows and exits 0 when the binary probe reports it absent', () => {
    const probes: GlobalToolProbes = {
      isCi: () => false,
      probeInstalledVersion: () => null,
      probeLatestVersion: () => '0.1.22',
    };

    expect(run([], {probes})).toBe(0);
    expect(parseRows()).toHaveLength(1);
    expect(parseRows()[0]?.status).toBe('not-installed');
  });

  test('prints rows and exits 0 when the npm probe fails', () => {
    const probes: GlobalToolProbes = {
      isCi: () => false,
      probeInstalledVersion: () => '0.1.21',
      probeLatestVersion: () => null,
    };

    expect(run([], {probes})).toBe(0);
    expect(parseRows()[0]?.status).toBe('unknown');
  });
});

describe('update-deps run isolation from global tools', () => {
  let root: string;

  beforeEach(() => {
    root = mkdtempSync(path.join(tmpdir(), 'gaia-global-tools-'));
    writeFrontendRegistry(root);
    execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});
    writeFileSync(
      path.join(root, 'package.json'),
      JSON.stringify({dependencies: {foo: '^1.2.3'}}),
      'utf8'
    );
  });

  afterEach(() => {
    rmSync(root, {force: true, recursive: true});
    vi.restoreAllMocks();
  });

  test('--emit-updates payload never mentions playwright-cli', () => {
    const outPath = path.join(root, 'updates.json');

    expect(
      runEmit(['--emit-updates', outPath], {
        cwd: root,
        pnpmRunner: emptyOutdated,
      })
    ).toBe(0);

    const payload = readFileSync(outPath, 'utf8');

    expect(payload).not.toContain('playwright-cli');
    expect(payload).not.toContain('@playwright/cli');
  });

  test('run.ts does not import global-tools', () => {
    const source = readFileSync(
      path.join(import.meta.dirname, 'run.ts'),
      'utf8'
    );

    expect(source).not.toContain('global-tools');
  });
});
