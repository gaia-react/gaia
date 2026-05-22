/**
 * `gaia wiki log-prepend --sha <h> --decision <WORTHY|SKIP|RE_ANCHOR> --reason "..."` handler.
 *
 * Prepends a single canonical line to `wiki/log.md` immediately after the
 * frontmatter block. Replaces the prose recipe in `wiki/sync.md` Step 5
 * and the manual re-anchor write in `wiki/sync.md` Step 1.
 *
 * Line shape:
 *
 *   - <YYYY-MM-DD> <sha> <decision> — <reason>
 *
 * Date is today (UTC). Newest entries land at the top under the same
 * `## [Unreleased]` heading the log already uses; we insert immediately
 * after the heading line if present, otherwise after the closing `---`
 * frontmatter fence.
 *
 * Decisions:
 *   - WORTHY    — sync evaluated this commit and wiki was updated.
 *   - SKIP      — sync evaluated this commit and decided no wiki change.
 *   - RE_ANCHOR — sync re-anchored state after a history rewrite (rebase/squash).
 */
import {existsSync, readFileSync, renameSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from './util/git.js';

const HELP_TEXT = `Usage: gaia wiki log-prepend --sha <h> --decision <WORTHY|SKIP|RE_ANCHOR> --reason "..."

  Prepends one canonical line to wiki/log.md after the frontmatter.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const VALID_DECISIONS = new Set(['RE_ANCHOR', 'SKIP', 'WORTHY']);
const FRONTMATTER_FENCE = '---';

type ParsedFlags = {
  decision: string;
  reason: string;
  sha: string;
};

type FlagParseSuccess = {
  flags: ParsedFlags;
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

  if (value === undefined) {
    return {message: `${flag} requires a value`, ok: false};
  }

  return {ok: true, value};
};

const parseFlags = (argv: readonly string[]): FlagParseResult => {
  let sha: string | undefined;
  let decision: string | undefined;
  let reason: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string;

    if (token === '--sha') {
      const taken = takeValue(argv, index + 1, '--sha');

      if (!taken.ok) return taken;
      sha = taken.value;
      index += 1;
      continue;
    }

    if (token === '--decision') {
      const taken = takeValue(argv, index + 1, '--decision');

      if (!taken.ok) return taken;
      decision = taken.value;
      index += 1;
      continue;
    }

    if (token === '--reason') {
      const taken = takeValue(argv, index + 1, '--reason');

      if (!taken.ok) return taken;
      reason = taken.value;
      index += 1;
      continue;
    }

    return {message: `unknown flag: ${token}`, ok: false};
  }

  if (sha === undefined) return {message: '--sha is required', ok: false};
  if (decision === undefined)
    return {message: '--decision is required', ok: false};
  if (reason === undefined) return {message: '--reason is required', ok: false};

  if (!VALID_DECISIONS.has(decision)) {
    return {
      message: `--decision must be WORTHY, SKIP, or RE_ANCHOR (got: "${decision}")`,
      ok: false,
    };
  }

  return {flags: {decision, reason, sha}, ok: true};
};

const todayUtc = (): string => {
  const now = new Date();
  const year = now.getUTCFullYear();
  const month = String(now.getUTCMonth() + 1).padStart(2, '0');
  const day = String(now.getUTCDate()).padStart(2, '0');

  return `${year}-${month}-${day}`;
};

type FrontmatterScan =
  | {kind: 'malformed'}
  | {kind: 'missing'}
  | {endLineIndex: number; kind: 'present'};

const scanFrontmatter = (lines: readonly string[]): FrontmatterScan => {
  if ((lines[0] ?? '').trim() !== FRONTMATTER_FENCE) {
    return {kind: 'missing'};
  }

  for (let index = 1; index < lines.length; index += 1) {
    if ((lines[index] ?? '').trim() === FRONTMATTER_FENCE) {
      return {endLineIndex: index, kind: 'present'};
    }
  }

  return {kind: 'malformed'};
};

const findInsertionIndex = (
  lines: readonly string[],
  endFenceIndex: number
): number => {
  // Insert immediately after the `## [Unreleased]` (or first H2 heading)
  // when present; otherwise insert immediately after the closing fence
  // plus any leading blank lines + the H1 heading.
  for (let index = endFenceIndex + 1; index < lines.length; index += 1) {
    const line = (lines[index] ?? '').trim();

    if (line.startsWith('## ')) {
      // Insert after this heading; skip a single trailing blank line if
      // present so the new entry sits flush under the heading.
      const candidate = index + 1;
      const after = (lines[candidate] ?? '').trim();

      if (after === '') return candidate + 1;

      return candidate;
    }
  }

  // No `##` heading found. Insert immediately after the closing fence.
  return endFenceIndex + 1;
};

type RunOptions = {
  cwd?: string;
  /** Override "today" for deterministic tests. ISO-8601 UTC date string. */
  today?: string;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  if (argv.length === 0) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const first = argv[0] as string;

  if (HELP_TOKENS.has(first)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const parsed = parseFlags(argv);

  if (!parsed.ok) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.message,
      subcommand: 'wiki log-prepend',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: 'gaia wiki log-prepend must run inside a git repository',
      subcommand: 'wiki log-prepend',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const logPath = path.join(repoRoot, 'wiki', 'log.md');

  if (!existsSync(logPath)) {
    structuredError({
      code: 'log_missing',
      message: 'wiki/log.md does not exist',
      subcommand: 'wiki log-prepend',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const raw = readFileSync(logPath, 'utf8');
  const lines = raw.split('\n');
  const scan = scanFrontmatter(lines);

  if (scan.kind === 'missing' || scan.kind === 'malformed') {
    structuredError({
      code: 'frontmatter_invalid',
      message: 'wiki/log.md frontmatter is missing or malformed',
      subcommand: 'wiki log-prepend',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const date = options.today ?? todayUtc();
  const newLine = `- ${date} ${parsed.flags.sha} ${parsed.flags.decision} — ${parsed.flags.reason}`;
  const insertionIndex = findInsertionIndex(lines, scan.endLineIndex);
  const next = [
    ...lines.slice(0, insertionIndex),
    newLine,
    ...lines.slice(insertionIndex),
  ].join('\n');

  const tmpPath = `${logPath}.tmp`;
  writeFileSync(tmpPath, next, 'utf8');
  renameSync(tmpPath, logPath);

  return EXIT_CODES.OK;
};
