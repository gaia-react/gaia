/**
 * `gaia update-deps global-tools` handler.
 *
 * Reports whether the globally installed playwright-cli binary trails npm
 * latest. Kept apart from `run.ts` on purpose: a global tool cannot be cleared
 * through pnpm, so it must never reach the `--emit-updates` payload that
 * `outdatedCount` and the statusline read.
 */
import {spawnSync} from 'node:child_process';
import {EXIT_CODES} from '../exit.js';
import {compareSegments, parseSegments} from './version.js';

const HELP_TEXT = `Usage: gaia update-deps global-tools

  Print {"rows":[...]} describing globally installed tools /update-deps keeps
  current (playwright-cli). Always exits 0, even when a probe fails.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const INSTALL_COMMAND = 'npm install -g @playwright/cli@latest';

export type GlobalToolProbes = {
  isCi: () => boolean;
  /** Returns the bare semver the binary prints, or `null` when it is absent. */
  probeInstalledVersion: () => null | string;
  /** Returns npm's latest version, or `null` when the lookup failed. */
  probeLatestVersion: () => null | string;
};

export type GlobalToolRow = {
  installCommand: typeof INSTALL_COMMAND;
  installed: null | string;
  latest: null | string;
  message: string;
  offerInstall: boolean;
  packageName: '@playwright/cli';
  reportOnly: boolean;
  status: GlobalToolStatus;
  tool: 'playwright-cli';
};

export type GlobalToolStatus =
  'current' | 'not-installed' | 'outdated' | 'unknown';

export type PlaywrightCliRowInput = {
  ci: boolean;
  /** `null` means the binary is absent. */
  installedVersion: null | string;
  /** `null` means the npm lookup failed. */
  latestVersion: null | string;
};

const STRICT_SEMVER_PATTERN = /^\d+\.\d+\.\d+$/;

const parseStrictSegments = (value: string): null | readonly number[] =>
  STRICT_SEMVER_PATTERN.test(value.trim()) ? parseSegments(value) : null;

export const computePlaywrightCliRow = (
  input: PlaywrightCliRowInput
): GlobalToolRow => {
  const {ci, installedVersion, latestVersion} = input;
  const row = (
    status: GlobalToolStatus,
    message: string,
    offerInstall = false
  ): GlobalToolRow => ({
    installCommand: INSTALL_COMMAND,
    installed: installedVersion,
    latest: latestVersion,
    message,
    offerInstall,
    packageName: '@playwright/cli',
    reportOnly: ci,
    status,
    tool: 'playwright-cli',
  });

  if (installedVersion === null) {
    return row('not-installed', 'not installed, skipped');
  }

  if (latestVersion === null) {
    return row('unknown', 'npm lookup failed, version comparison skipped');
  }

  const installed = parseStrictSegments(installedVersion);
  const latest = parseStrictSegments(latestVersion);

  if (installed === null || latest === null) {
    return row(
      'unknown',
      `cannot compare versions (installed ${installedVersion}, latest ${latestVersion})`
    );
  }

  if (compareSegments(installed, latest) < 0) {
    return row(
      'outdated',
      ci ?
        `installed ${installedVersion}, latest ${latestVersion}; report-only in CI`
      : `installed ${installedVersion}, latest ${latestVersion}`,
      !ci
    );
  }

  return row('current', `up to date at ${installedVersion}`);
};

// ENOENT surfaces as `error`, not as a non-zero status.
const probeCommand = (command: string, args: string[]): null | string => {
  const result = spawnSync(command, args, {encoding: 'utf8'});

  if (result.error !== undefined || result.status !== 0) return null;

  const output = result.stdout.trim();

  return output === '' ? null : output;
};

const defaultProbes: GlobalToolProbes = {
  isCi: () => process.env.CI === 'true',
  probeInstalledVersion: () => probeCommand('playwright-cli', ['--version']),
  probeLatestVersion: () =>
    probeCommand('npm', ['view', '@playwright/cli', 'version']),
};

export type RunOptions = {
  probes?: GlobalToolProbes;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  if (argv.some((token) => HELP_TOKENS.has(token))) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const probes = options.probes ?? defaultProbes;
  const row = computePlaywrightCliRow({
    ci: probes.isCi(),
    installedVersion: probes.probeInstalledVersion(),
    latestVersion: probes.probeLatestVersion(),
  });

  process.stdout.write(`${JSON.stringify({rows: [row]})}\n`);

  return EXIT_CODES.OK;
};
