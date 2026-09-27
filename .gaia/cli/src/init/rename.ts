/**
 * `gaia init rename --title <T> --kebab <K>` handler.
 *
 * Codifies Step 6 of `/gaia-init`. Renames the project across the small
 * set of files that carry an identity:
 *
 *   - `package.json` "name" → kebab-case title.
 *   - `CLAUDE.md` first `# ` heading → "# <Title>" (only the first
 *     occurrence, preserves later content). The heading is a required
 *     precondition rather than something this step creates: a `CLAUDE.md`
 *     carrying none fails the step instead of passing silently.
 *   - `app/languages/en/common.ts` `meta.siteName` → `<Title>` (when the
 *     key exists).
 *   - `app/languages/en/pages/_index.ts` `meta.title`, `title`, and
 *     `heroTitle` → `<Title>` (when the keys exist).
 *
 * A language-file key that is absent is tolerated; one that is present is
 * rewritten wherever its value is a quoted string literal.
 *
 * Idempotent: re-running with the same args is a no-op once the rename
 * has been applied.
 *
 * Stdout: nothing on success. Exit codes: 0 / 1 / 2.
 */
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {takeValue} from '../util/argv.js';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import {escapeJsLiteralValue} from './util/js-literal.js';
import type {JsLiteralQuote} from './util/js-literal.js';
import {markStepCompleted} from './util/state.js';

const HELP_TEXT = `Usage: gaia init rename --title <T> --kebab <K>

  Rename the project across package.json, CLAUDE.md, and seeded language
  files (Step 6 of /gaia-init).

  Required flags:
    --title <T>     Project title (Title Case, e.g. "Hello World").
    --kebab <K>     Kebab-case slug (e.g. "hello-world").

  Exit codes:
    0  success (no stdout)
    1  user-correctable error (missing flags, invalid kebab, no package.json,
       no CLAUDE.md heading)
    2  unexpected (filesystem failure)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const UNEXPECTED_EXIT = 2;
const STEP_NAME = 'rename';

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
  kebab: string;
  title: string;
};

const parseFlags = (argv: readonly string[]): FlagParseResult => {
  let title: string | undefined;
  let kebab: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--title') {
      const taken = takeValue(argv, index + 1, '--title');

      if (!taken.ok) return taken;
      title = taken.value;
      index += 1;
    } else if (token === '--kebab') {
      const taken = takeValue(argv, index + 1, '--kebab');

      if (!taken.ok) return taken;
      kebab = taken.value;
      index += 1;
    } else {
      return {message: `unknown flag: ${token}`, ok: false};
    }
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

const FENCE_LINE = /^\s*(?:```|~~~)/u;
// Tested against one line at a time, which is what keeps `\s` from reaching
// across a line ending: over the whole file it matches the newline after a
// bare `#`, and the rewrite then swallows the blank line below it.
const H1_LINE = /^#\s/u;

/**
 * Index of the document's title heading, or `-1`.
 *
 * The title is the first `# ` line, and it has to sit above the first fenced
 * code block. `# ` opens a shell comment as well as a markdown heading, so a
 * scan that walks into a fence finds one in a shell example, reports a title
 * where there is none, and rewrites a line of the adopter's own code.
 *
 * Stopping at the first fence rather than tracking open and closed ones is
 * deliberate. Whether a later fence *closes* an earlier one is a CommonMark
 * question about delimiter character and run length, and answering it wrong
 * puts the scan back inside a code block; a nested sample, or a `~~~` inside
 * a backtick block, is enough to do it. Nothing has to close for this rule,
 * so no nesting can defeat it.
 */
const findH1Line = (lines: readonly string[]): number => {
  for (const [index, line] of lines.entries()) {
    if (FENCE_LINE.test(line)) return -1;

    if (H1_LINE.test(line)) return index;
  }

  return -1;
};

/**
 * Whether `CLAUDE.md` content carries a heading `rename` can rewrite.
 * Exported so the suite asserting the shipped template through the same
 * predicate the step uses cannot drift from it.
 */
export const claudeMdHasH1 = (source: string): boolean =>
  findH1Line(source.split('\n')) !== -1;

/**
 * True when `CLAUDE.md` is absent, which is tolerated, or carries a heading.
 *
 * The heading is a precondition this step enforces, never one it creates:
 * every rewrite in this module replaces a value the seed already has, and
 * choosing where to insert a heading into a file the user may have
 * restructured is a guess with no right answer. Checked before the first
 * write so a run that cannot finish has not renamed anything.
 */
const claudeMdPreconditionMet = (cwd: string): boolean => {
  const target = path.join(cwd, CLAUDE_MD);

  return !existsSync(target) || claudeMdHasH1(readFileSync(target, 'utf8'));
};

const renameClaudeMd = (cwd: string, title: string): void => {
  const target = path.join(cwd, CLAUDE_MD);

  if (!existsSync(target)) return;
  const lines = readFileSync(target, 'utf8').split('\n');
  const index = findH1Line(lines);

  if (index === -1) return;
  const currentLine = lines[index];

  if (currentLine === undefined) return;
  const heading = `# ${title}`;

  if (currentLine === heading) return;
  lines[index] = heading;
  atomicWriteFileSync(target, lines.join('\n'));
};

