/**
 * `gaia residue-cursor show | advance --token T | clear`
 *
 * The resumable per-run cursor (RD-005): `advance` records the coordinate the
 * skill just confirmed a disposition for, so a later `residue-tally` run
 * resumes after it rather than re-emitting it. `advance` only ever accepts a
 * token this tally itself minted: `decodeToken` re-validates the decoded path
 * and line, so a hand-forged or path-traversal token is refused rather than
 * written to disk.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../util/repo-root.js';
import {clearCursor, readCursor, writeCursor} from './cache.js';
import {decodeToken, encodeToken} from './token.js';

const HELP_TEXT = `Usage: gaia residue-cursor <show|advance|clear> [args]

  show                Print the recorded cursor as JSON (including its own
                       token), or "null" when none is recorded.
  advance --token T    Record T's decoded coordinate as the cursor.
  clear                Remove the cursor file.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type RunOptions = {cwd?: string};

const resolveRoot = (cwd: string): string => {
  try {
    return resolveRepoRoot(cwd);
  } catch {
    return cwd;
  }
};

const handleShow = (repoRoot: string): number => {
  const cursor = readCursor(repoRoot);

  if (cursor === null) {
    process.stdout.write('null\n');

    return EXIT_CODES.OK;
  }

  process.stdout.write(
    `${JSON.stringify({...cursor, token: encodeToken(cursor)})}\n`
  );

  return EXIT_CODES.OK;
};

const handleAdvance = (argv: readonly string[], repoRoot: string): number => {
  let token: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--token') {
      token = argv[index + 1];
      index += 1;
    }
  }

  if (token === undefined) {
    structuredError({
      code: 'invalid_arguments',
      message: 'residue-cursor advance requires --token T',
      subcommand: 'residue-cursor advance',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const decoded = decodeToken(token);

  if (!decoded.ok) {
    structuredError({
      code: 'invalid_token',
      message: decoded.reason,
      subcommand: 'residue-cursor advance',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  writeCursor(repoRoot, decoded.value);

  return EXIT_CODES.OK;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  const [sub, ...rest] = argv;
  const repoRoot = resolveRoot(options.cwd ?? process.cwd());

  if (sub === undefined || HELP_TOKENS.has(sub)) {
    process.stdout.write(HELP_TEXT);

    return sub === undefined ? EXIT_CODES.UNKNOWN_SUBCOMMAND : EXIT_CODES.OK;
  }

  if (sub === 'show') return handleShow(repoRoot);
  if (sub === 'advance') return handleAdvance(rest, repoRoot);

  if (sub === 'clear') {
    clearCursor(repoRoot);

    return EXIT_CODES.OK;
  }

  structuredError({
    code: 'unknown_subcommand',
    message: `unknown residue-cursor subcommand: ${sub}`,
    subcommand: 'residue-cursor',
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};
