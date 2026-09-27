/**
 * `gaia harden-ledger snapshot record`
 *
 * A completed `/gaia-harden` review records what it reviewed so the
 * `/gaia-harden` statusline nudge can stay silent until something changes.
 * `record` builds the snapshot from a saved `harden-tally` JSON and writes
 * it, unconditionally overwriting whatever snapshot came before; it never
 * reads the prior snapshot, so a malformed one is simply replaced rather
 * than blocking the next completed review.
 *
 * A `gh_ok: false` tally, an unparseable file, or a pre-SPEC tally lacking
 * the new keys is refused with a named exit code and no write: a snapshot
 * built from a failed window read would silence the nudge on a reading
 * nobody made.
 *
 * Snapshot file: `.gaia/local/harden/reviewed.json` (gitignored). Schema and
 * atomic writer in `schemas/review-snapshot.ts`.
 */
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {
  ReviewTallyInputSchema,
  snapshotFromTally,
  writeReviewSnapshot,
} from '../schemas/review-snapshot.js';
import {summarizeZodError} from '../schemas/zod-error.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../util/repo-root.js';

const HELP_TEXT = `Usage: gaia harden-ledger snapshot record [args]

  record --tally-file <path>
    Build a review snapshot from a saved harden-tally JSON file and write it,
    overwriting any existing snapshot unconditionally.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type RunOptions = {
  cwd?: string;
  now?: () => Date;
};

const resolveRoot = (
  options: RunOptions,
  subcommand: string
): null | string => {
  try {
    return resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: `gaia harden-ledger ${subcommand} must run inside a git repository`,
      subcommand: `harden-ledger ${subcommand}`,
    });

    return null;
  }
};

// --- record ----------------------------------------------------------------

const parseRecordArgs = (
  argv: readonly string[]
): {error: string} | {value: {tallyFile: string}} => {
  let tallyFile: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--tally-file') {
      tallyFile = argv[index + 1];
      index += 1;
    } else {
      return {error: `unknown argument: ${token}`};
    }
  }

  if (tallyFile === undefined || tallyFile === '') {
    return {error: 'snapshot record requires --tally-file <path>'};
  }

  return {value: {tallyFile}};
};

const handleRecord = (argv: readonly string[], options: RunOptions): number => {
  const parsed = parseRecordArgs(argv);

  if ('error' in parsed) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.error,
      subcommand: 'harden-ledger snapshot record',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const tallyPath = path.resolve(
    options.cwd ?? process.cwd(),
    parsed.value.tallyFile
  );

  const repoRoot = resolveRoot(options, 'snapshot record');

  if (repoRoot === null) return EXIT_CODES.STORAGE_INACCESSIBLE;

  let raw: string;

  try {
    raw = readFileSync(tallyPath, 'utf8');
  } catch (error) {
    structuredError({
      code: 'tally_file_unreadable',
      message: `${tallyPath}: ${error instanceof Error ? error.message : String(error)}`,
      subcommand: 'harden-ledger snapshot record',
    });

    return EXIT_CODES.STORAGE_INACCESSIBLE;
  }

  let parsedJson: unknown;

  try {
    parsedJson = JSON.parse(raw);
  } catch (error) {
    structuredError({
      code: 'malformed_tally',
      message: `${tallyPath}: invalid JSON: ${error instanceof Error ? error.message : String(error)}`,
      subcommand: 'harden-ledger snapshot record',
    });

    return EXIT_CODES.PAYLOAD_VALIDATION_FAILED;
  }

  const result = ReviewTallyInputSchema.safeParse(parsedJson);

  if (!result.success) {
    structuredError({
      code: 'malformed_tally',
      message: summarizeZodError(tallyPath, result.error),
      subcommand: 'harden-ledger snapshot record',
    });

    return EXIT_CODES.PAYLOAD_VALIDATION_FAILED;
  }

  if (!result.data.gh_ok) {
    structuredError({
      code: 'tally_gh_not_ok',
      message: `${tallyPath}: gh_ok is false, refusing to snapshot a failed window read`,
      subcommand: 'harden-ledger snapshot record',
    });

    return EXIT_CODES.PAYLOAD_VALIDATION_FAILED;
  }

  const now = options.now ?? (() => new Date());

  writeReviewSnapshot(repoRoot, snapshotFromTally(result.data, now()));

  return EXIT_CODES.OK;
};

// --- dispatch ----------------------------------------------------------------

export const runSnapshot = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  const [sub, ...rest] = argv;

  if (sub === undefined || HELP_TOKENS.has(sub)) {
    process.stdout.write(HELP_TEXT);

    return sub === undefined ? EXIT_CODES.UNKNOWN_SUBCOMMAND : EXIT_CODES.OK;
  }

  if (sub === 'record') return handleRecord(rest, options);

  structuredError({
    code: 'unknown_subcommand',
    message: `unknown harden-ledger snapshot subcommand: ${sub}`,
    subcommand: 'harden-ledger snapshot',
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};
