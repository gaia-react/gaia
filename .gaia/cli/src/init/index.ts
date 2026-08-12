/**
 * Each per-step handler under `./<step>.ts` reads and writes
 * `.gaia/init-state.json` so the `/gaia-init` skill can resume on failure
 * (network drop, user cancellation, IDE crash).
 *
 * Also owns the target guard: every step rewrites the tree it runs in, and
 * every per-step precondition asks only whether its own rewrite is doable,
 * never where it is running. The guard is here rather than in any one step
 * because all eight resolve the target identically from ambient state.
 */
import {existsSync} from 'node:fs';
import path from 'node:path';
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

type RunOptions = {
  cwd?: string;
};

type SubcommandHandler = (
  args: readonly string[],
  options: RunOptions
) => number | Promise<number>;

/**
 * A GAIA project carries `.gaia/manifest.json`; it is written at scaffold time
 * and read by `/update-gaia`. A parent project or an unrelated sibling
 * checkout has none, which is what makes it a usable floor here.
 */
const MANIFEST_RELATIVE = path.join('.gaia', 'manifest.json');

/**
 * `.gaia/cli/src` is the CLI's TypeScript source, which is excluded from the
 * adopter bundle: adopters get the compiled `.gaia/cli/gaia` and nothing else,
 * so the directory is present only in the GAIA template source itself.
 */
const CLI_SOURCE_RELATIVE = path.join('.gaia', 'cli', 'src');

/**
 * Refuse to rewrite a tree that is not the scaffold these steps are for.
 * Returns an exit code when the target is wrong, `null` when it is fine.
 */
const targetRefusal = (cwd: string, subcommand: string): null | number => {
  if (!existsSync(path.join(cwd, MANIFEST_RELATIVE))) {
    structuredError({
      code: 'not_a_gaia_project',
      message: `refusing to run in ${cwd}: it has no ${MANIFEST_RELATIVE}, so it is not a GAIA project; re-run from the root of the scaffold you mean to initialize`,
      subcommand: `init ${subcommand}`,
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (existsSync(path.join(cwd, CLI_SOURCE_RELATIVE))) {
    structuredError({
      code: 'gaia_template_source',
      message: `refusing to run in ${cwd}: ${CLI_SOURCE_RELATIVE} is present, so this is the GAIA template source rather than a project scaffolded from it`,
      subcommand: `init ${subcommand}`,
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  return null;
};

const SUBCOMMAND_HANDLERS: Readonly<
  Partial<Record<string, SubcommandHandler>>
> = {
  'bootstrap-env': runBootstrapEnv,
  'configure-automation': runConfigureAutomation,
  'configure-i18n': runConfigureI18n,
  finalize: runFinalize,
  rename: runRename,
  resume: runResume,
  'strip-branding': runStripBranding,
  'wire-statusline': runWireStatusline,
};

export const run = async (
  argv: readonly string[],
  options: RunOptions = {}
): Promise<number> => {
  const subcommand = argv[0];
  const rest = argv.slice(1);

  if (subcommand === undefined || HELP_TOKENS.has(subcommand)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const handler = SUBCOMMAND_HANDLERS[subcommand];

  if (handler !== undefined) {
    const cwd = options.cwd ?? process.cwd();
    // A help request writes nothing, so it is readable from anywhere. Guard
    // only the invocations that would rewrite the tree.
    const [firstRestToken] = rest;
    const askingForHelp =
      firstRestToken !== undefined && HELP_TOKENS.has(firstRestToken);
    const refusal = askingForHelp ? null : targetRefusal(cwd, subcommand);

    if (refusal !== null) return refusal;
    // Hand the step the path that was guarded. Without this the step resolves
    // its own target from `process.cwd()` and the guard's subject and the
    // rewrite's subject are only incidentally the same.
    const result = await handler(rest, {cwd});

    return typeof result === 'number' ? result : EXIT_CODES.OK;
  }

  structuredError({
    code: 'unknown_subcommand',
    message: `unknown init subcommand: ${subcommand}`,
    subcommand: `init ${subcommand}`,
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};
