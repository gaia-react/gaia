/**
 * `gaia-maintainer release exclude-regex` handler.
 *
 * The single compiler of `.gaia/release-exclude` into the anchored-regex file
 * every executable release surface feeds to `grep -vE -f`. Emits one
 * `^<escaped>(/|$)` per non-comment/non-blank line to stdout, byte-identical to
 * the retired `awk | sed | awk` pipeline; the empty exclude list yields zero
 * bytes. Fail-closed: a metacharacter/indentation offender or an unreadable
 * source exits nonzero, never an empty "exclude nothing" stdout on error.
 */
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {
  renderExcludeRegex,
  resolveExcludePath,
  resolveRepoRoot,
  validateExcludeText,
} from './manifest.js';

const HELP_TEXT = `Usage: gaia-maintainer release exclude-regex [--exclude-file <path>]

  Compile .gaia/release-exclude into the anchored-regex file the release
  staging filter feeds to \`grep -vE -f\`. One \`^<escaped>(/|$)\` per
  non-comment/non-blank line to stdout; empty exclude list yields zero bytes.

  Flags:
    --exclude-file <path>   Read from <path> instead of <repo>/.gaia/release-exclude.

  Exit codes:
    0  success
    1  invalid arguments, or a non-literal-path offender (glob/regex
       metacharacter or indentation) in the exclude source
    2  unexpected (exclude source unreadable / IO error)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const UNEXPECTED_EXIT = 2;

type ArgsParseFailure = {
  message: string;
  ok: false;
};

type ArgsParseResult = ArgsParseFailure | ArgsParseSuccess;

type ArgsParseSuccess = {
  excludeFile: string | undefined;
  ok: true;
};

const parseArgs = (argv: readonly string[]): ArgsParseResult => {
  let excludeFile: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token !== '--exclude-file') {
      return {message: `unknown flag: ${token}`, ok: false};
    }

    const value = argv.at(index + 1);

    if (value === undefined) {
      return {message: '--exclude-file requires a value', ok: false};
    }
    excludeFile = value;
    index += 1;
  }

  return {excludeFile, ok: true};
};

export const run = (
  argv: readonly string[],
  options: {cwd?: string} = {}
): number => {
  if (argv.length > 0 && HELP_TOKENS.has(argv[0])) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const parsed = parseArgs(argv);

  if (!parsed.ok) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.message,
      subcommand: 'release exclude-regex',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const {excludeFile} = parsed;
  let text: string;

  try {
    const source =
      excludeFile === undefined ? resolveExcludePath(resolveRepoRoot(cwd))
      : path.isAbsolute(excludeFile) ? excludeFile
      : path.join(cwd, excludeFile);
    text = readFileSync(source, 'utf8');
  } catch (error) {
    structuredError({
      code: 'exclude_read_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'release exclude-regex',
    });

    return UNEXPECTED_EXIT;
  }

  try {
    validateExcludeText(text);
  } catch (error) {
    structuredError({
      code: 'exclude_compile_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'release exclude-regex',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  process.stdout.write(renderExcludeRegex(text));

  return EXIT_CODES.OK;
};
