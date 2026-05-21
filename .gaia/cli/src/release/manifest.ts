/**
 * `gaia-maintainer release manifest` handler.
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
 *
 * `--check` mode reads the committed manifest, regenerates an expected
 * manifest in memory, and exits non-zero on any drift. Also lints the
 * classifier sets for entries that are dead code because release-exclude
 * already masks them. Wired into `release.yml` so a stale committed
 * manifest fails the build at tag-time before any bundle work runs.
 */
import {execFileSync} from 'node:child_process';
import {existsSync, readFileSync} from 'node:fs';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import path from 'node:path';
import {z} from 'zod';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';

const HELP_TEXT = `Usage: gaia-maintainer release manifest [--out <path>] [--stdout]
       gaia-maintainer release manifest --check [--json]

  Regenerate .gaia/manifest.json. Walks git ls-files, subtracts
  release-exclude patterns and adopter-owned sentinels, classifies the
  remainder, and writes a sorted JSON manifest.

  Flags:
    --out <path>   Override output path (default: .gaia/manifest.json).
    --stdout       Print manifest JSON to stdout instead of writing the file.
    --check        Verify the committed manifest matches what the
                   classifier would produce against the current source,
                   and lint classifier sets against release-exclude for
                   dead-code overlap. Exits non-zero on drift / overlap.
    --json         (with --check) Emit a structured JSON drift report.

  Exit codes:
    0  success / check clean
    1  user-correctable error / check found drift or overlap
    2  unexpected (filesystem / git failure)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const UNEXPECTED_EXIT = 2;

// Root governance files (CHANGELOG.md, CODE_OF_CONDUCT.md, CONTRIBUTING.md,
// LICENSE, README.md, SUPPORTERS.md) are handled by `.gaia/release-exclude`
// category 11 (maintainer-only project governance) and never reach this
// classifier. Don't add them to the sets below.
//
// Canonical source of the git-tracked adopter-owned sentinels. `release
// runtime-deps` imports this set and extends it with its own runtime-only
// sentinels (paths created on the adopter side that are never git-tracked,
// so they can't appear here). Keeping one shared base prevents the two
// allowlists silently drifting apart.
export const ADOPTER_OWNED_SENTINELS: ReadonlySet<string> = new Set([
  '.gaia/manifest.json',
  '.gaia/VERSION',
  'wiki/hot.md',
  'wiki/log.md',
]);

