/**
 * Writes `dependabot_security_updates` to `.gaia/project.json` (the committed project config)
 * through `updateProjectConfig`, creating the file when absent.
 *
 * Refuses (non-zero), and writes nothing, when the existing file is
 * malformed or when the value is not one of the known values: the WRITE
 * boundary rejects what the READ boundary (the permissive schema)
 * tolerates.
 */
import {EXIT_CODES} from '../exit.js';
import {
  DEPENDABOT_SECURITY_UPDATES,
  isDependabotSecurityUpdates,
} from '../schemas/project-config.js';
import {structuredError} from '../stderr.js';
import {
  ProjectConfigError,
  updateProjectConfig,
} from '../util/project-config-write.js';
import {resolveRepoRoot} from '../util/repo-root.js';

const SUBCOMMAND = 'setup-ci write-dependabot-policy';

const HELP_TEXT = `Usage: gaia setup-ci write-dependabot-policy <${DEPENDABOT_SECURITY_UPDATES.join('|')}>

  Write dependabot_security_updates to .gaia/project.json (committed), merged onto the
  raw parsed config so a key a newer binary wrote survives. Creates the file
  when absent. Refuses if the file is malformed, or if the value is not one
  of: ${DEPENDABOT_SECURITY_UPDATES.join(', ')}.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type RunOptions = {
  cwd?: string;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  const firstArgument = argv[0];

  if (firstArgument === undefined || HELP_TOKENS.has(firstArgument)) {
    process.stdout.write(HELP_TEXT);

    return firstArgument === undefined ?
        EXIT_CODES.UNKNOWN_SUBCOMMAND
      : EXIT_CODES.OK;
  }

  const valueToken = firstArgument;
  const rest = argv.slice(1);

  if (rest.length > 0) {
    structuredError({
      code: 'invalid_arguments',
      message: `unexpected argument: ${rest[0]}`,
      subcommand: SUBCOMMAND,
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (!isDependabotSecurityUpdates(valueToken)) {
    structuredError({
      code: 'invalid_arguments',
      message: `unrecognized dependabot_security_updates value: ${valueToken}. Supported: ${DEPENDABOT_SECURITY_UPDATES.join(', ')}`,
      subcommand: SUBCOMMAND,
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
        'gaia setup-ci write-dependabot-policy must run inside a git repository',
      subcommand: SUBCOMMAND,
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  try {
    updateProjectConfig(repoRoot, {dependabot_security_updates: value});
  } catch (error) {
    if (error instanceof ProjectConfigError && error.kind === 'malformed') {
      structuredError({
        code: 'config_malformed',
        message: error.message,
        subcommand: SUBCOMMAND,
      });

      return EXIT_CODES.CONFIG_INVALID;
    }

    structuredError({
      code: 'project_config_write_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: SUBCOMMAND,
    });

    return EXIT_CODES.STORAGE_INACCESSIBLE;
  }

  process.stdout.write(
    `${JSON.stringify({dependabot_security_updates: value})}\n`
  );

  return EXIT_CODES.OK;
};
