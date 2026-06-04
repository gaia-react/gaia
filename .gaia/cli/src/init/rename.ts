/**
 * `gaia init rename --title <T> --kebab <K>` handler.
 *
 * Codifies Step 6 of `/gaia-init`. Renames the project across the small
 * set of files that carry an identity:
 *
 *   - `package.json` "name" → kebab-case title.
 *   - `CLAUDE.md` "# GAIA React" heading → "# <Title>" (only the first
 *     occurrence, preserves later content).
 *   - `app/languages/en/common.ts` `meta.siteName` → `<Title>`.
 *   - `app/languages/en/pages/_index.ts` `meta.title`, `title`, and
 *     `heroTitle` → `<Title>` (when the keys exist).
 *
 * Idempotent: re-running with the same args is a no-op once the rename
 * has been applied.
 *
 * Stdout: nothing on success. Exit codes: 0 / 1 / 2.
 */
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {markStepCompleted} from './util/state.js';

const HELP_TEXT = `Usage: gaia init rename --title <T> --kebab <K>

  Rename the project across package.json, CLAUDE.md, and seeded language
  files (Step 6 of /gaia-init).

  Required flags:
    --title <T>     Project title (Title Case, e.g. "Hello World").
    --kebab <K>     Kebab-case slug (e.g. "hello-world").

  Exit codes:
    0  success (no stdout)
    1  user-correctable error (missing flags, no package.json)
    2  unexpected (filesystem failure)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const UNEXPECTED_EXIT = 2;
const STEP_NAME = 'rename';

type Flags = {
  kebab: string;
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
  let kebab: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string;

    if (token === '--title') {
      const taken = takeValue(argv, index + 1, '--title');

      if (!taken.ok) return taken;
      title = taken.value;
      index += 1;
      continue;
    }

    if (token === '--kebab') {
      const taken = takeValue(argv, index + 1, '--kebab');

      if (!taken.ok) return taken;
      kebab = taken.value;
      index += 1;
      continue;
    }

    return {message: `unknown flag: ${token}`, ok: false};
  }

  if (title === undefined) {
    return {message: '--title is required', ok: false};
  }

  if (kebab === undefined) {
    return {message: '--kebab is required', ok: false};
  }

  if (!/^[a-z][\d a-z-]*$/u.test(kebab)) {
    return {message: '--kebab must be a kebab-case identifier', ok: false};
  }

  return {flags: {kebab, title}, ok: true};
};

const PACKAGE_JSON = 'package.json';
const CLAUDE_MD = 'CLAUDE.md';
const COMMON_TS = 'app/languages/en/common.ts';
const INDEX_PAGE_TS = 'app/languages/en/pages/_index.ts';

const renamePackageJson = (cwd: string, kebab: string): void => {
  const target = path.join(cwd, PACKAGE_JSON);

  if (!existsSync(target)) {
    throw new Error('package.json not found at repo root');
  }
  const raw = readFileSync(target, 'utf8');
  const parsed = JSON.parse(raw) as Record<string, unknown>;

  if (parsed.name === kebab) return;
  parsed.name = kebab;
  const trailing = raw.endsWith('\n') ? '\n' : '';
  atomicWriteFileSync(target, `${JSON.stringify(parsed, null, 2)}${trailing}`);
};

const renameClaudeMd = (cwd: string, title: string): void => {
  const target = path.join(cwd, CLAUDE_MD);

  if (!existsSync(target)) return;
  const original = readFileSync(target, 'utf8');
  // Match the FIRST line that starts with `# ` and replace its body.
  const next = original.replace(/^#\s+.*$/mu, `# ${title}`);

  if (next !== original) {
    atomicWriteFileSync(target, next);
  }
};

/**
 * Replace every occurrence of a string-literal property's value while
 * preserving quotes (single or double) and surrounding whitespace.
 * Used for keys whose value is the project title regardless of where
 * they appear (top-level, nested in `meta`, etc.).
 */
