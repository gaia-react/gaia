/**
 * `gaia-maintainer labels`: the label commands only the maintainer repository
 * runs. Adopters receive the generated wiki page through `/update-gaia`.
 */
import {createSubcommandRouter} from '../util/router.js';
import type {SubcommandHandler} from '../util/router.js';
import {run as runDocumentation} from './docs.js';

const HELP_TEXT = `Usage: gaia-maintainer labels <subcommand> [args]

  docs [--repo-root <path>]
                             Regenerate the generated span of the wiki page.
`;

const SUBCOMMAND_HANDLERS: Readonly<
  Partial<Record<string, SubcommandHandler>>
> = {
  docs: runDocumentation,
};

export const run = createSubcommandRouter({
  handlers: SUBCOMMAND_HANDLERS,
  helpText: HELP_TEXT,
});
