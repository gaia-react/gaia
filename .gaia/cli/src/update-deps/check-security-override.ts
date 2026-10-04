/**
 * `gaia update-deps check-security-override --key <k> --value <v>
 * --package <name> --first-patched <version>` handler.
 *
 * A security-floor override lands in `pnpm-workspace.yaml`, and a manifest-only
 * dependency commit skips the frontend audit, so the entry must be exactly
 * `<name>` or `<parent>><name>` mapped to `>=<first patched version>`. Anything
 * else (an alias, a protocol, a URL, a compound range) is refused before it is
 * committed.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {isNpmPackageName, isSemverVersion} from './advisory-validate.js';

const HELP_TEXT = `Usage: gaia update-deps check-security-override --key <k> --value <v> --package <name> --first-patched <version>

  Validate a security-floor override entry before it is written. Exit 0 when
  <k> is exactly <name> or <parent>><name> and <v> is exactly
  >=<version>. Exit 1 otherwise, printing {"valid": false, "reason": "..."}.
  Exit 2 on a usage error.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const SUBCOMMAND = 'update-deps check-security-override';

/** The answer "not a valid override": distinct from a usage error. */
export const INVALID_OVERRIDE_EXIT = 1;

const FLAGS: readonly string[] = [
  '--key',
  '--value',
  '--package',
  '--first-patched',
];

type ParsedArgs = {
  firstPatched: string;
  key: string;
  packageName: string;
  value: string;
};

const parseArgs = (argv: readonly string[]): ParsedArgs | {error: string} => {
  const values = new Map<string, string>();

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === undefined || !FLAGS.includes(token)) {
      return {error: `unknown flag: ${String(token)}`};
    }

    const value = argv[index + 1];

    if (value === undefined || value.length === 0) {
      return {error: `${token} requires a value`};
    }

    values.set(token, value);
    index += 1;
  }

  for (const flag of FLAGS) {
    if (!values.has(flag)) return {error: `${flag} is required`};
  }

  return {
    firstPatched: values.get('--first-patched') ?? '',
    key: values.get('--key') ?? '',
    packageName: values.get('--package') ?? '',
    value: values.get('--value') ?? '',
  };
};

const keyProblem = (key: string, packageName: string): null | string => {
  const segments = key.split('>');

  if (segments.length > 2) return 'key has more than one parent level';

  if (segments.at(-1) !== packageName) {
    return 'key does not end in the advisory package';
  }

  if (segments.length === 2 && !isNpmPackageName(segments[0])) {
    return 'key parent is not an npm package name';
  }

  return null;
};

const problemWith = (args: ParsedArgs): null | string => {
  if (!isNpmPackageName(args.packageName)) {
    return 'package is not an npm package name';
  }

  if (!isSemverVersion(args.firstPatched)) {
    return 'first patched version is not valid semver';
  }

  const keyIssue = keyProblem(args.key, args.packageName);

  if (keyIssue !== null) return keyIssue;

  if (args.value !== `>=${args.firstPatched}`) {
    return 'value is not exactly >= the first patched version';
  }

  return null;
};

export const run = (argv: readonly string[]): number => {
  if (argv.some((token) => HELP_TOKENS.has(token))) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const args = parseArgs(argv);

  if ('error' in args) {
    structuredError({
      code: 'invalid_arguments',
      message: args.error,
      subcommand: SUBCOMMAND,
    });

    return EXIT_CODES.INVALID_ARGUMENTS;
  }

  const problem = problemWith(args);

  if (problem !== null) {
    process.stdout.write(
      `${JSON.stringify({reason: problem, valid: false})}\n`
    );

    return INVALID_OVERRIDE_EXIT;
  }

  process.stdout.write(`${JSON.stringify({valid: true})}\n`);

  return EXIT_CODES.OK;
};
