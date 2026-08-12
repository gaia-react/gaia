/**
 * `gaia-maintainer release changelog [--draft]` handler.
 *
 * Step 5 of the maintainer release runbook. The hand-written
 * `## [Unreleased]` block is the release content: every merge gates on an
 * entry there (`.claude/rules/pr-merge.md`), and those entries are
 * adopter-facing prose a conventional-commit subject cannot stand in for.
 *
 * With `--draft`, renders a Keep-a-Changelog block from conventional-commit
 * subjects since the last tag, mapping each commit type to a section
 * heading, and prints it to stdout. That block is a review aid the runbook
 * shows the maintainer so anything missing can be folded into
 * `## [Unreleased]` by hand; it is never written to the file.
 *
 * Without `--draft`, the hand-written block is graduated in place:
 *
 *   1. Find `## [Unreleased]`. Replace with `## [X.Y.Z] - YYYY-MM-DD`,
 *      leaving the hand-written entries beneath it.
 *   2. Insert a fresh empty `## [Unreleased]` section above.
 *   3. Maintain the Keep-a-Changelog reference-link block: repoint the
 *      `[Unreleased]` compare link at the new version and add a `[X.Y.Z]`
 *      release-tag definition. Skipped when the file has no link block.
 *
 * An empty `## [Unreleased]` body is refused rather than dated, so a
 * release cannot ship a version heading with nothing under it.
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
import {MAX_GIT_BUFFER_BYTES} from '../util/git-buffer.js';

const HELP_TEXT = `Usage: gaia-maintainer release changelog [--draft] [--version <X.Y.Z>]

  Graduate the hand-written \`## [Unreleased]\` block to
  \`## [X.Y.Z] - YYYY-MM-DD\` and open a fresh empty one above it.

  Flags:
    --draft               Render a block from conventional-commit subjects
                          since the last tag to stdout and write nothing.
                          A review aid: fold anything it shows that the
                          Unreleased block is missing in by hand.
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

/**
 * `collectCommits` asks git for every subject *and body* since the last tag,
 * so its output grows with the distance from that tag and passes Node's 1 MiB
 * `spawnSync` default well before a release is due, failing the command
 * closed with ENOBUFS.
 */
export const defaultRunner: CommandRunner = (command, args, options) =>
  spawnSync(command, args as string[], {
    cwd: options.cwd,
    encoding: 'utf8',
    maxBuffer: MAX_GIT_BUFFER_BYTES,
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
  revert: 'Fixed',
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
  | {kind: 'duplicate'}
  | {kind: 'empty-unreleased'}
  | {kind: 'no-unreleased'}
  | {kind: 'ok'; updated: string};

/**
 * What the caller reports for each outcome that refuses to graduate. Keyed by
 * outcome kind, so a new refusal fails to compile here until it has a message.
 * `duplicate` is absent deliberately: it is the idempotent no-op, not a refusal.
 */
const GRADUATE_REFUSALS: Record<
  Exclude<GraduateOutcome['kind'], 'duplicate' | 'ok'>,
  {code: string; message: string}
> = {
  'empty-unreleased': {
    code: 'empty_unreleased_section',
    message:
      'CHANGELOG.md has an empty `## [Unreleased]` section; write the release entries under it before graduating (`release changelog --draft` renders a starting point)',
  },
  'no-unreleased': {
    code: 'no_unreleased_section',
    message: 'CHANGELOG.md has no `## [Unreleased]` heading to graduate',
  },
};

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

/** A Keep-a-Changelog reference-link definition, e.g. `[1.0.0]: https://…`. */
const LINK_DEFINITION = /^\[[^\]]+\]:/u;

/**
 * Does the `## [Unreleased]` section carry anything to release? Its body runs
 * from the heading to whichever comes first: the next `## ` heading, the
 * reference-link block, or the end of the file. The link block ends it because
 * a changelog with no released version yet carries its links directly under
 * `## [Unreleased]`, where counting them as entries would date an empty
 * section.
 */
const hasUnreleasedEntries = (
  lines: readonly string[],
  unreleasedIndex: number
): boolean => {
  for (const line of lines.slice(unreleasedIndex + 1)) {
    if (line.startsWith('## ') || LINK_DEFINITION.test(line)) return false;
    if (line.trim() !== '') return true;
  }

  return false;
};

type GraduateChangelogArgs = {
  current: string;
  newVersion: string;
  today: string;
};

export const graduateChangelog = ({
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

  if (!hasUnreleasedEntries(lines, unreleasedIndex)) {
    return {kind: 'empty-unreleased'};
  }

  // Only the heading is replaced: the hand-written body below it is left where
  // it is, which is what makes it the released block.
  lines.splice(unreleasedIndex, 1, UNRELEASED_HEADING, '', versionHeading);

  const updated = updateLinkReferences(lines.join('\n'), newVersion);

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
  const [firstArgument] = argv;

  if (firstArgument !== undefined && HELP_TOKENS.has(firstArgument)) {
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

  // Only the draft path reads git: the graduation moves the hand-written
  // Unreleased block and never consults commit subjects.
  if (parsed.flags.draft) {
    const tag = lastTag(cwd, runner);
    const range = tag === null ? 'HEAD' : `${tag}..HEAD`;
    const commits = tryCollectCommitsOrReport(cwd, runner, range);

    if (commits === null) return UNEXPECTED_EXIT;

    process.stdout.write(renderBlock(groupCommits(commits)));

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
    current,
    newVersion: version,
    today,
  });

  if (outcome.kind === 'duplicate') {
    // Idempotent: nothing to do.
    return EXIT_CODES.OK;
  }

  if (outcome.kind !== 'ok') {
    structuredError({
      ...GRADUATE_REFUSALS[outcome.kind],
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
