import semver from 'semver';
/**
 * `gaia update-deps advisory-landed --package <name> --vulnerable-range <range>`
 * handler.
 *
 * /update-deps counts a security resolution only on exit 0 here: no installed
 * copy of the package, in the root lockfile's project document, satisfies the
 * advisory's vulnerable range. Exit 1 is not landed. Every failure to answer
 * (bad arguments, an invalid range, an unreadable lockfile) exits
 * INVALID_ARGUMENTS with `landed: false`, so a broken check never reads as a
 * resolution.
 */
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../util/repo-root.js';
import {installedVersions} from './advisory-lockfile.js';
import {
  isNpmPackageName,
  isRangeString,
  toSemverRange,
} from './advisory-validate.js';

const HELP_TEXT = `Usage: gaia update-deps advisory-landed --package <name> --vulnerable-range <range>

  Report whether a security resolution landed: no installed version of
  <name> in the root pnpm-lock.yaml (its project document) satisfies
  <range>. Prints {"landed", "installed", "vulnerable"} as JSON.

  Exit 0 landed, 1 not landed, 2 on a usage error, an invalid range, or an
  unreadable lockfile (then landed is false).
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const SUBCOMMAND = 'update-deps advisory-landed';

/** The answer "not landed": distinct from every failure, which exits 2. */
export const NOT_LANDED_EXIT = 1;

export type AdvisoryLandedOptions = {cwd?: string};

type LandedReport = {
  installed: string[];
  landed: boolean;
  vulnerable: string[];
};

const printReport = (report: LandedReport): void => {
  process.stdout.write(`${JSON.stringify(report)}\n`);
};

const refuse = (code: string, message: string): number => {
  structuredError({code, message, subcommand: SUBCOMMAND});
  printReport({installed: [], landed: false, vulnerable: []});

  return EXIT_CODES.INVALID_ARGUMENTS;
};

type ParsedArgs = {packageName: string; range: string};

const parseArgs = (argv: readonly string[]): ParsedArgs | {error: string} => {
  let packageName: string | undefined;
  let range: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token !== '--package' && token !== '--vulnerable-range') {
      return {error: `unknown flag: ${String(token)}`};
    }

    const value = argv[index + 1];

    if (value === undefined || value.length === 0) {
      return {error: `${token} requires a value`};
    }

    if (token === '--package') packageName = value;
    else range = value;
    index += 1;
  }

  if (packageName === undefined) return {error: '--package is required'};
  if (range === undefined) return {error: '--vulnerable-range is required'};

  return {packageName, range};
};

const readLockfile = (cwd: string): null | string => {
  let root: string;

  try {
    root = resolveRepoRoot(cwd);
  } catch {
    root = cwd;
  }

  try {
    return readFileSync(path.join(root, 'pnpm-lock.yaml'), 'utf8');
  } catch {
    return null;
  }
};

export const run = (
  argv: readonly string[],
  options: AdvisoryLandedOptions = {}
): number => {
  if (argv.some((token) => HELP_TOKENS.has(token))) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const args = parseArgs(argv);

  if ('error' in args) return refuse('invalid_arguments', args.error);

  if (!isNpmPackageName(args.packageName)) {
    return refuse('invalid_arguments', '--package is not an npm package name');
  }

  if (!isRangeString(args.range)) {
    return refuse('invalid_range', '--vulnerable-range is not a valid range');
  }

  const lockfileText = readLockfile(options.cwd ?? process.cwd());

  if (lockfileText === null) {
    return refuse('lockfile_unreadable', 'cannot read pnpm-lock.yaml');
  }

  let installed: string[];

  try {
    installed = installedVersions(lockfileText, args.packageName);
  } catch (error) {
    return refuse(
      'lockfile_unreadable',
      error instanceof Error ? error.message : String(error)
    );
  }

  const range = toSemverRange(args.range);
  // A version that is not valid semver (a tarball or git spec) cannot be
  // proven outside the range, so it counts as vulnerable: failing closed.
  const vulnerable = installed.filter(
    (version) =>
      semver.valid(version) === null ||
      semver.satisfies(version, range, {includePrerelease: true})
  );
  const landed = vulnerable.length === 0;

  printReport({installed, landed, vulnerable});

  return landed ? EXIT_CODES.OK : NOT_LANDED_EXIT;
};