const replaceStringPropertyAll = (
  source: string,
  key: string,
  newValue: string
): string => {
  const escaped = newValue.replaceAll(/[$\\]/gu, '\\$&');
  const pattern = new RegExp(
    String.raw`(\b${key}\s*:\s*)(['"])(?:[^'"\\]|\\.)*\2`,
    'gmu'
  );

  return source.replace(pattern, `$1$2${escaped}$2`);
};

/**
 * Replace a string-literal property's value, but only when the key is
 * indented at the file's top object level (a single indentation unit).
 * Nested keys with the same name (e.g. a `title` inside a deeper route
 * object) are left untouched so a user-diverged file is preserved.
 */
const replaceTopLevelStringProperty = (
  source: string,
  key: string,
  newValue: string
): string => {
  const escaped = newValue.replaceAll(/[$\\]/gu, '\\$&');
  const pattern = new RegExp(
    String.raw`^(\x20\x20${key}\s*:\s*)(['"])(?:[^'"\\]|\\.)*\2`,
    'gmu'
  );

  return source.replace(pattern, `$1$2${escaped}$2`);
};

/**
 * Replace the `title` string-literal nested directly inside the
 * top-level `meta: { … }` block. Scopes the rewrite to the seed's
 * `meta.title` so other `title` keys elsewhere in the file are untouched.
 */
const replaceMetaTitle = (source: string, newValue: string): string => {
  const escaped = newValue.replaceAll(/[$\\]/gu, '\\$&');
  // Match `meta: {` opened at the top object level, then the first
  // `title:` string within it before the block closes.
  const pattern =
    /^(\x20\x20meta\s*:\s*\{[^}]*?\btitle\s*:\s*)(['"])(?:[^'"\\]|\\.)*\2/mu;

  return source.replace(pattern, `$1$2${escaped}$2`);
};

const renameCommonTs = (cwd: string, title: string): void => {
  const target = path.join(cwd, COMMON_TS);

  if (!existsSync(target)) return;
  const original = readFileSync(target, 'utf8');
  // common.ts only carries one identity-bearing key, `siteName`. Other
  // `*Name` properties exist (e.g. form labels) but no other `siteName`,
  // so a global rewrite is safe.
  const next = replaceStringPropertyAll(original, 'siteName', title);

  if (next !== original) {
    atomicWriteFileSync(target, next);
  }
};

const renameIndexPage = (cwd: string, title: string): void => {
  const target = path.join(cwd, INDEX_PAGE_TS);

  if (!existsSync(target)) return;
  const original = readFileSync(target, 'utf8');
  let next = original;
  // The seeded `_index.ts` has exactly three identity-bearing keys whose
  // value is the project title: top-level `heroTitle`, top-level `title`,
  // and `meta.title`. Scope the rewrite to those precise locations; a
  // global `title` rewrite would clobber `title` keys in extra routes a
  // user may have added (data loss on a diverged file).
  next = replaceTopLevelStringProperty(next, 'heroTitle', title);
  next = replaceTopLevelStringProperty(next, 'title', title);
  next = replaceMetaTitle(next, title);

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
      subcommand: 'init rename',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();

  try {
    renamePackageJson(cwd, parsed.flags.kebab);
    renameClaudeMd(cwd, parsed.flags.title);
    renameCommonTs(cwd, parsed.flags.title);
    renameIndexPage(cwd, parsed.flags.title);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);

    if (message.includes('not found')) {
      structuredError({
        code: 'package_json_missing',
        message,
        subcommand: 'init rename',
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }
    structuredError({
      code: 'rename_failed',
      message,
      subcommand: 'init rename',
    });

    return UNEXPECTED_EXIT;
  }

  try {
    markStepCompleted(cwd, STEP_NAME, {
      kebab: parsed.flags.kebab,
      title: parsed.flags.title,
    });
  } catch (error) {
    structuredError({
      code: 'state_write_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'init rename',
    });

    return UNEXPECTED_EXIT;
  }

  return EXIT_CODES.OK;
};
