/**
 * `gaia init strip-branding --title <T>` handler.
 *
 * Codifies Step 3 of `/gaia-init`. Removes GAIA-specific branding from the
 * project so an adopter can start clean:
 *
 *   1. Delete `.github/FUNDING.yml` and `app/components/GaiaLogo/`.
 *   2. Replace the root `README.md` with the project-agnostic template at
 *      `.gaia/templates/README.md`, substituting `{{PROJECT_TITLE}}`.
 *   3. Edit `app/components/Header/index.tsx` to drop the `GaiaLogo` import
 *      and replace the `<GaiaLogo … />` element with a text wordmark.
 *
 * Idempotent: re-running is safe; files already removed stay removed,
 * the README replacement is unchanged once written, and the Header edit
 * is a no-op once the wordmark is already in place.
 *
 * Stdout: nothing on success. Exit codes: 0 / 1 / 2.
 */
import {existsSync, readFileSync, rmSync} from 'node:fs';
import path from 'node:path';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {markStepCompleted} from './util/state.js';

const HELP_TEXT = `Usage: gaia init strip-branding --title <T>

  Strip GAIA-specific branding from the project (Step 3 of /gaia-init).

  Required flags:
    --title <T>        Project title (Title Case, e.g. "Hello World").

  Exit codes:
    0  success (no stdout)
    1  user-correctable error (missing flag, missing template)
    2  unexpected (filesystem failure)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const UNEXPECTED_EXIT = 2;
const STEP_NAME = 'strip-branding';

type Flags = {
  title: string;
};

type FlagParseSuccess = {
  flags: Flags;
  ok: true;
};

type FlagParseFailure = {
  message: string;
  ok: false;
};

type FlagParseResult = FlagParseFailure | FlagParseSuccess;

const takeValue = (
  argv: readonly string[],
  index: number,
  flag: string
): {message: string; ok: false} | {ok: true; value: string} => {
  const value = argv[index];

  if (value === undefined)
    return {message: `${flag} requires a value`, ok: false};

  return {ok: true, value};
};

const parseFlags = (argv: readonly string[]): FlagParseResult => {
  let title: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string;

    if (token === '--title') {
      const taken = takeValue(argv, index + 1, '--title');

      if (!taken.ok) return taken;
      title = taken.value;
      index += 1;
      continue;
    }

    return {message: `unknown flag: ${token}`, ok: false};
  }

  if (title === undefined) {
    return {message: '--title is required', ok: false};
  }

  return {flags: {title}, ok: true};
};

const FUNDING_PATH = '.github/FUNDING.yml';
const GAIA_LOGO_DIR = 'app/components/GaiaLogo';
const README_TEMPLATE = '.gaia/templates/README.md';
const README_TARGET = 'README.md';
const HEADER_FILE = 'app/components/Header/index.tsx';
const PLACEHOLDER = '{{PROJECT_TITLE}}';

const removeIfPresent = (cwd: string, relative: string): void => {
  const absolute = path.join(cwd, relative);

  if (existsSync(absolute)) {
    rmSync(absolute, {force: true, recursive: true});
  }
};

const writeReadme = (cwd: string, title: string): void => {
  const templatePath = path.join(cwd, README_TEMPLATE);

  if (!existsSync(templatePath)) {
    throw new Error(`${README_TEMPLATE} not found; cannot replace README`);
  }
  const template = readFileSync(templatePath, 'utf8');
  const rendered = template.split(PLACEHOLDER).join(title);
  const target = path.join(cwd, README_TARGET);

  if (existsSync(target)) {
    const current = readFileSync(target, 'utf8');

    if (current === rendered) return;
  }
  atomicWriteFileSync(target, rendered);
};

const WORDMARK_REPLACEMENT =
  '<span className="text-body text-xl font-bold">{t(\'meta.siteName\')}</span>';

const stripGaiaLogoFromHeader = (cwd: string): void => {
  const target = path.join(cwd, HEADER_FILE);

  if (!existsSync(target)) return; // header may already be customized
  const original = readFileSync(target, 'utf8');
  let next = original;

  // Drop the import line; match common forms (`import GaiaLogo from
  // '~/components/GaiaLogo';` with or without trailing newline / whitespace).
  next = next.replaceAll(
    /^import\s+GaiaLogo\s+from\s+['"]~\/components\/GaiaLogo['"];?\n/gmu,
    ''
  );

  // Replace the JSX element. The runbook ships a specific instance:
  //   <GaiaLogo className="h-6 sm:h-7" />
  // Match the self-closing form AND a paired `<GaiaLogo …>…</GaiaLogo>`
  // form, in case the wordmark was customized into a wrapping element.
  next = next.replaceAll(
    /<GaiaLogo\b[^>]*\/>|<GaiaLogo\b[^>]*>[\s\S]*?<\/GaiaLogo>/gu,
    WORDMARK_REPLACEMENT
  );

  if (next !== original) {
    atomicWriteFileSync(target, next);
  }
};

type RunOptions = {
  cwd?: string;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  if (argv.length > 0 && HELP_TOKENS.has(argv[0] as string)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const parsed = parseFlags(argv);

  if (!parsed.ok) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.message,
      subcommand: 'init strip-branding',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();

  try {
    removeIfPresent(cwd, FUNDING_PATH);
    removeIfPresent(cwd, GAIA_LOGO_DIR);
    writeReadme(cwd, parsed.flags.title);
    stripGaiaLogoFromHeader(cwd);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);

    if (message.includes('not found')) {
      structuredError({
        code: 'template_missing',
        message,
        subcommand: 'init strip-branding',
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }
    structuredError({
      code: 'strip_branding_failed',
      message,
      subcommand: 'init strip-branding',
    });

    return UNEXPECTED_EXIT;
  }

  try {
    markStepCompleted(cwd, STEP_NAME, {title: parsed.flags.title});
  } catch (error) {
    structuredError({
      code: 'state_write_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'init strip-branding',
    });

    return UNEXPECTED_EXIT;
  }

  return EXIT_CODES.OK;
};
