/**
 * `gaia init configure-i18n --locales <list> --strip <bool>` handler.
 *
 * Codifies Step 5 of `/gaia-init`. Two paths:
 *
 *   --strip false   Keep the i18n scaffolding wired up. Edits
 *                   `app/languages/index.ts` so `LANGUAGES` and the
 *                   `Language` union match the requested locale list, and
 *                   updates `app/i18n.ts`'s `fallbackLng` to the first
 *                   locale.
 *
 *   --strip true    Removes everything i18n-related: deletes
 *                   `app/languages/`, `app/i18n.ts`, the locale-specific
 *                   route segments, and clears any hooks that depend on
 *                   them. NOTE: only the locale list is recorded in state;
 *                   the prose `remove-i18n.md` instruction is invoked by
 *                   the orchestrator skill when full removal is needed.
 *
 * Both paths are idempotent; re-running with the same args is a no-op.
 *
 * Stdout: nothing on success. Exit codes: 0 / 1 / 2.
 */
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import {markStepCompleted} from './util/state.js';

const HELP_TEXT = `Usage: gaia init configure-i18n --locales <list> --strip <bool>

  Configure the project's i18n surface from the user's language picks.

  Required flags:
    --locales <a,b,c>    Comma-separated locale codes to keep (e.g. "en,es").
    --strip <bool>       "true" removes the i18n scaffolding entirely.

  Exit codes:
    0  success (no stdout)
    1  user-correctable error (missing flags, invalid locale list)
    2  unexpected (filesystem failure)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const UNEXPECTED_EXIT = 2;
const STEP_NAME = 'configure-i18n';

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
  locales: string[];
  strip: boolean;
};

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

const parseBool = (raw: string): boolean | null => {
  if (raw === 'true') return true;

  if (raw === 'false') return false;

  return null;
};

const parseLocales = (raw: string): null | string[] => {
  const parts = raw.split(',').flatMap((token) => {
    const trimmed = token.trim();

    return trimmed.length > 0 ? [trimmed] : [];
  });

  if (parts.length === 0) return null;

  for (const code of parts) {
    if (!/^[a-z]{2,3}(-[A-Za-z]{2,4})?$/u.test(code)) return null;
  }

  return parts;
};

const parseFlags = (argv: readonly string[]): FlagParseResult => {
  let locales: string[] | undefined;
  let strip: boolean | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--locales') {
      const taken = takeValue(argv, index + 1, '--locales');

      if (!taken.ok) return taken;
      const parsed = parseLocales(taken.value);

      if (parsed === null) {
        return {message: 'invalid --locales list', ok: false};
      }
      locales = parsed;
      index += 1;
      continue;
    }

    if (token === '--strip') {
      const taken = takeValue(argv, index + 1, '--strip');

      if (!taken.ok) return taken;
      const parsed = parseBool(taken.value);

      if (parsed === null) {
        return {message: '--strip must be "true" or "false"', ok: false};
      }
      strip = parsed;
      index += 1;
      continue;
    }

    return {message: `unknown flag: ${token}`, ok: false};
  }

  if (locales === undefined) {
    return {message: '--locales is required', ok: false};
  }

  if (strip === undefined) {
    return {message: '--strip is required', ok: false};
  }

  return {flags: {locales, strip}, ok: true};
};

const LANGUAGES_INDEX = 'app/languages/index.ts';
const I18N_FILE = 'app/i18n.ts';

const renderLanguagesIndex = (locales: readonly string[]): string => {
  const imports = locales
    .map((code) => `import ${code} from './${code}';`)
    .join('\n');
  const list = locales.map((code) => `'${code}'`).join(', ');
  const union = locales.map((code) => `'${code}'`).join(' | ');
  const exports = locales.join(', ');

  return `${imports}

export const LANGUAGES = [${list}];

export type Language = ${union};

export default {${exports}} as const;
`;
};

const updateLanguagesIndex = (
  cwd: string,
  locales: readonly string[]
): void => {
  const target = path.join(cwd, LANGUAGES_INDEX);

  if (!existsSync(target)) return;
  const next = renderLanguagesIndex(locales);
  const current = readFileSync(target, 'utf8');

  if (current === next) return;
  atomicWriteFileSync(target, next);
};

const updateI18nFallback = (cwd: string, fallback: string): void => {
  const target = path.join(cwd, I18N_FILE);

  if (!existsSync(target)) return;
  const original = readFileSync(target, 'utf8');
  // Update DEFAULT_LOCALE constant if present (keeps the export in sync).
  let next = original.replace(
    /DEFAULT_LOCALE\s*=\s*['"][^'"]+['"]/u,
    `DEFAULT_LOCALE = '${fallback}'`
  );
  // Replace `fallbackLng: 'xx'` (or "xx") or `fallbackLng: DEFAULT_LOCALE`.
  next = next.replace(
    /fallbackLng:\s*(?:['"][^'"]+['"]|DEFAULT_LOCALE)/u,
    `fallbackLng: '${fallback}'`
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
      subcommand: 'init configure-i18n',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();

  // The full strip flow lives in the prose `remove-i18n.md` instruction
  // (referenced by the slash command). Here we only record the decision
  // so resume can detect it; the orchestrator dispatches the prose path.
  if (!parsed.flags.strip) {
    try {
      updateLanguagesIndex(cwd, parsed.flags.locales);
      const [first] = parsed.flags.locales as [string, ...string[]];
      updateI18nFallback(cwd, first);
    } catch (error) {
      structuredError({
        code: 'configure_i18n_failed',
        message: error instanceof Error ? error.message : String(error),
        subcommand: 'init configure-i18n',
      });

      return UNEXPECTED_EXIT;
    }
  }

  try {
    markStepCompleted(cwd, STEP_NAME, {
      locales: parsed.flags.locales,
      strip: parsed.flags.strip,
    });
  } catch (error) {
    structuredError({
      code: 'state_write_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'init configure-i18n',
    });

    return UNEXPECTED_EXIT;
  }

  return EXIT_CODES.OK;
};
