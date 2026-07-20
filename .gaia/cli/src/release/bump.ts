/**
 * `gaia-maintainer release bump [--auto]` handler.
 *
 * Step 3 of the maintainer release runbook. Scans conventional-commit
 * subjects (and bodies) since the last tag, classifies the highest
 * semver bump, and either reports the proposal or applies it to
 * `package.json` and `.gaia/VERSION`.
 *
 * Bump rules; highest severity wins:
 *
 *   - `BREAKING CHANGE` in body, or `!` suffix on any type → major
 *   - `feat:` / `feat(...):`                               → minor
 *   - every other declared type except `wiki:`             → patch
 *   - `wiki:` and any undeclared type                      → no contribution
 *
 * The grammar and the type vocabulary come from
 * `util/conventional-commit.ts`; `TYPE_TO_BUMP` below is this module's own
 * disposition over that vocabulary.
 *
 * Without `--auto` the command prints `vCURRENT -> vNEXT (bump)` and
 * exits 0 without writing. With `--auto` it writes the new version to
 * `package.json` and `.gaia/VERSION`, then prints the new version on
 * stdout.
 *
 * Major bumps are surfaced but never auto-applied: the CLI always
 * exits 0 on `--auto` for major and writes nothing, expecting the
 * maintainer-facing slash command to confirm before re-invoking.
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

const HELP_TEXT = `Usage: gaia-maintainer release bump [--auto]

  Compute the next semver bump from conventional-commit subjects since
  the last tag. Without --auto, prints the proposal. With --auto, writes
  package.json and .gaia/VERSION.

  Exit codes:
    0  success
    1  user-correctable error (no commits, malformed package.json)
    2  unexpected (git failure)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const UNEXPECTED_EXIT = 2;

export type BumpKind = 'major' | 'minor' | 'patch';

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
  auto: boolean;
};

const parseFlags = (argv: readonly string[]): FlagParseResult => {
  let auto = false;

  for (const token of argv) {
    if (token === '--auto') {
      auto = true;
    } else {
      return {message: `unknown flag: ${token}`, ok: false};
    }
  }

  return {flags: {auto}, ok: true};
};

/**
 * What each declared commit type contributes to the aggregate bump, before the
 * breaking marker (which outranks the type and always means major).
 *
 * Keyed by `CommitType`, so a type added to the vocabulary fails to compile
 * here until it gets a disposition. That is deliberate: `debt` and `build`
 * were in steady use with no entry, so a maintenance window of debt drains
 * plus a rebundle aggregated to no bump while every subject in it was
 * correctly formatted.
 *
 * `wiki` is the one deliberate `null`: sync commits are the tool's own
 * bookkeeping and should never force a release.
 */
const TYPE_TO_BUMP: Record<CommitType, BumpKind | null> = {
  build: 'patch',
  chore: 'patch',
  ci: 'patch',
  debt: 'patch',
  docs: 'patch',
  feat: 'minor',
  fix: 'patch',
  perf: 'patch',
  refactor: 'patch',
  // A revert changes released behavior, so it has to ship. Kept at `patch`
  // rather than inferred from what it undoes: reverting a `feat` arguably
  // warrants more, and a revert that genuinely removes a shipped capability
  // carries the `!` marker, which already outranks this table.
  revert: 'patch',
  style: 'patch',
  test: 'patch',
  wiki: null,
};

export type Commit = {
  body: string;
  subject: string;
};

export const classifyCommit = (commit: Commit): BumpKind | null => {
  const {body, subject} = commit;

  // Breaking change: major.
  if (/(^|\n)BREAKING CHANGE: /u.test(body)) return 'major';

  const header = parseConventionalCommitHeader(subject);

  if (header === undefined) return null;

  const {breaking, type} = header;

  // The `!` marker is read on any type, matching Conventional Commits and the
  // wiki classifier's reading of the same grammar.
  if (breaking) return 'major';
  if (!isCommitType(type)) return null;

  return TYPE_TO_BUMP[type];
};

const RANK: Record<BumpKind, number> = {major: 3, minor: 2, patch: 1};

export const aggregateBump = (commits: readonly Commit[]): BumpKind | null => {
  let highest: BumpKind | null = null;

  for (const commit of commits) {
    const classified = classifyCommit(commit);

    if (
      classified !== null &&
      (highest === null || RANK[classified] > RANK[highest])
    ) {
      highest = classified;
    }
  }

  return highest;
};

export const applyBump = (current: string, kind: BumpKind): string => {
  const parts = current
    .split('.')
    .map((segment) => Number.parseInt(segment, 10));

  if (parts.length !== 3 || parts.some((value) => Number.isNaN(value))) {
    throw new Error(`current version is not semver: "${current}"`);
  }

  const [major, minor, patch] = parts as [number, number, number];

  if (kind === 'major') return `${major + 1}.0.0`;
  if (kind === 'minor') return `${major}.${minor + 1}.0`;

  return `${major}.${minor}.${patch + 1}`;
};

const expectSuccess = (
  result: SpawnSyncReturns<string>,
  command: string,
  args: readonly string[]
): string => {
  if (result.error !== undefined) {
    throw new Error(
      `${command} ${args.join(' ')} failed: ${result.error.message}`
    );
  }

  if ((result.status ?? -1) !== 0) {
    const stderr = result.stderr.trim();

    throw new Error(
      `${command} ${args.join(' ')} exited ${result.status ?? -1}: ${stderr}`
    );
  }

  return result.stdout;
};

