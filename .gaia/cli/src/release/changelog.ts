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
 *   1. Find `## [Unreleased]`. Replace with `## [vX.Y.Z] — YYYY-MM-DD`.
 *   2. Insert a fresh empty `## [Unreleased]` section above.
 *   3. Place the rendered block under the new dated heading.
 *
 * Idempotent: re-running with the same `--version` is a no-op once the
 * version block already exists.
 */
import {type SpawnSyncReturns, spawnSync} from 'node:child_process';
import {existsSync, readFileSync} from 'node:fs';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';

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

type Flags = {
  draft: boolean;
  version: string | undefined;
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
  let draft = false;
  let version: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string;

    if (token === '--draft') {
      draft = true;
      continue;
    }

    if (token === '--version') {
      const taken = takeValue(argv, index + 1, '--version');

      if (!taken.ok) return taken;
      version = taken.value;
      index += 1;
      continue;
    }

    return {message: `unknown flag: ${token}`, ok: false};
  }

  return {flags: {draft, version}, ok: true};
};

type Section = 'Added' | 'Changed' | 'Fixed';

const TYPE_TO_SECTION: Record<string, Section | null> = {
  chore: null,
  ci: null,
  docs: 'Changed',
  feat: 'Added',
  fix: 'Fixed',
  perf: 'Changed',
  refactor: 'Changed',
  style: null,
  test: null,
};

const CONVENTIONAL_HEADER_REGEX =
  /^(?<type>[a-z]+)(?:\((?<scope>[^)]*)\))?!?:\s*(?<rest>.*)$/u;

export type Commit = {
  body: string;
  subject: string;
};

export type RenderedSections = Record<Section, string[]>;

export const groupCommits = (commits: readonly Commit[]): RenderedSections => {
  const sections: RenderedSections = {Added: [], Changed: [], Fixed: []};

  for (const commit of commits) {
    const subject = commit.subject.trim();
    const match = CONVENTIONAL_HEADER_REGEX.exec(subject);

    if (match === null) continue;
    const groups = match.groups ?? {};
    const type = (groups.type ?? '').toLowerCase();
    const target = TYPE_TO_SECTION[type];

    if (!target) continue;
    const message = (groups.rest ?? '').trim();

    if (message.length === 0) continue;
    sections[target].push(message);
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

    if (items.length === 0) continue;
    lines.push(`### ${section}`, '');

    for (const item of items) lines.push(`- ${item}`);
    lines.push('');
  }

  return lines.join('\n').replace(/\n+$/u, '\n');
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
    const stderr = (result.stderr ?? '').trim();
    throw new Error(`git log exited ${result.status ?? -1}: ${stderr}`);
  }

  const out = result.stdout ?? '';
  const commits: Commit[] = [];

  for (const chunk of out.split(RECORD_SEPARATOR)) {
    const trimmed = chunk.replace(/^[\s\n]+/u, '').replace(/[\s\n]+$/u, '');

    if (trimmed === '') continue;
    const lines = trimmed.split('\n');
    const subject = lines[0] ?? '';
    const body = lines.slice(1).join('\n');
    commits.push({body, subject});
  }

  return commits;
};

const lastTag = (cwd: string, runner: CommandRunner): string | null => {
  const result = runner('git', ['describe', '--tags', '--abbrev=0'], {cwd});

  if (result.error !== undefined) return null;
  if ((result.status ?? -1) !== 0) return null;
  const out = (result.stdout ?? '').trim();

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
    throw new Error('package.json has no string "version"');
  }

  return parsed.version;
};

const UNRELEASED_HEADING = '## [Unreleased]';

type GraduateOutcome =
  | {kind: 'duplicate'}
  | {kind: 'no-unreleased'}
  | {kind: 'ok'; updated: string};

export const graduateChangelog = (
  current: string,
  newVersion: string,
  block: string,
  today: string
): GraduateOutcome => {
  const versionHeading = `## [${newVersion}] — ${today}`;

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
  //   ## [vX.Y.Z] — DATE
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

  const updated = [...head, ...newSection, ...tail].join('\n');

  return {kind: 'ok', updated};
};

type RunOptions = {
  cwd?: string;
  runner?: CommandRunner;
  /** Override "today" for deterministic tests. ISO-8601 UTC date. */
  today?: string;
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
      subcommand: 'release changelog',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const runner = options.runner ?? defaultRunner;

  let version: string;

  try {
    version = readVersion(cwd, parsed.flags.version);
  } catch (error) {
    structuredError({
      code: 'package_json_invalid',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'release changelog',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const tag = lastTag(cwd, runner);
  const range = tag === null ? 'HEAD' : `${tag}..HEAD`;

  let commits: Commit[];

  try {
    commits = collectCommits(cwd, runner, range);
  } catch (error) {
    process.stderr.write(
      `changelog: ${error instanceof Error ? error.message : String(error)}\n`
    );

    return UNEXPECTED_EXIT;
  }

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
  const outcome = graduateChangelog(current, version, block, today);

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
