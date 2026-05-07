/**
 * `gaia release` subcommand router.
 *
 * Phase 6 of the Claude Integration Optimization plan extracts the
 * procedural steps of the `/gaia-release` runbook into deterministic
 * CLI subcommands. The slash command becomes a thin orchestrator that
 * chains preflight → bump → quality gate → changelog → scrub-wiki →
 * manifest → commit-and-tag. Each subcommand owns its acceptance
 * criteria and tests.
 *
 * Object-map dispatch (no `switch`) per the project's typescript skill rules.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {run as runBump} from './bump.js';
import {run as runChangelog} from './changelog.js';
import {run as runCommitAndTag} from './commit-and-tag.js';
import {run as runManifest} from './manifest.js';
import {run as runPreflight} from './preflight.js';
import {run as runScrubWiki} from './scrub-wiki.js';

const HELP_TEXT = `Usage: gaia release <subcommand> [args]

  preflight [--branch <name>]                 Branch + working-tree + wiki state checks.
  bump [--auto]                               Conventional-commit semver bump.
  changelog [--draft] [--version <X.Y.Z>]     Render / graduate the CHANGELOG block.
  scrub-wiki [--version <X.Y.Z>] [--date <D>] Reset wiki/hot.md and wiki/log.md.
  manifest [--out <path>] [--stdout]          Regenerate .gaia/manifest.json.
  commit-and-tag (--commit | --tag) [--no-push]
                                              Commit + amend state, or tag + push.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type SubcommandHandler = (
  args: readonly string[]
) => number | Promise<number>;

const SUBCOMMAND_HANDLERS: Readonly<Partial<Record<string, SubcommandHandler>>> = {
  'bump': runBump,
  'changelog': runChangelog,
  'commit-and-tag': runCommitAndTag,
  'manifest': runManifest,
  'preflight': runPreflight,
  'scrub-wiki': runScrubWiki,
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
    message: `unknown release subcommand: ${subcommand}`,
    subcommand: `release ${subcommand}`,
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};
