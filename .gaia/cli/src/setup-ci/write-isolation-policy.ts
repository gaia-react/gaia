/**
 * `gaia setup-ci write-isolation-policy <policy>` handler.
 *
 * Writes `isolation_policy` to `.gaia/automation.json` (the committed
 * config). Read-merges the new value onto the RAW parsed JSON via
 * `readAutomationConfigRaw`, never onto Zod's stripped `config`, so a key
 * a newer binary wrote survives the round-trip.
 *
 * Refuses (non-zero) when the config is missing or malformed; fail-closed,
 * no destructive write on a broken state. Also refuses, and writes
 * nothing, when the value is not one of the three known policies: the
 * WRITE boundary rejects what the READ boundary (the permissive schema)
 * tolerates.
 */
import {EXIT_CODES} from '../exit.js';
import {
  isIsolationPolicy,
  ISOLATION_POLICIES,
  readAutomationConfigRaw,
} from '../schemas/automation-config.js';
import type {AutomationConfig} from '../schemas/automation-config.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../wiki/util/git.js';
import {writeAutomationConfig} from './util/automation-write.js';

const HELP_TEXT = `Usage: gaia setup-ci write-isolation-policy <${ISOLATION_POLICIES.join('|')}>

  Write isolation_policy to .gaia/automation.json (committed), read-merged
  onto the raw parsed config so a key a newer binary wrote survives.
  Refuses if the config is missing or malformed, or if the value is not
  one of: ${ISOLATION_POLICIES.join(', ')}.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type RunOptions = {
  cwd?: string;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  if (argv.length === 0 || HELP_TOKENS.has(argv[0])) {
    process.stdout.write(HELP_TEXT);

    return argv.length === 0 ? EXIT_CODES.UNKNOWN_SUBCOMMAND : EXIT_CODES.OK;
  }

  const valueToken = argv[0];
  const rest = argv.slice(1);

  if (rest.length > 0) {
    structuredError({
      code: 'invalid_arguments',
      message: `unexpected argument: ${rest[0]}`,
      subcommand: 'setup-ci write-isolation-policy',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (!isIsolationPolicy(valueToken)) {
    structuredError({
      code: 'invalid_arguments',
      message: `unrecognized isolation policy: ${valueToken}. Supported: ${ISOLATION_POLICIES.join(', ')}`,
      subcommand: 'setup-ci write-isolation-policy',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const value = valueToken;

  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message:
        'gaia setup-ci write-isolation-policy must run inside a git repository',
      subcommand: 'setup-ci write-isolation-policy',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const result = readAutomationConfigRaw(repoRoot);

  if (result.status === 'missing') {
    structuredError({
      code: 'config_missing',
      message: '.gaia/automation.json does not exist',
      subcommand: 'setup-ci write-isolation-policy',
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  if (result.status === 'malformed') {
    structuredError({
      code: 'config_malformed',
      message: result.error,
      subcommand: 'setup-ci write-isolation-policy',
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  writeAutomationConfig(repoRoot, {
    ...result.raw,
    isolation_policy: value,
  } as AutomationConfig);

  process.stdout.write(`${JSON.stringify({isolation_policy: value})}\n`);

  return EXIT_CODES.OK;
};
