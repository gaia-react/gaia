/**
 * `gaia wiki` subcommand router.
 *
 * Phase 3 of the Claude Integration Optimization plan extracts
 * wiki-state primitives out of the prose `wiki-sync.md`, `wiki-lint.md`,
 * and `wiki-consolidate.md` commands. Consumer commands are updated in a
 * follow-up task; this router only ships the seven primitives.
 *
 * Object-map dispatch (no `switch`) per the project's typescript skill rules.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {run as runCommitClassify} from './commit-classify.js';
import {run as runDeadPaths} from './dead-paths.js';
import {run as runLogPrepend} from './log-prepend.js';
import {run as runNearCollisions} from './near-collisions.js';
import {run as runOrphans} from './orphans.js';
import {run as runPageIndex} from './page-index.js';
import {run as runState} from './state.js';
import {run as runStateBump} from './state-bump.js';
import {run as runStateInit} from './state-init.js';
import {run as runSyncLand} from './sync-land.js';

const HELP_TEXT = `Usage: gaia wiki <subcommand> [args]

  state [--json]                              Drift report.
  commit-classify --since <sha> [--json]      Per-commit WORTHY/SKIP.
  state-init <sha>                            Create wiki/.state.json (refuses if exists).
  state-bump <field> <value>                  Atomic field bump in wiki/.state.json.
  log-prepend --sha <h> --decision <D> --reason "..."
                                              Prepend a decision line to wiki/log.md.
  page-index [--json]                         Frontmatter + wikilink walk.
  orphans                                     Pages with zero inbound links.
  near-collisions [--max-distance N]          Per-domain Levenshtein over slugs.
  dead-paths [--json]                         Backticked repo paths in wiki/ that don't exist.
  sync land [--branch-aware]                  Branch-aware landing of staged wiki changes.
`;

const SYNC_HELP_TEXT = `Usage: gaia wiki sync <subcommand> [args]

  land [--branch-aware]                       Land staged wiki changes via the correct
                                              branch strategy.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type SubcommandHandler = (
  args: readonly string[]
) => number | Promise<number>;

const runSync: SubcommandHandler = async (
  args: readonly string[]
): Promise<number> => {
  const subcommand = args[0] as string | undefined;
  const rest = args.slice(1);

  if (subcommand === undefined || HELP_TOKENS.has(subcommand)) {
    process.stdout.write(SYNC_HELP_TEXT);

    return EXIT_CODES.OK;
  }

  if (subcommand === 'land') {
    return runSyncLand(rest);
  }

  structuredError({
    code: 'unknown_subcommand',
    message: `unknown wiki sync subcommand: ${subcommand}`,
    subcommand: `wiki sync ${subcommand}`,
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};

const SUBCOMMAND_HANDLERS: Readonly<Partial<Record<string, SubcommandHandler>>> = {
  'commit-classify': runCommitClassify,
  'dead-paths': runDeadPaths,
  'log-prepend': runLogPrepend,
  'near-collisions': runNearCollisions,
  'orphans': runOrphans,
  'page-index': runPageIndex,
  'state': runState,
  'state-bump': runStateBump,
  'state-init': runStateInit,
  'sync': runSync,
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
    message: `unknown wiki subcommand: ${subcommand}`,
    subcommand: `wiki ${subcommand}`,
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};
