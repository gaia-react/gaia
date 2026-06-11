/**
 * `gaia update-deps` subcommand router.
 *
 * Replicates Phases 1-3 of `.claude/skills/update-deps/SKILL.md` as a
 * deterministic shell primitive so the GAIA CI dependabot workflow can
 * split major bumps into per-group PRs before the LLM-driven flow runs.
 *
 * The `run` subcommand is currently the only entry, but the namespace is
 * structured to admit additional subcommands (e.g. discovery-only,
 * cap-only, group-resolve) without restructuring the dispatcher.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {run as runDecline} from './decline.js';
import {run as runEmit} from './run.js';

const HELP_TEXT = `Usage: gaia update-deps <subcommand> [args]

  run --emit-updates <path>                   Discover outdated packages,
                                              classify into Wave A / Wave B,
                                              and emit a JSON payload at
                                              <path>.
  decline --source <path> --skip <a,b,...>    Snooze update groups so the
                                              statusline stops counting them
                                              (local only). --clear resets.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type SubcommandHandler = (args: readonly string[]) => number | Promise<number>;

const SUBCOMMAND_HANDLERS: Readonly<
  Partial<Record<string, SubcommandHandler>>
> = {
  decline: runDecline,
  run: runEmit,
};

export const run = async (argv: readonly string[]): Promise<number> => {
  const subcommand = argv[0] as string | undefined;
  const rest = argv.slice(1);

  if (subcommand === undefined || HELP_TOKENS.has(subcommand)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const handler = SUBCOMMAND_HANDLERS[subcommand];

  if (handler !== undefined) {
    const result = await handler(rest);

    return typeof result === 'number' ? result : EXIT_CODES.OK;
  }

  structuredError({
    code: 'unknown_subcommand',
    message: `unknown update-deps subcommand: ${subcommand}`,
    subcommand: `update-deps ${subcommand}`,
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};
