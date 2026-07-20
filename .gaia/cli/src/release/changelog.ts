/**
 * `gaia-maintainer release changelog [--draft]` handler.
 *
 * Step 7 of the maintainer release runbook. Auto-drafts a Keep-a-Changelog
 * block from conventional-commit subjects since the last tag, mapping
 * each commit type to a section heading. With `--draft`, prints the
 * rendered block to stdout (the runbook copies into `CHANGELOG.md`
 * after human edit). Without `--draft`, the rendered block is graduated
 * into `CHANGELOG.md`:
 *
 *   1. Find `## [Unreleased]`. Replace with `## [X.Y.Z] - YYYY-MM-DD`.
 *   2. Insert a fresh empty `## [Unreleased]` section above.
 *   3. Place the rendered block under the new dated heading.
 *   4. Maintain the Keep-a-Changelog reference-link block: repoint the
 *      `[Unreleased]` compare link at the new version and add a `[X.Y.Z]`
 *      release-tag definition. Skipped when the file has no link block.
 *
 * Idempotent: re-running with the same `--version` is a no-op once the
 * version block already exists.
 */
import {spawnSync} from 'node:child_process';
import type {SpawnSyncReturns} from 'node:child_process';
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import {
  isCommitType,
  parseConventionalCommitHeader,
} from '../util/conventional-commit.js';
import type {CommitType} from '../util/conventional-commit.js';

const HELP_TEXT = `Usage: gaia-maintainer release changelog [--draft] [--version <X.Y.Z>]

  Render a Keep-a-Changelog block for the new version from
  conventional-commit subjects since the last tag.

  Flags:
    --draft               Print the rendered block to stdout, do not write.
    --version <X.Y.Z>     Override the new version (default: package.json).

  Exit codes:
    0  success
    1  user-correctable error
    2  unexpected (git failure)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const UNEXPECTED_EXIT = 2;

export type CommandRunner = (
  command: string,
  args: readonly string[],
  options: {cwd: string}
) => SpawnSyncReturns<string>;

export const defaultRunner: CommandRunner = (command, args, options) =>
  spawnSync(command, args as string[], {
    cwd: options.cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });

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
  draft: boolean;
  version: string | undefined;
};

const takeValue = (
  argv: readonly string[],
  index: number,
  flag: string
): {message: string; ok: false} | {ok: true; value: string} => {
  // `.at()` (unlike bracket indexing) types its result `string | undefined`,
  // which honestly reflects that `index` can run past the end of argv.
  const value = argv.at(index);

  if (value === undefined)
    return {message: `${flag} requires a value`, ok: false};

  return {ok: true, value};
};

const parseFlags = (argv: readonly string[]): FlagParseResult => {
  let draft = false;
  let version: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--draft') {
      draft = true;
    } else if (token === '--version') {
      const taken = takeValue(argv, index + 1, '--version');

      if (!taken.ok) return taken;
      version = taken.value;
      index += 1;
    } else {
      return {message: `unknown flag: ${token}`, ok: false};
    }
  }

  return {flags: {draft, version}, ok: true};
};

type Section = 'Added' | 'Changed' | 'Fixed';

/**
 * Which CHANGELOG section each declared commit type lands in, or `null` for
 * types the changelog does not narrate.
 *
 * Keyed by `CommitType`, so a type added to the vocabulary in
 * `util/conventional-commit.ts` fails to compile here until it gets a section.
 * The scope segment is discarded: the message text is entirely carried by the
 * parsed header's `rest`.
 */
const TYPE_TO_SECTION: Record<CommitType, null | Section> = {
  build: null,
  chore: null,
  ci: null,
  debt: 'Fixed',
  docs: 'Changed',
  feat: 'Added',
  fix: 'Fixed',
  perf: 'Changed',
  refactor: 'Changed',
  style: null,
  test: null,
  wiki: null,
};

export type Commit = {
  body: string;
  subject: string;
};

export type RenderedSections = Record<Section, string[]>;

export const groupCommits = (commits: readonly Commit[]): RenderedSections => {
  const sections: RenderedSections = {Added: [], Changed: [], Fixed: []};

  for (const commit of commits) {
    const header = parseConventionalCommitHeader(commit.subject);

    if (header !== undefined && isCommitType(header.type)) {
      const target = TYPE_TO_SECTION[header.type];

      if (target && header.rest.length > 0) {
        sections[target].push(header.rest);
      }
    }
  }

  return sections;
};

const todayUtc = (now: Date = new Date()): string => {
  const year = now.getUTCFullYear();
  const month = String(now.getUTCMonth() + 1).padStart(2, '0');
  const day = String(now.getUTCDate()).padStart(2, '0');

  return `${year}-${month}-${day}`;
};

export const renderBlock = (sections: RenderedSections): string => {
  const lines: string[] = [];
  const order: Section[] = ['Added', 'Changed', 'Fixed'];

  for (const section of order) {
    const items = sections[section];

    if (items.length > 0) {
      lines.push(`### ${section}`, '');

      for (const item of items) lines.push(`- ${item}`);
      lines.push('');
    }
  }

  // Collapse a run of trailing newlines to exactly one, without a
  // backtracking-prone `\n+$` regex.
  let joined = lines.join('\n');

  while (joined.endsWith('\n\n')) joined = joined.slice(0, -1);

  return joined;
};