type TryRunArgs = {
  args: readonly string[];
  command: string;
  cwd: string;
  runner: CommandRunner;
};

const tryRun = ({args, command, cwd, runner}: TryRunArgs): null | string => {
  const result = runner(command, args, {cwd});

  if (result.error !== undefined || (result.status ?? -1) !== 0) return null;

  return result.stdout;
};

const RECORD_SEPARATOR = '---END-COMMIT---';

export const collectCommits = (
  cwd: string,
  runner: CommandRunner,
  range: string
): Commit[] => {
  const out = expectSuccess(
    runner(
      'git',
      ['log', '--no-merges', `--format=%s%n%b%n${RECORD_SEPARATOR}`, range],
      {cwd}
    ),
    'git',
    ['log']
  );

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
  const out = tryRun({
    args: ['describe', '--tags', '--abbrev=0'],
    command: 'git',
    cwd,
    runner,
  });

  if (out === null) return null;
  const trimmed = out.trim();

  if (trimmed.length === 0) return null;

  return trimmed;
};

type PackageJsonShape = {
  version?: unknown;
};

const readPackageJson = (
  cwd: string
): {path: string; raw: string; version: string} => {
  const target = path.join(cwd, 'package.json');

  if (!existsSync(target)) {
    throw new Error('package.json not found at repo root');
  }
  const raw = readFileSync(target, 'utf8');
  const parsed = JSON.parse(raw) as PackageJsonShape;

  if (typeof parsed.version !== 'string') {
    throw new TypeError('package.json has no string "version"');
  }

  return {path: target, raw, version: parsed.version};
};

const writePackageJsonVersion = (
  packagePath: string,
  raw: string,
  newVersion: string
): void => {
  // Use a regex replace bounded to the first "version" key to preserve
  // overall formatting (sibling key order, indentation, trailing newline).
  const replaced = raw.replace(
    /"version"\s*:\s*"[^"]+"/u,
    `"version": "${newVersion}"`
  );

  if (replaced === raw) {
    throw new Error('failed to rewrite "version" field in package.json');
  }
  atomicWriteFileSync(packagePath, replaced);
};

const writeVersionFile = (cwd: string, newVersion: string): void => {
  const target = path.join(cwd, '.gaia', 'VERSION');

  if (!existsSync(target)) return;
  // Preserve trailing newline if originally present.
  const original = readFileSync(target, 'utf8');
  const trailing = original.endsWith('\n') ? '\n' : '';
  atomicWriteFileSync(target, `${newVersion}${trailing}`);
};

type RunOptions = {
  cwd?: string;
  runner?: CommandRunner;
};

// Each `tryX` helper below owns one step's try/catch and structured-error
// reporting, so `run` reads as a flat sequence of "did this step succeed?"
// checks instead of nested try/catch blocks.

const tryReadPackageJsonOrReport = (
  cwd: string
): null | ReturnType<typeof readPackageJson> => {
  try {
    return readPackageJson(cwd);
  } catch (error) {
    structuredError({
      code: 'package_json_invalid',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'release bump',
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
      `bump: ${error instanceof Error ? error.message : String(error)}\n`
    );

    return null;
  }
};

const tryApplyBumpOrReport = (
  version: string,
  kind: BumpKind
): null | string => {
  try {
    return applyBump(version, kind);
  } catch (error) {
    structuredError({
      code: 'invalid_version',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'release bump',
    });

    return null;
  }
};

const tryWriteVersionOrReport = (
  pkg: ReturnType<typeof readPackageJson>,
  cwd: string,
  nextVersion: string
): boolean => {
  try {
    writePackageJsonVersion(pkg.path, pkg.raw, nextVersion);
    writeVersionFile(cwd, nextVersion);

    return true;
  } catch (error) {
    structuredError({
      code: 'version_write_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'release bump',
    });

    return false;
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
      subcommand: 'release bump',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const runner = options.runner ?? defaultRunner;

  const pkg = tryReadPackageJsonOrReport(cwd);

  if (pkg === null) return EXIT_CODES.UNKNOWN_SUBCOMMAND;

  const tag = lastTag(cwd, runner);
  const range = tag === null ? 'HEAD' : `${tag}..HEAD`;

  const commits = tryCollectCommitsOrReport(cwd, runner, range);

  if (commits === null) return UNEXPECTED_EXIT;

  if (commits.length === 0) {
    process.stderr.write('bump: no commits since last tag; nothing to bump\n');

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const kind = aggregateBump(commits);

  if (kind === null) {
    process.stderr.write(
      'bump: no conventional-commit prefixes found; cannot determine bump\n'
    );

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const nextVersion = tryApplyBumpOrReport(pkg.version, kind);

  if (nextVersion === null) return EXIT_CODES.UNKNOWN_SUBCOMMAND;

  if (!parsed.flags.auto) {
    process.stdout.write(`v${pkg.version} -> v${nextVersion} (${kind})\n`);

    return EXIT_CODES.OK;
  }

  if (kind === 'major') {
    // Per task contract: surface, but do not auto-apply major.
    process.stderr.write(
      `bump: major bump detected (v${pkg.version} -> v${nextVersion}); refusing --auto without explicit confirmation\n`
    );

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (!tryWriteVersionOrReport(pkg, cwd, nextVersion)) return UNEXPECTED_EXIT;

  process.stdout.write(`${nextVersion}\n`);

  return EXIT_CODES.OK;
};
