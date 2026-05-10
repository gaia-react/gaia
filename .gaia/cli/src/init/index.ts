/**
 * `gaia init` subcommand router.
 *
 * Dispatches to per-step handlers under `./<step>.ts`. Each handler
 * reads and writes `.gaia/init-state.json` so the `/gaia-init` skill
 * can resume on failure (network drop, user cancellation, IDE crash).
 *
 * Object-map dispatch (no `switch`) per the project's typescript skill rules.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {run as runBootstrapEnv} from './bootstrap-env.js';
import {run as runConfigureAutomation} from './configure-automation.js';
import {run as runConfigureI18n} from './configure-i18n.js';
import {run as runFinalize} from './finalize.js';
import {run as runRename} from './rename.js';
import {run as runResume} from './resume.js';
import {run as runStripBranding} from './strip-branding.js';
import {run as runWireStatusline} from './wire-statusline.js';

const HELP_TEXT = `Usage: gaia init <subcommand> [args]

  strip-branding --title <T>
                            Remove GAIA branding from the project.
  configure-i18n --locales <list> --strip <bool>
                            Configure or strip the i18n surface.
  rename --title <T> --kebab <K>
                            Rename the project across package.json + locales.
  wire-statusline --mode <global|project|skip>
                            Wire the GAIA statusline into Claude settings.
  bootstrap-env             Copy .env.example to .env if .env is absent.
  configure-automation --wiki <m> --update-deps <m> --pnpm-audit <m> --stale-branches <m>
                            Write .gaia/automation.json (Phase A of GAIA CI).
  finalize                  Final cleanup steps for the init runbook.
  resume [--from-step <N>]  Resume a partially-completed init via state file.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type SubcommandHandler = (
  args: readonly string[]
) => number | Promise<number>;

const SUBCOMMAND_HANDLERS: Readonly<Partial<Record<string, SubcommandHandler>>> = {
  'bootstrap-env': runBootstrapEnv,
  'configure-automation': runConfigureAutomation,
  'configure-i18n': runConfigureI18n,
  'finalize': runFinalize,
  'rename': runRename,
  'resume': runResume,
  'strip-branding': runStripBranding,
  'wire-statusline': runWireStatusline,
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
    message: `unknown init subcommand: ${subcommand}`,
    subcommand: `init ${subcommand}`,
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};