const RECORD_SEPARATOR = '---END-COMMIT---';

export const collectCommits = (
  cwd: string,
  runner: CommandRunner,
  range: string
): Commit[] => {
  const result = runner(
    'git',
    ['log', '--no-merges', `--format=%s%n%b%n${RECORD_SEPARATOR}`, range],
    {cwd}
  );

  if (result.error !== undefined) {
    throw new Error(`git log failed: ${result.error.message}`);
  }

  if ((result.status ?? -1) !== 0) {
    const stderr = result.stderr.trim();

    throw new Error(`git log exited ${result.status ?? -1}: ${stderr}`);
  }

  const out = result.stdout;
  const commits: Commit[] = [];

  for (const chunk of out.split(RECORD_SEPARATOR)) {
    const trimmed = chunk.trim();

    if (trimmed !== '') {
      const lines = trimmed.split('\n');
      const subject = lines[0] ?? '';
      const body = lines.slice(1).join('\n');
      commits.push({body, subject});
    }
  }

  return commits;
};

const lastTag = (cwd: string, runner: CommandRunner): null | string => {
  const result = runner('git', ['describe', '--tags', '--abbrev=0'], {cwd});

  if (result.error !== undefined) return null;
  if ((result.status ?? -1) !== 0) return null;
  const out = result.stdout.trim();

  if (out.length === 0) return null;

  return out;
};

const readVersion = (cwd: string, override: string | undefined): string => {
  if (override !== undefined && override.length > 0) return override;
  const target = path.join(cwd, 'package.json');

  if (!existsSync(target)) {
    throw new Error('package.json not found at repo root');
  }
  const parsed = JSON.parse(readFileSync(target, 'utf8')) as {
    version?: unknown;
  };

  if (typeof parsed.version !== 'string') {
    throw new TypeError('package.json has no string "version"');
  }

  return parsed.version;
};

const UNRELEASED_HEADING = '## [Unreleased]';

type GraduateOutcome =
  {kind: 'duplicate'} | {kind: 'no-unreleased'} | {kind: 'ok'; updated: string};

const UNRELEASED_REF_PREFIX = '[Unreleased]:';

/**
 * Maintain the Keep-a-Changelog reference-link block on graduation: repoint the
 * `[Unreleased]` compare link at the just-released version and insert a
 * `[X.Y.Z]` release-tag definition beneath it. The repo base URL is derived
 * from the existing `[Unreleased]:` target, never hardcoded; a CHANGELOG with
 * no link block (or an unrecognized `[Unreleased]` target) is left untouched.
 */
const updateLinkReferences = (body: string, newVersion: string): string => {
  const lines = body.split('\n');
  const refIndex = lines.findIndex((line) =>
    line.startsWith(UNRELEASED_REF_PREFIX)
  );

  if (refIndex === -1) {
    return body;
  }

  const target = (lines[refIndex] ?? '')
    .slice(UNRELEASED_REF_PREFIX.length)
    .trim();
  const compareIndex = target.indexOf('/compare/');

  if (compareIndex === -1) {
    return body;
  }

  const baseUrl = target.slice(0, compareIndex);

  lines.splice(
    refIndex,
    1,
    `${UNRELEASED_REF_PREFIX} ${baseUrl}/compare/v${newVersion}...HEAD`,
    `[${newVersion}]: ${baseUrl}/releases/tag/v${newVersion}`
  );

  return lines.join('\n');
};

type GraduateChangelogArgs = {
  block: string;
  current: string;
  newVersion: string;
  today: string;
};

