/**
 * `gaia-maintainer release bump [--auto]` handler.
 *
 * Step 3 of the maintainer release runbook. Scans conventional-commit
 * subjects (and bodies) since the last tag, classifies the highest
 * semver bump, and either reports the proposal or applies it to
 * `package.json` and `.gaia/VERSION`.
 *
 * Bump rules — highest severity wins:
 *
 *   - `BREAKING CHANGE` in body, or `!` suffix on type → major
 *   - `feat:` / `feat(...):`                            → minor
 *   - `fix:` / `docs:` / `chore:` / `refactor:` /
 *     `perf:` / `ci:` / `test:` / `style:`              → patch
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
import {type SpawnSyncReturns, spawnSync} from 'node:child_process';
import {existsSync, readFileSync} from 'node:fs';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';

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

type Flags = {
  auto: boolean;
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

const parseFlags = (argv: readonly string[]): FlagParseResult => {
  let auto = false;

  for (const token of argv) {
    if (token === '--auto') {
      auto = true;
      continue;
    }

    return {message: `unknown flag: ${token}`, ok: false};
  }

  return {flags: {auto}, ok: true};
};

const PATCH_TYPES = new Set([
  'chore',
  'ci',
  'docs',
  'fix',
  'perf',
  'refactor',
  'style',
  'test',
]);

/** `feat`, `feat(scope)`, `fix!`, `feat(scope)!:`, `BREAKING CHANGE: …`. */
const CONVENTIONAL_HEADER_REGEX =
  /^(?<type>[a-z]+)(?:\([^)]*\))?(?<bang>!?):/u;

export type Commit = {
  body: string;
  subject: string;
};

export const classifyCommit = (commit: Commit): BumpKind | null => {
  const subject = commit.subject.trim();
  const body = commit.body;

  // Breaking change — major.
  if (/(^|\n)BREAKING CHANGE: /u.test(body)) return 'major';

  const match = CONVENTIONAL_HEADER_REGEX.exec(subject);

  if (match === null) return null;
  const groups = match.groups ?? {};

  if (groups.bang === '!') return 'major';

  const type = groups.type;

  if (type === 'feat') return 'minor';
  if (type !== undefined && PATCH_TYPES.has(type)) return 'patch';

  return null;
};

const RANK: Record<BumpKind, number> = {major: 3, minor: 2, patch: 1};

export const aggregateBump = (commits: readonly Commit[]): BumpKind | null => {
  let highest: BumpKind | null = null;

  for (const commit of commits) {
    const classified = classifyCommit(commit);

    if (classified === null) continue;

    if (highest === null || RANK[classified] > RANK[highest]) {
      highest = classified;
    }
  }

  return highest;
};

export const applyBump = (
  current: string,
  kind: BumpKind
): string => {
  const parts = current.split('.').map((segment) => Number.parseInt(segment, 10));

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
    throw new Error(`${command} ${args.join(' ')} failed: ${result.error.message}`);
  }

  if ((result.status ?? -1) !== 0) {
    const stderr = (result.stderr ?? '').trim();
    throw new Error(
      `${command} ${args.join(' ')} exited ${result.status ?? -1}: ${stderr}`
    );
  }

  return result.stdout ?? '';
};

const tryRun = (
  runner: CommandRunner,
  command: string,
  args: readonly string[],
  cwd: string
): string | null => {
  const result = runner(command, args, {cwd});

  if (result.error !== undefined || (result.status ?? -1) !== 0) return null;

  return result.stdout ?? '';
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
      [
        'log',
        '--no-merges',
        `--format=%s%n%b%n${RECORD_SEPARATOR}`,
        range,
      ],
      {cwd}
    ),
    'git',
    ['log']
  );

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
  const out = tryRun(runner, 'git', ['describe', '--tags', '--abbrev=0'], cwd);

  if (out === null) return null;
  const trimmed = out.trim();

  if (trimmed.length === 0) return null;

  return trimmed;
};

type PackageJsonShape = {
  version?: unknown;
};

const readPackageJson = (cwd: string): {raw: string; version: string; path: string} => {
  const target = path.join(cwd, 'package.json');

  if (!existsSync(target)) {
    throw new Error('package.json not found at repo root');
  }
  const raw = readFileSync(target, 'utf8');
  const parsed = JSON.parse(raw) as PackageJsonShape;

  if (typeof parsed.version !== 'string') {
    throw new Error('package.json has no string "version"');
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
      subcommand: 'release bump',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const runner = options.runner ?? defaultRunner;

  let pkg: ReturnType<typeof readPackageJson>;

  try {
    pkg = readPackageJson(cwd);
  } catch (error) {
    structuredError({
      code: 'package_json_invalid',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'release bump',
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
      `bump: ${error instanceof Error ? error.message : String(error)}\n`
    );

    return UNEXPECTED_EXIT;
  }

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

  let nextVersion: string;

  try {
    nextVersion = applyBump(pkg.version, kind);
  } catch (error) {
    structuredError({
      code: 'invalid_version',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'release bump',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

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

  try {
    writePackageJsonVersion(pkg.path, pkg.raw, nextVersion);
    writeVersionFile(cwd, nextVersion);
  } catch (error) {
    structuredError({
      code: 'version_write_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'release bump',
    });

    return UNEXPECTED_EXIT;
  }

  process.stdout.write(`${nextVersion}\n`);

  return EXIT_CODES.OK;
};
