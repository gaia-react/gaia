/**
 * `gaia release manifest` handler.
 *
 * Walks `git ls-files`, subtracts paths matched by `.gaia/release-exclude`
 * and adopter-owned sentinels, classifies each remaining path, and
 * writes a deterministic (alphabetically sorted) JSON manifest to
 * `.gaia/manifest.json`. Stdout summary reports file count and per-class
 * breakdown.
 *
 * Port of `.gaia/scripts/generate-manifest.mjs`. Output is byte-identical
 * to the script for the current repo state — see the snapshot test in
 * `manifest.test.ts`.
 */
import {execFileSync} from 'node:child_process';
import {existsSync, readFileSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';

const HELP_TEXT = `Usage: gaia release manifest [--out <path>] [--stdout]

  Regenerate .gaia/manifest.json. Walks git ls-files, subtracts
  release-exclude patterns and adopter-owned sentinels, classifies the
  remainder, and writes a sorted JSON manifest.

  Flags:
    --out <path>   Override output path (default: .gaia/manifest.json).
    --stdout       Print manifest JSON to stdout instead of writing the file.

  Exit codes:
    0  success
    1  user-correctable error
    2  unexpected (filesystem / git failure)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const UNEXPECTED_EXIT = 2;

const ADOPTER_OWNED_SENTINELS = new Set([
  '.gaia/manifest.json',
  '.gaia/VERSION',
  'CHANGELOG.md',
  'wiki/hot.md',
  'wiki/log.md',
]);

const SHARED = new Set([
  '.claude/settings.json',
  '.github/CODEOWNERS',
  '.github/FUNDING.yml',
  'CLAUDE.md',
  'package.json',
  'README.md',
  'wiki/index.md',
]);

const SHARED_PREFIXES = ['.github/workflows/'];

const WIKI_OWNED_PREFIXES = [
  'wiki/components/',
  'wiki/concepts/',
  'wiki/decisions/',
  'wiki/dependencies/',
  'wiki/flows/',
  'wiki/modules/',
  'wiki/sources/',
];

const WIKI_OWNED_EXACT = new Set(['wiki/overview.md', 'wiki/README.md']);

export type ManifestClass = 'owned' | 'shared' | 'wiki-owned';

const escapeRegExp = (pattern: string): string =>
  pattern
    .replaceAll('.', String.raw`\.`)
    .replaceAll('+', String.raw`\+`)
    .replaceAll('?', String.raw`\?`)
    .replaceAll('*', '[^/]*');

export const parseExcludePatterns = (text: string): RegExp[] =>
  text
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.length > 0 && !line.startsWith('#'))
    .map((pattern) => new RegExp(`^${escapeRegExp(pattern)}(/|$)`));

export const classifyPath = (relativePath: string): ManifestClass | null => {
  if (ADOPTER_OWNED_SENTINELS.has(relativePath)) return null;
  if (SHARED.has(relativePath)) return 'shared';
  if (SHARED_PREFIXES.some((prefix) => relativePath.startsWith(prefix))) return 'shared';
  if (WIKI_OWNED_EXACT.has(relativePath)) return 'wiki-owned';
  if (WIKI_OWNED_PREFIXES.some((prefix) => relativePath.startsWith(prefix))) return 'wiki-owned';

  return 'owned';
};

type ManifestShape = {
  files: Record<string, ManifestClass>;
  generated: string;
  version: string;
};

type BuildOptions = {
  /** Override the timestamp for deterministic tests / snapshots. */
  generatedAt?: string;
  /** Override repo root resolution; default is `git rev-parse --show-toplevel`. */
  repoRoot?: string;
};

const resolveRepoRoot = (cwd: string): string =>
  execFileSync('git', ['rev-parse', '--show-toplevel'], {
    cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  }).trim();

const listGitFiles = (cwd: string): string[] =>
  execFileSync('git', ['ls-files'], {
    cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  })
    .split('\n')
    .filter((line) => line.length > 0);

export const buildManifest = (
  cwd: string,
  options: BuildOptions = {}
): ManifestShape => {
  const repoRoot = options.repoRoot ?? resolveRepoRoot(cwd);
  const versionPath = path.resolve(repoRoot, '.gaia/VERSION');
  const excludePath = path.resolve(repoRoot, '.gaia/release-exclude');
  const version = readFileSync(versionPath, 'utf8').trim();
  const excludePatterns = parseExcludePatterns(readFileSync(excludePath, 'utf8'));
  const isExcluded = (candidate: string): boolean =>
    excludePatterns.some((pattern) => pattern.test(candidate));

  const tracked = listGitFiles(repoRoot);
  const entries: Array<[string, ManifestClass]> = [];

  for (const relativePath of tracked) {
    if (isExcluded(relativePath)) continue;
    const klass = classifyPath(relativePath);

    if (klass === null) continue;
    entries.push([relativePath, klass]);
  }

  entries.sort(([a], [b]) => a.localeCompare(b));
  const files = Object.fromEntries(entries);

  return {
    files,
    generated: options.generatedAt ?? new Date().toISOString(),
    version,
  };
};

const serialize = (manifest: ManifestShape): string =>
  `${JSON.stringify(manifest, null, 2)}\n`;

type Flags = {
  outPath: string | undefined;
  stdout: boolean;
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

  if (value === undefined) return {message: `${flag} requires a value`, ok: false};

  return {ok: true, value};
};

const parseFlags = (argv: readonly string[]): FlagParseResult => {
  let outPath: string | undefined;
  let stdout = false;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string;

    if (token === '--out') {
      const taken = takeValue(argv, index + 1, '--out');

      if (!taken.ok) return taken;
      outPath = taken.value;
      index += 1;
      continue;
    }

    if (token === '--stdout') {
      stdout = true;
      continue;
    }

    return {message: `unknown flag: ${token}`, ok: false};
  }

  return {flags: {outPath, stdout}, ok: true};
};

type RunOptions = {
  cwd?: string;
  generatedAt?: string;
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
      subcommand: 'release manifest',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  let manifest: ManifestShape;
  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(cwd);
    manifest = buildManifest(cwd, {
      generatedAt: options.generatedAt,
      repoRoot,
    });
  } catch (error) {
    structuredError({
      code: 'manifest_build_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'release manifest',
    });

    return UNEXPECTED_EXIT;
  }

  const serialized = serialize(manifest);

  if (parsed.flags.stdout) {
    process.stdout.write(serialized);

    return EXIT_CODES.OK;
  }

  const target = parsed.flags.outPath
    ? (path.isAbsolute(parsed.flags.outPath)
      ? parsed.flags.outPath
      : path.join(cwd, parsed.flags.outPath))
    : path.join(repoRoot, '.gaia', 'manifest.json');

  if (!existsSync(path.dirname(target))) {
    structuredError({
      code: 'output_dir_missing',
      message: `output directory does not exist: ${path.dirname(target)}`,
      subcommand: 'release manifest',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  try {
    writeFileSync(target, serialized, 'utf8');
  } catch (error) {
    structuredError({
      code: 'manifest_write_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'release manifest',
    });

    return UNEXPECTED_EXIT;
  }

  // Brief stdout summary: file count + per-class breakdown.
  const counts: Record<ManifestClass, number> = {owned: 0, shared: 0, 'wiki-owned': 0};

  for (const klass of Object.values(manifest.files)) counts[klass] += 1;

  const total = Object.keys(manifest.files).length;
  process.stdout.write(
    `release manifest: wrote ${total} files (owned=${counts.owned}, shared=${counts.shared}, wiki-owned=${counts['wiki-owned']}) → ${path.relative(cwd, target) || target}\n`
  );

  return EXIT_CODES.OK;
};