const SHARED = new Set([
  '.claude/settings.json',
  '.github/CODEOWNERS',
  '.github/FUNDING.yml',
  'CLAUDE.md',
  'package.json',
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

const ManifestClassSchema = z.literal(['owned', 'shared', 'wiki-owned'] as const);

/**
 * Runtime shape of `.gaia/manifest.json`. The committed manifest is
 * untrusted input (hand-edits, merge conflicts, a stale schema), so
 * `--check` validates it against this schema before diffing rather than
 * blindly casting `as ManifestShape`.
 */
const ManifestSchema = z.object({
  files: z.record(z.string(), ManifestClassSchema),
  generated: z.string(),
  version: z.string(),
});

type ManifestShape = z.infer<typeof ManifestSchema>;

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

// ---------------------------------------------------------------------------
// Classifier-set lint
// ---------------------------------------------------------------------------

export type ClassifierOverlap = {
  entry: string;
  excludePattern: string;
  setName: string;
};

/**
 * Cross-check the classifier sets against `.gaia/release-exclude`. An
 * entry that's matched by an exclude pattern is dead code: `buildManifest`
 * runs the exclude filter first, so the classifier never sees the path.
 *
 * For prefix sets, probe the prefix without its trailing slash — exclude
 * regexes are anchored `^P(/|$)` so the directory path itself matches.
 */
export const lintClassifierSets = (
  excludePatterns: readonly RegExp[]
): ClassifierOverlap[] => {
  const overlaps: ClassifierOverlap[] = [];

  const findOverlap = (entry: string, setName: string): void => {
    const matched = excludePatterns.find((pattern) => pattern.test(entry));

    if (matched !== undefined) {
      overlaps.push({entry, excludePattern: matched.source, setName});
    }
  };

  for (const entry of ADOPTER_OWNED_SENTINELS) findOverlap(entry, 'ADOPTER_OWNED_SENTINELS');
  for (const entry of SHARED) findOverlap(entry, 'SHARED');
  for (const entry of WIKI_OWNED_EXACT) findOverlap(entry, 'WIKI_OWNED_EXACT');

  for (const prefix of SHARED_PREFIXES) {
    findOverlap(prefix.replace(/\/$/, ''), 'SHARED_PREFIXES');
  }

  for (const prefix of WIKI_OWNED_PREFIXES) {
    findOverlap(prefix.replace(/\/$/, ''), 'WIKI_OWNED_PREFIXES');
  }

  return overlaps;
};

// ---------------------------------------------------------------------------
// Check
// ---------------------------------------------------------------------------

export type ManifestDrift = {
  classifierOverlaps: readonly ClassifierOverlap[];
  drift: ReadonlyArray<{
    actual: ManifestClass;
    expected: ManifestClass;
    file: string;
  }>;
  extra: ReadonlyArray<{actual: ManifestClass; file: string}>;
  missing: ReadonlyArray<{expected: ManifestClass; file: string}>;
  versionDrift: {actual: string; expected: string} | undefined;
};

const computeDrift = (
  expected: ManifestShape,
  actual: ManifestShape,
  classifierOverlaps: readonly ClassifierOverlap[]
): ManifestDrift => {
  const missing: Array<{expected: ManifestClass; file: string}> = [];
  const extra: Array<{actual: ManifestClass; file: string}> = [];
  const drift: Array<{actual: ManifestClass; expected: ManifestClass; file: string}> = [];

  for (const [file, expectedClass] of Object.entries(expected.files)) {
    const actualClass = actual.files[file];

    if (actualClass === undefined) {
      missing.push({expected: expectedClass, file});
      continue;
    }

    if (actualClass !== expectedClass) {
      drift.push({actual: actualClass, expected: expectedClass, file});
    }
  }

  for (const [file, actualClass] of Object.entries(actual.files)) {
    if (expected.files[file] === undefined) {
      extra.push({actual: actualClass, file});
    }
  }

  missing.sort((a, b) => a.file.localeCompare(b.file));
  extra.sort((a, b) => a.file.localeCompare(b.file));
  drift.sort((a, b) => a.file.localeCompare(b.file));

  const versionDrift =
    expected.version === actual.version
      ? undefined
      : {actual: actual.version, expected: expected.version};

  return {classifierOverlaps, drift, extra, missing, versionDrift};
};

const renderCheckReport = (
  result: ManifestDrift,
  jsonMode: boolean
): string => {
  if (jsonMode) return `${JSON.stringify(result, null, 2)}\n`;

  const out: string[] = [];
  const total =
    result.missing.length
    + result.extra.length
    + result.drift.length
    + result.classifierOverlaps.length
    + (result.versionDrift === undefined ? 0 : 1);

  if (total === 0) {
    out.push('release manifest --check: clean (manifest fresh, classifier sets coherent)');

    return `${out.join('\n')}\n`;
  }

  out.push(`release manifest --check: ${total} issue(s)`);

  if (result.versionDrift !== undefined) {
    out.push(
      '',
      `version drift:`,
      `  manifest version: ${result.versionDrift.actual}`,
      `  .gaia/VERSION:    ${result.versionDrift.expected}`
    );
  }

  if (result.missing.length > 0) {
    out.push('', `missing from manifest (${result.missing.length}):`);

    for (const entry of result.missing) {
      out.push(`  + ${entry.file}  [${entry.expected}]`);
    }
  }

  if (result.extra.length > 0) {
    out.push('', `extra in manifest (${result.extra.length}):`);

    for (const entry of result.extra) {
      out.push(`  - ${entry.file}  [${entry.actual}]`);
    }
  }

  if (result.drift.length > 0) {
    out.push('', `class drift (${result.drift.length}):`);

    for (const entry of result.drift) {
      out.push(`  ~ ${entry.file}  ${entry.actual} → ${entry.expected}`);
    }
  }

  if (result.classifierOverlaps.length > 0) {
    out.push(
      '',
      `classifier-set overlaps with release-exclude (${result.classifierOverlaps.length}):`
    );

    for (const overlap of result.classifierOverlaps) {
      out.push(`  ${overlap.setName}: ${overlap.entry} (matched by /${overlap.excludePattern}/)`);
    }
  }

  return `${out.join('\n')}\n`;
};

const runCheck = (
  cwd: string,
  generatedAt: string | undefined,
  jsonMode: boolean
): number => {
  let repoRoot: string;
  let expected: ManifestShape;
  let excludePatterns: RegExp[];

  try {
    repoRoot = resolveRepoRoot(cwd);
    expected = buildManifest(cwd, {generatedAt, repoRoot});
    excludePatterns = parseExcludePatterns(
      readFileSync(path.resolve(repoRoot, '.gaia/release-exclude'), 'utf8')
    );
  } catch (error) {
    structuredError({
      code: 'manifest_build_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'release manifest',
    });

    return UNEXPECTED_EXIT;
  }

  const manifestPath = path.resolve(repoRoot, '.gaia/manifest.json');

  if (!existsSync(manifestPath)) {
    structuredError({
      code: 'manifest_missing',
      message: `committed manifest not found at ${manifestPath}; run \`gaia-maintainer release manifest\` to generate it`,
      subcommand: 'release manifest',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let actual: ManifestShape;

  try {
    const rawJson: unknown = JSON.parse(readFileSync(manifestPath, 'utf8'));
    actual = ManifestSchema.parse(rawJson);
  } catch (error) {
    const message =
      error instanceof z.ZodError
        ? `committed manifest is malformed: ${z.prettifyError(error)}`
        : error instanceof Error
          ? error.message
          : String(error);
    structuredError({
      code: 'manifest_parse_failed',
      message,
      path: manifestPath,
      subcommand: 'release manifest',
    });

    return UNEXPECTED_EXIT;
  }

  const classifierOverlaps = lintClassifierSets(excludePatterns);
  const result = computeDrift(expected, actual, classifierOverlaps);
  process.stdout.write(renderCheckReport(result, jsonMode));

  const hasIssue =
    result.missing.length > 0
    || result.extra.length > 0
    || result.drift.length > 0
    || result.classifierOverlaps.length > 0
    || result.versionDrift !== undefined;

  return hasIssue ? EXIT_CODES.UNKNOWN_SUBCOMMAND : EXIT_CODES.OK;
};

// ---------------------------------------------------------------------------
// Flags
// ---------------------------------------------------------------------------

type Flags = {
  check: boolean;
  json: boolean;
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
  let check = false;
  let json = false;
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

    if (token === '--check') {
      check = true;
      continue;
    }

    if (token === '--json') {
      json = true;
      continue;
    }

    return {message: `unknown flag: ${token}`, ok: false};
  }

  if (check && (outPath !== undefined || stdout)) {
    return {message: '--check is incompatible with --out / --stdout', ok: false};
  }

  if (!check && json) {
    return {message: '--json requires --check', ok: false};
  }

  return {flags: {check, json, outPath, stdout}, ok: true};
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

  if (parsed.flags.check) {
    return runCheck(cwd, options.generatedAt, parsed.flags.json);
  }

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
    atomicWriteFileSync(target, serialized);
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