export const graduateChangelog = ({
  block,
  current,
  newVersion,
  today,
}: GraduateChangelogArgs): GraduateOutcome => {
  const versionHeading = `## [${newVersion}] - ${today}`;

  if (current.includes(`## [${newVersion}]`)) {
    return {kind: 'duplicate'};
  }

  const lines = current.split('\n');
  const unreleasedIndex = lines.findIndex(
    (line) => line.trim() === UNRELEASED_HEADING
  );

  if (unreleasedIndex === -1) {
    return {kind: 'no-unreleased'};
  }

  // Replace the Unreleased heading with the dated heading and insert a
  // fresh Unreleased section above. Result:
  //
  //   ## [Unreleased]
  //
  //   ## [vX.Y.Z] - DATE
  //   <block>
  const blockLines = block.split('\n');

  // Trim leading/trailing blanks from blockLines for predictable spacing.
  while (blockLines.length > 0 && (blockLines[0] ?? '').trim() === '') {
    blockLines.shift();
  }

  while (blockLines.length > 0 && (blockLines.at(-1) ?? '').trim() === '') {
    blockLines.pop();
  }

  const newSection = [
    UNRELEASED_HEADING,
    '',
    versionHeading,
    '',
    ...blockLines,
    '',
  ];

  const head = lines.slice(0, unreleasedIndex);
  const tail = lines.slice(unreleasedIndex + 1);

  // Strip a single blank line right after the original Unreleased
  // heading so we don't double-up after replacement.
  while (tail.length > 0 && (tail[0] ?? '').trim() === '') {
    tail.shift();
  }

  const graduated = [...head, ...newSection, ...tail].join('\n');
  const updated = updateLinkReferences(graduated, newVersion);

  return {kind: 'ok', updated};
};

type RunOptions = {
  cwd?: string;
  runner?: CommandRunner;
  /** Override "today" for deterministic tests. ISO-8601 UTC date. */
  today?: string;
};

// Each `tryX` helper below owns one step's try/catch and error reporting, so
// `run` reads as a flat sequence of "did this step succeed?" checks instead
// of nested try/catch blocks.

const tryReadVersionOrReport = (
  cwd: string,
  override: string | undefined
): null | string => {
  try {
    return readVersion(cwd, override);
  } catch (error) {
    structuredError({
      code: 'package_json_invalid',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'release changelog',
    });

    return null;
  }
};

const tryCollectCommitsOrReport = (
  cwd: string,
  runner: CommandRunner,
  range: string
): Commit[] | null => {
  try {
    return collectCommits(cwd, runner, range);
  } catch (error) {
    process.stderr.write(
      `changelog: ${error instanceof Error ? error.message : String(error)}\n`
    );

    return null;
  }
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
      subcommand: 'release changelog',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const runner = options.runner ?? defaultRunner;

  const version = tryReadVersionOrReport(cwd, parsed.flags.version);

  if (version === null) return EXIT_CODES.UNKNOWN_SUBCOMMAND;

  const tag = lastTag(cwd, runner);
  const range = tag === null ? 'HEAD' : `${tag}..HEAD`;

  const commits = tryCollectCommitsOrReport(cwd, runner, range);

  if (commits === null) return UNEXPECTED_EXIT;

  const sections = groupCommits(commits);
  const block = renderBlock(sections);

  if (parsed.flags.draft) {
    process.stdout.write(block);

    return EXIT_CODES.OK;
  }

  const changelogPath = path.join(cwd, 'CHANGELOG.md');

  if (!existsSync(changelogPath)) {
    structuredError({
      code: 'changelog_missing',
      message: 'CHANGELOG.md not found at repo root',
      subcommand: 'release changelog',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const current = readFileSync(changelogPath, 'utf8');
  const today = options.today ?? todayUtc();
  const outcome = graduateChangelog({
    block,
    current,
    newVersion: version,
    today,
  });

  if (outcome.kind === 'duplicate') {
    // Idempotent: nothing to do.
    return EXIT_CODES.OK;
  }

  if (outcome.kind === 'no-unreleased') {
    structuredError({
      code: 'no_unreleased_section',
      message: 'CHANGELOG.md has no `## [Unreleased]` heading to graduate',
      subcommand: 'release changelog',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  try {
    atomicWriteFileSync(changelogPath, outcome.updated);
  } catch (error) {
    structuredError({
      code: 'changelog_write_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'release changelog',
    });

    return UNEXPECTED_EXIT;
  }

  return EXIT_CODES.OK;
};