/**
 * The body of a quoted string literal, for the pattern `literalPattern` builds
 * around it, whose group 2 is the opening quote.
 *
 * `(?!\2)` excludes only the quote the match actually opened with, so a
 * single-quoted literal may hold a bare `"` and a double-quoted one a bare `'`.
 * A class naming both quotes refuses `"Steve's Template"` outright, and a
 * pattern that cannot match is a rewrite that silently does not happen. It
 * cannot re-match this command's own output either: the escaper leaves the
 * non-wrapping quote bare, because it needs no escape, so a title carrying one
 * survives the first rename and then defeats the second.
 *
 * `\n` stays excluded because a JavaScript string literal cannot span a raw
 * line ending. Bounding the body to one line is what keeps a quote further down
 * the file from being read as this literal's closing one, now that the class no
 * longer stops at the other quote character.
 */
const LITERAL_BODY = String.raw`(?:(?!\2)[^\n\\]|\\.)*`;

type LanguageFile = {
  file: string;
  keys: readonly RewriteKey[];
};

/**
 * One rewritable identity key.
 *
 * `prefix` is everything up to the opening quote and carries **no capturing
 * group of its own**: `literalPattern` wraps it in group 1 and opens group 2 for
 * the quote, so both indices `LITERAL_BODY` and the replacer depend on are fixed
 * where the pattern is composed rather than by whoever authored the prefix.
 *
 * `global` is whether the key is rewritten everywhere it appears or only at its
 * first match, which is the one regex flag that varies across the table.
 */
type RewriteKey = {
  global: boolean;
  prefix: string;
};

const flagsFor = (key: RewriteKey): string => (key.global ? 'gmu' : 'mu');

/** The whole property: prefix, opening quote, body, matching close quote. */
const literalPattern = (key: RewriteKey): RegExp =>
  new RegExp(String.raw`(${key.prefix})(['"])${LITERAL_BODY}\2`, flagsFor(key));

/**
 * `source` with `newValue` written into every value `key` matches.
 *
 * A **function** replacement, which is what makes the title safe to splice: in
 * a replacement *string* `$1` and `$&` are match references, so a title
 * carrying one injects part of the file into itself. A backslash does not
 * neutralize them, only `$$` does, so the escape this replaced looked like a
 * guard and was inert. A function receives the value verbatim and interprets
 * nothing.
 *
 * The value is then escaped for the quote the match found, so an ordinary
 * `Steve's App` cannot close the literal early. Both halves are needed: the
 * function form fixes `$`, the escape fixes the quote.
 */
const applyRewrite = (
  source: string,
  key: RewriteKey,
  newValue: string
): string =>
  source.replace(
    literalPattern(key),
    // `literalPattern` captures the quote as `(['"])`, so group 2 is one of the
    // two by construction, which is what the narrower type records.
    (_match: string, prefix: string, quote: JsLiteralQuote) =>
      `${prefix}${quote}${escapeJsLiteralValue(newValue, quote)}${quote}`
  );

/** A key whose value is the title wherever in the file it appears. */
const unscopedKey = (key: string): RewriteKey => ({
  global: true,
  prefix: String.raw`\b${key}\s*:\s*`,
});

/**
 * A key indented at the file's top object level (a single indentation unit).
 * Nested keys with the same name (e.g. a `title` inside a deeper route object)
 * are left untouched so a user-diverged file is preserved.
 */
const topLevelKey = (key: string): RewriteKey => ({
  global: true,
  prefix: String.raw`^\x20\x20${key}\s*:\s*`,
});

/**
 * The `title` nested directly inside the top-level `meta: { … }` block: the
 * block opened at the top object level, then the first `title:` within it
 * before the block closes. Scoped so other `title` keys are untouched.
 */
const META_TITLE_KEY: RewriteKey = {
  global: false,
  prefix: String.raw`^\x20\x20meta\s*:\s*\{[^}]*?\btitle\s*:\s*`,
};

/**
 * Every identity key this step rewrites, grouped by the file carrying it.
 *
 * `common.ts` carries a single identity-bearing key. Other `*Name` properties
 * exist there (form labels) but no second `siteName`, so an unscoped rewrite is
 * safe. `_index.ts` has three, each scoped to the precise location it occupies:
 * a global `title` rewrite would clobber `title` keys in extra routes a user
 * may have added, which is data loss on a diverged file.
 *
 * Every key is optional. The shipped `_index.ts` carries only `meta.title`, so
 * a file missing the others is a clean pass.
 */
const LANGUAGE_FILES: readonly LanguageFile[] = [
  {file: COMMON_TS, keys: [unscopedKey('siteName')]},
  {
    file: INDEX_PAGE_TS,
    keys: [topLevelKey('heroTitle'), topLevelKey('title'), META_TITLE_KEY],
  },
];

const renameLanguageFile = (
  cwd: string,
  {file, keys}: LanguageFile,
  title: string
): void => {
  const target = path.join(cwd, file);

  if (!existsSync(target)) return;
  const original = readFileSync(target, 'utf8');
  const next = keys.reduce(
    (source, key) => applyRewrite(source, key, title),
    original
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
  const [first] = argv;

  if (first !== undefined && HELP_TOKENS.has(first)) {
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
    // Ahead of every write: a knowable precondition should not fail the run
    // with package.json already renamed.
    if (!claudeMdPreconditionMet(cwd)) {
      structuredError({
        code: 'claude_md_heading_missing',
        message:
          'CLAUDE.md has no top-level "# " heading to rewrite; add one above any fenced code block and re-run',
        subcommand: 'init rename',
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }
    renamePackageJson(cwd, parsed.flags.kebab);
    renameClaudeMd(cwd, parsed.flags.title);

    for (const languageFile of LANGUAGE_FILES) {
      renameLanguageFile(cwd, languageFile, parsed.flags.title);
    }
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
