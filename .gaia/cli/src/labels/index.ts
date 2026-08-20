/**
 * `gaia labels`: the three commands that read `.gaia/labels.json`.
 *
 * `sync` reconciles a repository against the registry, `docs` regenerates the
 * span of `wiki/concepts/GitHub Labels.md`, and `check` cross-references every
 * label literal in the tracked tree back against the registry.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {lookupOwn} from '../util/argv.js';
import {run as runCheck} from './check.js';
import {run as runDocumentation} from './docs.js';
import {run as runSync} from './sync.js';

const HELP_TEXT = `Usage: gaia labels <subcommand> [args]

  sync [--repo <owner/name>] [--dry-run] [--adopt] [--adopt-palette]
       [--prune-deprecated] [--enforce-blocked] [--json]
       [--audience adopter|maintainer] [--feature <key>]...
                             Reconcile a repository against the registry.
  docs [--repo-root <path>] [--check]
                             Regenerate the generated span of the wiki page.
  check [--repo-root <path>] [--json]
                             Fail on a label literal the registry does not
                             carry, or carries as blocked.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type SubcommandHandler = (args: readonly string[]) => number | Promise<number>;

const SUBCOMMAND_HANDLERS: Readonly<
  Partial<Record<string, SubcommandHandler>>
> = {
  check: runCheck,
  docs: runDocumentation,
  sync: runSync,
};

export const run = async (argv: readonly string[]): Promise<number> => {
  const subcommand = argv[0];
  const rest = argv.slice(1);

  if (subcommand === undefined || HELP_TOKENS.has(subcommand)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const handler = lookupOwn(SUBCOMMAND_HANDLERS, subcommand);

  if (handler !== undefined) {
    const result = await handler(rest);

    return typeof result === 'number' ? result : EXIT_CODES.OK;
  }

  structuredError({
    code: 'unknown_subcommand',
    message: `unknown labels subcommand: ${subcommand}`,
    subcommand: `labels ${subcommand}`,
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};
