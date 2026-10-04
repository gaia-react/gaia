/**
 * `gaia update-deps dismiss-alert --alert <n> --reason <reason> --comment
 * <text> --confirmed` handler.
 *
 * Dismissing a Dependabot alert is ask-first and never runs in CI. Every
 * argument is validated before any spawn, `gh` is argv-spawned (never through a
 * shell), and gh's stderr is never echoed because it can carry a token.
 */
import {EXIT_CODES} from '../exit.js';
import {runGh} from '../setup-ci/util/gh.js';
import type {GhOptions, GhResult} from '../setup-ci/util/gh.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../util/repo-root.js';
import {
  ADVISORY_SPAWN_TIMEOUT_MS,
  resolveGithubRepository,
} from './advisory-sources.js';
import type {OriginReader} from './advisory-sources.js';
import {isPositiveInteger} from './advisory-validate.js';

const HELP_TEXT = `Usage: gaia update-deps dismiss-alert --alert <n> --reason <tolerable_risk|not_used> --comment <text> --confirmed

  Dismiss one Dependabot alert on GitHub. Refused (no request sent) in CI,
  without --confirmed, for an invalid argument, or without a github.com
  origin. The comment is 1 to 280 characters and is never truncated.
  Prints {"dismissed": true|false, ...} as JSON. Exit 0 dismissed, 1 refused
  or failed, 2 on a usage error.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const SUBCOMMAND = 'update-deps dismiss-alert';

const MAX_COMMENT_LENGTH = 280;
const REASONS = new Set(['not_used', 'tolerable_risk']);
const ALERT_PATTERN = /^[1-9]\d*$/u;
const FORBIDDEN_PATTERN = /\bHTTP 403\b/u;

export type DismissAlertOptions = {
  cwd?: string;
  env?: NodeJS.ProcessEnv;
  ghRunner?: (options: GhOptions) => Promise<GhResult>;
  originReader?: OriginReader;
};

type DismissError =
  | 'forbidden'
  | 'invalid-arguments'
  | 'no-remote'
  | 'non-github-remote'
  | 'not-confirmed'
  | 'refused-ci'
  | 'request-failed';

type ParsedArgs = {
  alert: number;
  comment: string;
  confirmed: boolean;
  reason: string;
};

const printResult = (result: Record<string, unknown>): void => {
  process.stdout.write(`${JSON.stringify(result)}\n`);
};

const fail = (
  error: DismissError,
  alert: null | number,
  exitCode: number = EXIT_CODES.UNKNOWN_SUBCOMMAND
): number => {
  printResult({alert, dismissed: false, error});

  return exitCode;
};

const isCiEnvironment = (env: NodeJS.ProcessEnv): boolean =>
  [env.CI, env.GITHUB_ACTIONS].some(
    (value) => value !== undefined && value !== '' && value !== 'false'
  );

// Counts code points, not UTF-16 units, so an emoji is one character.
const countCodePoints = (text: string): number => {
  let count = 0;
  let index = 0;

  while (index < text.length) {
    // A code point above U+FFFF occupies two UTF-16 units.
    index += (text.codePointAt(index) ?? 0) > 0xff_ff ? 2 : 1;
    count += 1;
  }

  return count;
};

type RawFlags = {
  alert?: string;
  comment?: string;
  confirmed: boolean;
  reason?: string;
};

const readFlags = (argv: readonly string[]): RawFlags | {error: string} => {
  const flags: RawFlags = {confirmed: false};

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--confirmed') {
      flags.confirmed = true;
    } else if (
      token === '--alert' ||
      token === '--reason' ||
      token === '--comment'
    ) {
      const value = argv[index + 1];

      if (value === undefined) return {error: `${token} requires a value`};

      if (token === '--alert') flags.alert = value;
      else if (token === '--reason') flags.reason = value;
      else flags.comment = value;
      index += 1;
    } else {
      return {error: `unknown flag: ${String(token)}`};
    }
  }

  return flags;
};

const parseArgs = (argv: readonly string[]): ParsedArgs | {error: string} => {
  const flags = readFlags(argv);

  if ('error' in flags) return flags;

  const {alert, comment, confirmed, reason} = flags;

  if (alert === undefined || !ALERT_PATTERN.test(alert)) {
    return {error: '--alert must be a positive integer'};
  }

  const alertNumber = Number(alert);

  if (!isPositiveInteger(alertNumber)) {
    return {error: '--alert must be a positive integer'};
  }

  if (reason === undefined || !REASONS.has(reason)) {
    return {error: '--reason must be tolerable_risk or not_used'};
  }

  if (comment === undefined || comment.length === 0) {
    return {error: '--comment is required'};
  }

  if (countCodePoints(comment) > MAX_COMMENT_LENGTH) {
    return {error: `--comment is longer than ${MAX_COMMENT_LENGTH} characters`};
  }

  return {alert: alertNumber, comment, confirmed, reason};
};

const resolveWorkingRoot = (cwd: string): string => {
  try {
    return resolveRepoRoot(cwd);
  } catch {
    return cwd;
  }
};

export const run = async (
  argv: readonly string[],
  options: DismissAlertOptions = {}
): Promise<number> => {
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

    return fail('invalid-arguments', null, EXIT_CODES.INVALID_ARGUMENTS);
  }

  if (isCiEnvironment(options.env ?? process.env)) {
    return fail('refused-ci', args.alert);
  }

  if (!args.confirmed) return fail('not-confirmed', args.alert);

  const cwd = resolveWorkingRoot(options.cwd ?? process.cwd());
  const repository = resolveGithubRepository(cwd, options.originReader);

  if (!repository.ok) return fail(repository.reason, args.alert);

  const result = await (options.ghRunner ?? runGh)({
    args: [
      'api',
      '-X',
      'PATCH',
      `repos/${repository.owner}/${repository.repo}/dependabot/alerts/${args.alert}`,
      '-f',
      'state=dismissed',
      '-f',
      `dismissed_reason=${args.reason}`,
      '-f',
      `dismissed_comment=${args.comment}`,
    ],
    cwd,
    timeoutMs: ADVISORY_SPAWN_TIMEOUT_MS,
  });

  if (!result.ok) {
    const forbidden =
      result.timedOut !== true && FORBIDDEN_PATTERN.test(result.stderr);

    return fail(forbidden ? 'forbidden' : 'request-failed', args.alert);
  }

  printResult({alert: args.alert, dismissed: true});

  return EXIT_CODES.OK;
};
