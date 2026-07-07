/**
 * `gaia init strip-branding --title <T>` handler.
 *
 * Codifies Step 3 of `/gaia-init`. Removes GAIA-specific branding from the
 * project so an adopter can start clean:
 *
 *   1. Delete `.github/FUNDING.yml`.
 *   2. Replace the root `README.md` with the project-agnostic template at
 *      `.gaia/templates/README.md`, substituting `{{PROJECT_TITLE}}`.
 *   3. De-brand the Storybook sidebar in `.storybook/preview.ts`: rewrite
 *      the brand to the project title with no GAIA image or URL.
 *
 * Idempotent: re-running is safe; files already removed stay removed,
 * the README replacement is unchanged once written, and the Storybook
 * edit is a no-op once the project title is in place.
 *
 * Stdout: nothing on success. Exit codes: 0 / 1 / 2.
 */
import {existsSync, readFileSync, rmSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {atomicWriteFileSync} from '../util/atomic-write.js';
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

type FlagParseFailure = {
  message: string;
  ok: false;
};

type FlagParseResult = FlagParseFailure | FlagParseSuccess;

type FlagParseSuccess = {
  flags: Flags;
  ok: true;
};

type Flags = {
  title: string;
};

const takeValue = (
  argv: readonly string[],
  index: number,
  flag: string
): {message: string; ok: false} | {ok: true; value: string} => {
  // `noUncheckedIndexedAccess` is off, so TS types `argv[index]` as `string`,
  // not `string | undefined`; check the bound explicitly instead of
  // comparing the indexed value to `undefined`.
  if (index >= argv.length) {
    return {message: `${flag} requires a value`, ok: false};
  }

  return {ok: true, value: argv[index]};
};

const parseFlags = (argv: readonly string[]): FlagParseResult => {
  let title: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--title') {
      const taken = takeValue(argv, index + 1, '--title');

      if (!taken.ok) return taken;
      title = taken.value;
      index += 1;
    } else {
      return {message: `unknown flag: ${token}`, ok: false};
    }
  }

  if (title === undefined) {
    return {message: '--title is required', ok: false};
  }

  return {flags: {title}, ok: true};
};

const FUNDING_PATH = '.github/FUNDING.yml';
const README_TEMPLATE = '.gaia/templates/README.md';
const README_TARGET = 'README.md';
const PREVIEW_FILE = '.storybook/preview.ts';
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

const debrandStorybook = (cwd: string, title: string): void => {
  const target = path.join(cwd, PREVIEW_FILE);

  if (!existsSync(target)) return; // preview may already be customized
  const original = readFileSync(target, 'utf8');
  let next = original;

  // Rewrite the brand to the project wordmark: no GAIA title or URL.
  // A function replacement avoids `$` in the title being read as a backref.
  const safeTitle = title
    .replaceAll('\\', '\\\\')
    .replaceAll("'", String.raw`\'`);

  next = next.replaceAll(
    /const BRAND = \{[\s\S]*?\};/gu,
    () =>
      `const BRAND = {\n  brandTarget: '_blank',\n  brandTitle: '${safeTitle}',\n};`
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
  if (argv.length > 0 && HELP_TOKENS.has(argv[0])) {
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
    writeReadme(cwd, parsed.flags.title);
    debrandStorybook(cwd, parsed.flags.title);
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
