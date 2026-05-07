/**
 * `gaia mentorship` subcommand router.
 *
 * Routes to:
 *   gaia mentorship enable
 *   gaia mentorship disable
 *   gaia mentorship purge
 *   gaia mentorship status
 *   gaia mentorship analytics enable|disable|dry-run
 *   gaia mentorship _internal-write-config (consumed by gaia-init)
 *   gaia mentorship _internal-provision-dirs (consumed by gaia-init)
 *   gaia mentorship _internal-assert-memory-rules (consumed by the session-start hook)
 *
 * Object-map dispatch (no `switch`) per the project's typescript skill rules.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {run as runInternalAssertMemoryRules} from './_internal-assert-memory-rules.js';
import {run as runInternalProvisionDirectories} from './_internal-provision-dirs.js';
import {run as runInternalWriteConfig} from './_internal-write-config.js';
import {run as runAnalyticsDisable} from './analytics-disable.js';
import {run as runAnalyticsDryRun} from './analytics-dry-run.js';
import {run as runAnalyticsEnable} from './analytics-enable.js';
import {run as runDisable} from './disable.js';
import {run as runEnable} from './enable.js';
import {run as runPurge} from './purge.js';
import {run as runStatus} from './status.js';

const HELP_TEXT = `Usage: gaia mentorship <subcommand> [args]

  enable                       Enable mentorship + analytics (interactive; --yes for non-interactive).
  disable                      Disable mentorship; existing files are preserved.
  purge                        Delete all mentorship data (interactive; --yes).
  status                       Print structured JSON describing mentorship state.
  analytics enable             Enable analytics report generation.
  analytics disable            Disable analytics; mentorship JSONL writes continue.
  analytics dry-run            Print today's analytics report JSON; never uploads.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type Handler = (
  argv: readonly string[]
) => number | Promise<number | undefined> | undefined;

const TOP_LEVEL_HANDLERS: Readonly<Partial<Record<string, Handler>>> = {
  '_internal-assert-memory-rules': runInternalAssertMemoryRules,
  '_internal-provision-dirs': runInternalProvisionDirectories,
  '_internal-write-config': runInternalWriteConfig,
  disable: runDisable,
  enable: runEnable,
  purge: runPurge,
  status: runStatus,
};

const ANALYTICS_HANDLERS: Readonly<Partial<Record<string, Handler>>> = {
  disable: runAnalyticsDisable,
  'dry-run': runAnalyticsDryRun,
  enable: runAnalyticsEnable,
};

const handleAnalytics = async (rest: readonly string[]): Promise<number> => {
  const subSubcommand = rest[0] as string | undefined;
  const subRest = rest.slice(1);

  if (subSubcommand === undefined || HELP_TOKENS.has(subSubcommand)) {
    process.stdout.write(
      'Usage: gaia mentorship analytics <enable|disable|dry-run>\n'
    );

    return EXIT_CODES.OK;
  }
  const handler = ANALYTICS_HANDLERS[subSubcommand];

  if (handler === undefined) {
    structuredError({
      code: 'unknown_subcommand',
      subcommand: `mentorship analytics ${subSubcommand}`,
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }
  const result = await handler(subRest);

  return typeof result === 'number' ? result : EXIT_CODES.OK;
};

export const run = async (argv: readonly string[]): Promise<number> => {
  const subcommand = argv[0] as string | undefined;
  const rest = argv.slice(1);

  if (subcommand === undefined || HELP_TOKENS.has(subcommand)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  if (subcommand === 'analytics') {
    return handleAnalytics(rest);
  }
  const handler = TOP_LEVEL_HANDLERS[subcommand];

  if (handler === undefined) {
    structuredError({
      code: 'unknown_subcommand',
      subcommand: `mentorship ${subcommand}`,
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }
  const result = await handler(rest);

  return typeof result === 'number' ? result : EXIT_CODES.OK;
};
