/**
 * `gaia-maintainer release` subcommand router.
 *
 * Chains preflight → bump → quality gate → changelog → scrub-wiki →
 * manifest → commit-and-tag for `/gaia-release`. The slash command is a
 * thin orchestrator; each subcommand owns its acceptance criteria and
 * tests.
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
import {run as runRuntimeDeps} from './runtime-deps.js';
import {run as runScrubWiki} from './scrub-wiki.js';
import {run as runScrub} from './scrub.js';

const HELP_TEXT = `Usage: gaia-maintainer release <subcommand> [args]

  preflight [--branch <name>]                 Branch + working-tree + wiki state checks.
  bump [--auto]                               Conventional-commit semver bump.
  changelog [--draft] [--version <X.Y.Z>]     Render / graduate the CHANGELOG block.
  scrub-wiki [--version <X.Y.Z>] [--date <D>] Reset wiki/hot.md and wiki/log.md.
  manifest [--out <path>] [--stdout]          Regenerate .gaia/manifest.json.
  manifest --check [--json]                   Verify committed manifest is fresh + lint classifier sets.
  scrub <staging-dir> [--config <path>] [--json]
                                              Apply bundle-time marker-strip + leak-check.
  runtime-deps [--staging <dir>] [--manifest <path>] [--json]
                                              Verify shipped scripts only call shipped paths.
  commit-and-tag (--commit | --tag) [--no-push]
                                              Commit + amend state, or tag + push.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type SubcommandHandler = (args: readonly string[]) => number | Promise<number>;

const SUBCOMMAND_HANDLERS: Readonly<
  Partial<Record<string, SubcommandHandler>>
> = {
  bump: runBump,
  changelog: runChangelog,
  'commit-and-tag': runCommitAndTag,
  manifest: runManifest,
  preflight: runPreflight,
  'runtime-deps': runRuntimeDeps,
  scrub: runScrub,
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
