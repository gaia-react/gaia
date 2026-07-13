import {load as parseYaml} from 'js-yaml';
import {z} from 'zod';
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
 * to the script for the current repo state; see the snapshot test in
 * `manifest.test.ts`.
 *
 * `--check` mode reads the committed manifest, regenerates an expected
 * manifest in memory, and exits non-zero on any drift. Also lints the
 * classifier sets for entries that are dead code because release-exclude
 * already masks them, and lints every owned `.sh`-bearing directory
 * against the scrub `maintainer-paths` scope and `runtime-deps`'s
 * `SCAN_GLOBS` (`lintScanScopes`), so a shipped script tree can't fall
 * outside both distribution-boundary leak checks at once. Wired into
 * `release.yml` so a stale committed manifest fails the build at tag-time
 * before any bundle work runs.
 */
import {execFileSync} from 'node:child_process';
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import {
  applyWithholds,
  parseExcludeCategories,
  validateAnswers,
} from './manifest-answers.js';
import type {AnswerError, WithholdAnswer} from './manifest-answers.js';
import {SCAN_GLOBS} from './scan-globs.js';

const HELP_TEXT = `Usage: gaia-maintainer release manifest [--out <path>] [--stdout]
                                       [--ship <path>]...
                                       [--withhold <path> --category <N> --reason <text>]...
                                       [--allow-undecided]
       gaia-maintainer release manifest --check [--json]

  Regenerate .gaia/manifest.json. Walks git ls-files, subtracts
  release-exclude patterns and adopter-owned sentinels, classifies the
  remainder, and writes a sorted JSON manifest.

  Refuses, in every output mode, to produce a manifest while any file that
  would newly ship lacks an explicit answer. Answer each one with --ship or
  --withhold, or waive the accounting with --allow-undecided.

  Flags:
    --ship <path>      Answer <path> as shipping. Repeatable.
    --withhold <path>  Answer <path> as withheld: appends it to
                       .gaia/release-exclude. Repeatable. Each --withhold
                       must be closed by exactly one --category and exactly
                       one --reason before the next one.
    --category <N>     Numbered release-exclude category the open --withhold
                       is filed under.
    --reason <text>    One-line rationale, written as the comment directly
                       above the withheld path.
    --allow-undecided  Waive the answer requirement; every unanswered file
                       ships. The escape hatch for bootstrapping a manifest
                       and for unattended regeneration.
    --out <path>       Override output path (default: .gaia/manifest.json).
    --stdout           Print manifest JSON to stdout instead of writing the file.
    --check            Verify the committed manifest matches what the
                       classifier would produce against the current source,
                       lint classifier sets against release-exclude for
                       dead-code overlap, and lint every owned .sh-bearing
                       directory against the scrub maintainer-paths scope and
                       runtime-deps's SCAN_GLOBS. Exits non-zero on drift,
                       overlap, or a scan-scope gap. Read-only: incompatible
                       with every flag above.
    --json             (with --check) Emit a structured JSON drift report.

  Exit codes:
    0  success / check clean
    1  unanswered or invalid answers / user-correctable error / check found
       drift or overlap
    2  unexpected (filesystem / git failure)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const UNEXPECTED_EXIT = 2;

// Root governance files (CHANGELOG.md, CODE_OF_CONDUCT.md, CONTRIBUTING.md,
// LICENSE, README.md, SUPPORTERS.md) and `.github/CODEOWNERS` are handled by
// `.gaia/release-exclude` category 11 (maintainer-only project governance) and
// never reach this classifier. Don't add them to the sets below. /gaia-init
// writes a fresh CODEOWNERS for the adopter, so GAIA's must not ship.
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

// `package.json`, `pnpm-workspace.yaml`, and `.gaia/audit-ci.yml` are `shared`
// but special-cased out of the generic /update-gaia walk: all three are
// field-aware merged (package.json at JSON-key granularity, pnpm-workspace.yaml
// at YAML-key / map-entry granularity, audit-ci.yml at YAML-key granularity
// with its `audit_authors` login=mode string merged entry-by-entry) so adopter
// drift never forces a full-file conflict patch.
const SHARED = new Set([
  '.claude/settings.json',
  '.gaia/audit-ci.yml',
  '.github/FUNDING.yml',
  'CLAUDE.md',
  'package.json',
  'pnpm-workspace.yaml',
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

/**
 * Trimmed, non-blank, non-comment lines from a `.gaia/release-exclude` body.
 * The shared primitive behind both the exclude-pattern compiler here and the
 * scrub `wikilink-to-excluded` slug derivation; one parser keeps the two from
 * drifting on comment / blank-line handling.
 */
export const parseExcludeLines = (text: string): string[] =>
  text.split('\n').flatMap((line) => {
    const trimmed = line.trim();

    if (trimmed.length === 0 || trimmed.startsWith('#')) return [];

    return [trimmed];
  });

export const parseExcludePatterns = (text: string): RegExp[] =>
  parseExcludeLines(text).map(
    (line) => new RegExp(`^${escapeRegExp(line)}(/|$)`)
  );

export const classifyPath = (relativePath: string): ManifestClass | null => {
  if (ADOPTER_OWNED_SENTINELS.has(relativePath)) return null;
  if (SHARED.has(relativePath)) return 'shared';
  if (SHARED_PREFIXES.some((prefix) => relativePath.startsWith(prefix)))
    return 'shared';
  if (WIKI_OWNED_EXACT.has(relativePath)) return 'wiki-owned';
  if (WIKI_OWNED_PREFIXES.some((prefix) => relativePath.startsWith(prefix)))
    return 'wiki-owned';

  return 'owned';
};

const ManifestClassSchema = z.literal([
  'owned',
  'shared',
  'wiki-owned',
] as const);

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

type BuildOptions = {
  /**
   * Override `.gaia/release-exclude`'s content instead of reading it from
   * disk. Lets `run()` compute the post-withhold manifest in memory, before
   * either the boundary file or the manifest is written.
   */
  excludeText?: string;
  /** Override the timestamp for deterministic tests / snapshots. */
  generatedAt?: string;
  /** Override repo root resolution; default is `git rev-parse --show-toplevel`. */
  repoRoot?: string;
};

type ManifestShape = z.infer<typeof ManifestSchema>;

const resolveRepoRoot = (cwd: string): string =>
  execFileSync('git', ['rev-parse', '--show-toplevel'], {
    cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  }).trim();

const resolveExcludePath = (repoRoot: string): string =>
  path.resolve(repoRoot, '.gaia/release-exclude');

const resolveManifestPath = (repoRoot: string): string =>
  path.resolve(repoRoot, '.gaia/manifest.json');

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
  const version = readFileSync(versionPath, 'utf8').trim();
  const excludeText =
    options.excludeText ?? readFileSync(resolveExcludePath(repoRoot), 'utf8');
  const excludePatterns = parseExcludePatterns(excludeText);
  const isExcluded = (candidate: string): boolean =>
    excludePatterns.some((pattern) => pattern.test(candidate));

  const tracked = listGitFiles(repoRoot);
  const entries: [string, ManifestClass][] = [];

  for (const relativePath of tracked) {
    if (!isExcluded(relativePath)) {
      const klass = classifyPath(relativePath);

      if (klass !== null) {
        entries.push([relativePath, klass]);
      }
    }
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
 * For prefix sets, probe the prefix without its trailing slash; exclude
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

  for (const entry of ADOPTER_OWNED_SENTINELS)
    findOverlap(entry, 'ADOPTER_OWNED_SENTINELS');
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
// Scan-scope lint
// ---------------------------------------------------------------------------

const RELEASE_SCRUB_PATH = '.gaia/release-scrub.yml';
const MAINTAINER_PATHS_CHECK_ID = 'maintainer-paths';

export type ScanScopeGap = {
  dir: string;
  missingFrom: readonly ScanScopeName[];
};

type ScanScopeName = 'maintainer-paths scope' | 'runtime-deps SCAN_GLOBS';

/**
 * Read the `maintainer-paths` leak-check's `scope` list straight out of
 * `.gaia/release-scrub.yml`. A light, unvalidated read (mirrors how
 * `buildManifest` reads `.gaia/release-exclude` directly) rather than going
 * through `scrub.ts`'s `loadConfig`, so this module never has to import
 * `scrub.ts` for one field. Returns `undefined` when the file is absent, a
 * minimal/sandboxed checkout (unit-test fixtures) has nothing to lint
 * against, distinct from a present-but-empty scope, which is a real gap.
 */
const readMaintainerPathsScope = (
  repoRoot: string
): readonly string[] | undefined => {
  const scrubPath = path.resolve(repoRoot, RELEASE_SCRUB_PATH);

  if (!existsSync(scrubPath)) return undefined;

  const parsed = parseYaml(readFileSync(scrubPath, 'utf8')) as {
    transforms?: {checks?: {id?: string; scope?: string[]}[]}[];
  };

  for (const transform of parsed.transforms ?? []) {
    for (const check of transform.checks ?? []) {
      if (check.id === MAINTAINER_PATHS_CHECK_ID) return check.scope ?? [];
    }
  }

  return [];
};

/**
 * A scope glob covers `.gaia/scripts/**` or an exact literal; the
 * `maintainer-paths` check's `scope` list uses only those two shapes (no
 * bare `*` entries), so a minimal matcher suffices without pulling in
 * `scrub.ts`'s general-purpose `globToRegex`.
 */
const matchesScopeGlob = (file: string, glob: string): boolean => {
  if (glob === file) return true;
  if (!glob.endsWith('/**')) return false;

  const prefix = glob.slice(0, -3);

  return file === prefix || file.startsWith(`${prefix}/`);
};

const inScanGlobs = (file: string): boolean =>
  SCAN_GLOBS.some((glob) => file === glob || file.startsWith(`${glob}/`));

const computeMissingScopes = (
  file: string,
  inMaintainerScope: (file: string) => boolean
): ScanScopeName[] => {
  const missing: ScanScopeName[] = [];

  if (!inMaintainerScope(file)) missing.push('maintainer-paths scope');
  if (!inScanGlobs(file)) missing.push('runtime-deps SCAN_GLOBS');

  return missing;
};

const recordGap = (
  gapsByDir: Map<string, Set<ScanScopeName>>,
  file: string,
  missing: readonly ScanScopeName[]
): void => {
  const dir = path.dirname(file);
  const existing = gapsByDir.get(dir) ?? new Set<ScanScopeName>();
  for (const name of missing) existing.add(name);
  gapsByDir.set(dir, existing);
};

const listOwnedShFiles = (
  manifestFiles: Readonly<Record<string, ManifestClass>>
): string[] =>
  Object.entries(manifestFiles)
    .filter(([file, klass]) => klass === 'owned' && file.endsWith('.sh'))
    .map(([file]) => file);

/**
 * Cross-check every owned, non-release-excluded `.sh`-bearing directory in
 * the manifest against BOTH distribution-boundary leak-check scopes: the
 * scrub `maintainer-paths` check's `scope` list and `runtime-deps`'s
 * `SCAN_GLOBS`. A directory absent from either is invisible to that check
 * for every `.sh` file beneath it, the shipped-`.sh`-scope-gap Issue Class
 * (`.gaia/cli/health/taxonomy.md`).
 *
 * Matching runs per file (not per directory) since a `**`-suffixed scope
 * glob is anchored to a full path and needs the file's trailing segment to
 * match; the per-file misses are then grouped by directory for reporting.
 */
export const lintScanScopes = (
  manifestFiles: Readonly<Record<string, ManifestClass>>,
  maintainerPathsScope: readonly string[] | undefined
): ScanScopeGap[] => {
  if (maintainerPathsScope === undefined) return [];

  const inMaintainerScope = (file: string): boolean =>
    maintainerPathsScope.some((glob) => matchesScopeGlob(file, glob));

  const gapsByDir = new Map<string, Set<ScanScopeName>>();

  for (const file of listOwnedShFiles(manifestFiles)) {
    const missing = computeMissingScopes(file, inMaintainerScope);

    if (missing.length > 0) recordGap(gapsByDir, file, missing);
  }

  return [...gapsByDir.entries()]
    .map(([dir, missingFrom]) => ({dir, missingFrom: [...missingFrom]}))
    .toSorted((a, b) => a.dir.localeCompare(b.dir));
};

// ---------------------------------------------------------------------------
// Check
// ---------------------------------------------------------------------------

export type ManifestDrift = {
  classifierOverlaps: readonly ClassifierOverlap[];
  drift: readonly {
    actual: ManifestClass;
    expected: ManifestClass;
    file: string;
  }[];
  extra: readonly {actual: ManifestClass; file: string}[];
  missing: readonly {expected: ManifestClass; file: string}[];
  scanScopeGaps: readonly ScanScopeGap[];
  versionDrift: undefined | {actual: string; expected: string};
};

// `Record<string, T>` indexing types as `T`, never `undefined`, without
// `noUncheckedIndexedAccess` — but a file present on one side of the diff
// genuinely may be absent on the other, so this local widening keeps that
// runtime possibility honest instead of narrowing a real "missing" case away.
const lookupClass = (
  files: Record<string, ManifestClass>,
  file: string
): ManifestClass | undefined =>
  (files as Record<string, ManifestClass | undefined>)[file];

type LintResults = {
  classifierOverlaps: readonly ClassifierOverlap[];
  scanScopeGaps: readonly ScanScopeGap[];
};

const computeMissingEntries = (
  expected: ManifestShape,
  actual: ManifestShape
): {expected: ManifestClass; file: string}[] =>
  Object.entries(expected.files)
    .filter(([file]) => lookupClass(actual.files, file) === undefined)
    .map(([file, expectedClass]) => ({expected: expectedClass, file}))
    .toSorted((a, b) => a.file.localeCompare(b.file));

/**
 * The `missing` snapshot the answer gate validates against: every classified
 * path the committed manifest has never acknowledged, as sorted path strings.
 * Shared with `computeDrift` so the gate and the drift report can never
 * disagree about which files are awaiting an answer.
 */
const computeMissing = (
  expected: ManifestShape,
  actual: ManifestShape
): string[] =>
  computeMissingEntries(expected, actual).map((entry) => entry.file);

const computeDrift = (
  expected: ManifestShape,
  actual: ManifestShape,
  lints: LintResults
): ManifestDrift => {
  const {classifierOverlaps, scanScopeGaps} = lints;
  const missing = computeMissingEntries(expected, actual);
  const extra: {actual: ManifestClass; file: string}[] = [];
  const drift: {
    actual: ManifestClass;
    expected: ManifestClass;
    file: string;
  }[] = [];

  for (const [file, expectedClass] of Object.entries(expected.files)) {
    const actualClass = lookupClass(actual.files, file);

    if (actualClass !== undefined && actualClass !== expectedClass) {
      drift.push({actual: actualClass, expected: expectedClass, file});
    }
  }

  for (const [file, actualClass] of Object.entries(actual.files)) {
    if (lookupClass(expected.files, file) === undefined) {
      extra.push({actual: actualClass, file});
    }
  }

  extra.sort((a, b) => a.file.localeCompare(b.file));
  drift.sort((a, b) => a.file.localeCompare(b.file));

  const versionDrift =
    expected.version === actual.version ?
      undefined
    : {actual: actual.version, expected: expected.version};

  return {
    classifierOverlaps,
    drift,
    extra,
    missing,
    scanScopeGaps,
    versionDrift,
  };
};

// Each `renderXLines` helper below owns one report section (empty array when
// that section has nothing to say), so `renderCheckReport` just concatenates
// them instead of branching on every section itself.

const renderVersionDriftLines = (result: ManifestDrift): string[] =>
  result.versionDrift === undefined ?
    []
  : [
      '',
      'version drift:',
      `  manifest version: ${result.versionDrift.actual}`,
      `  .gaia/VERSION:    ${result.versionDrift.expected}`,
    ];

const renderMissingLines = (result: ManifestDrift): string[] =>
  result.missing.length === 0 ?
    []
  : [
      '',
      `missing from manifest (${result.missing.length}):`,
      ...result.missing.map(
        (entry) => `  + ${entry.file}  [${entry.expected}]`
      ),
    ];

const renderExtraLines = (result: ManifestDrift): string[] =>
  result.extra.length === 0 ?
    []
  : [
      '',
      `extra in manifest (${result.extra.length}):`,
      ...result.extra.map((entry) => `  - ${entry.file}  [${entry.actual}]`),
    ];

const renderDriftLines = (result: ManifestDrift): string[] =>
  result.drift.length === 0 ?
    []
  : [
      '',
      `class drift (${result.drift.length}):`,
      ...result.drift.map(
        (entry) => `  ~ ${entry.file}  ${entry.actual} → ${entry.expected}`
      ),
    ];

const renderOverlapLines = (result: ManifestDrift): string[] =>
  result.classifierOverlaps.length === 0 ?
    []
  : [
      '',
      `classifier-set overlaps with release-exclude (${result.classifierOverlaps.length}):`,
      ...result.classifierOverlaps.map(
        (overlap) =>
          `  ${overlap.setName}: ${overlap.entry} (matched by /${overlap.excludePattern}/)`
      ),
    ];

const renderScanScopeLines = (result: ManifestDrift): string[] =>
  result.scanScopeGaps.length === 0 ?
    []
  : [
      '',
      `.sh-bearing directories outside a leak-check scope (${result.scanScopeGaps.length}):`,
      ...result.scanScopeGaps.map(
        (gap) => `  ${gap.dir}  missing from: ${gap.missingFrom.join(', ')}`
      ),
    ];

const renderCheckReport = (
  result: ManifestDrift,
  jsonMode: boolean
): string => {
  if (jsonMode) return `${JSON.stringify(result, null, 2)}\n`;

  const total =
    result.missing.length +
    result.extra.length +
    result.drift.length +
    result.classifierOverlaps.length +
    result.scanScopeGaps.length +
    (result.versionDrift === undefined ? 0 : 1);

  if (total === 0) {
    return 'release manifest --check: clean (manifest fresh, classifier sets coherent)\n';
  }

  const out = [
    `release manifest --check: ${total} issue(s)`,
    ...renderVersionDriftLines(result),
    ...renderMissingLines(result),
    ...renderExtraLines(result),
    ...renderDriftLines(result),
    ...renderOverlapLines(result),
    ...renderScanScopeLines(result),
  ];

  return `${out.join('\n')}\n`;
};

type CommittedManifest =
  | {kind: 'absent'}
  | {kind: 'invalid'; message: string}
  | {kind: 'ok'; manifest: ManifestShape};

/**
 * The committed manifest is untrusted input (hand-edits, merge conflicts, a
 * stale schema), so it is schema-validated before anything diffs against it.
 * Absent is a distinct outcome from malformed: `--check` reports the first as
 * a user-correctable `manifest_missing`, while the answer gate treats it as
 * "nothing has been acknowledged yet".
 */
const readCommittedManifest = (manifestPath: string): CommittedManifest => {
  if (!existsSync(manifestPath)) return {kind: 'absent'};

  try {
    const rawJson: unknown = JSON.parse(readFileSync(manifestPath, 'utf8'));

    return {kind: 'ok', manifest: ManifestSchema.parse(rawJson)};
  } catch (error) {
    const message =
      error instanceof z.ZodError ?
        `committed manifest is malformed: ${z.prettifyError(error)}`
      : error instanceof Error ? error.message
      : String(error);

    return {kind: 'invalid', message};
  }
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
      readFileSync(resolveExcludePath(repoRoot), 'utf8')
    );
  } catch (error) {
    structuredError({
      code: 'manifest_build_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'release manifest',
    });

    return UNEXPECTED_EXIT;
  }

  const manifestPath = resolveManifestPath(repoRoot);
  const committed = readCommittedManifest(manifestPath);

  if (committed.kind === 'absent') {
    // Names the escape hatch, not the bare command: on any tree carrying a
    // classified file, the bare command refuses until every newly-shipping
    // file has an answer, so pointing there would send the reader into the
    // refusal with no way out.
    structuredError({
      code: 'manifest_missing',
      message: `committed manifest not found at ${manifestPath}; run \`gaia-maintainer release manifest --allow-undecided\` to bootstrap it`,
      subcommand: 'release manifest',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (committed.kind === 'invalid') {
    structuredError({
      code: 'manifest_parse_failed',
      message: committed.message,
      path: manifestPath,
      subcommand: 'release manifest',
    });

    return UNEXPECTED_EXIT;
  }

  const actual = committed.manifest;
  const classifierOverlaps = lintClassifierSets(excludePatterns);
  const scanScopeGaps = lintScanScopes(
    expected.files,
    readMaintainerPathsScope(repoRoot)
  );
  const result = computeDrift(expected, actual, {
    classifierOverlaps,
    scanScopeGaps,
  });
  process.stdout.write(renderCheckReport(result, jsonMode));

  const hasIssue =
    result.missing.length > 0 ||
    result.extra.length > 0 ||
    result.drift.length > 0 ||
    result.classifierOverlaps.length > 0 ||
    result.scanScopeGaps.length > 0 ||
    result.versionDrift !== undefined;

  return hasIssue ? EXIT_CODES.UNKNOWN_SUBCOMMAND : EXIT_CODES.OK;
};

// ---------------------------------------------------------------------------
// Flags
// ---------------------------------------------------------------------------

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
  allowUndecided: boolean;
  check: boolean;
  json: boolean;
  outPath: string | undefined;
  ships: string[];
  stdout: boolean;
  withholds: WithholdAnswer[];
};

/**
 * A `--withhold <path>` that has not yet been closed by its `--category` and
 * `--reason`. The next `--withhold`, or the end of argv, closes it.
 */
type PendingWithhold = {
  category: number | undefined;
  path: string;
  reason: string | undefined;
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

/** Returns an error message, or `undefined` once the record is banked. */
const closeWithhold = (
  pending: PendingWithhold | undefined,
  withholds: WithholdAnswer[]
): string | undefined => {
  if (pending === undefined) return undefined;

  if (pending.category === undefined)
    return `--withhold ${pending.path} requires a --category`;

  if (pending.reason === undefined)
    return `--withhold ${pending.path} requires a --reason`;

  withholds.push({
    category: pending.category,
    path: pending.path,
    reason: pending.reason,
  });

  return undefined;
};

/** Accumulator threaded through the flag handlers below. */
type ParseState = {
  allowUndecided: boolean;
  check: boolean;
  json: boolean;
  outPath: string | undefined;
  pending: PendingWithhold | undefined;
  ships: string[];
  stdout: boolean;
  withholds: WithholdAnswer[];
};

/** Each returns an error message, or `undefined` on success. */
type ValueFlagHandler = (
  state: ParseState,
  value: string
) => string | undefined;

const applyCategory: ValueFlagHandler = (state, value) => {
  if (state.pending === undefined)
    return '--category requires a preceding --withhold';

  if (state.pending.category !== undefined)
    return `--withhold ${state.pending.path} carries more than one --category`;

  if (!/^\d+$/.test(value) || Number(value) === 0)
    return `--category must be a positive integer, got: ${value}`;

  state.pending.category = Number(value);

  return undefined;
};

const applyReason: ValueFlagHandler = (state, value) => {
  if (state.pending === undefined)
    return '--reason requires a preceding --withhold';

  if (state.pending.reason !== undefined)
    return `--withhold ${state.pending.path} carries more than one --reason`;

  state.pending.reason = value;

  return undefined;
};

const openPendingWithhold: ValueFlagHandler = (state, value) => {
  const closeError = closeWithhold(state.pending, state.withholds);

  if (closeError !== undefined) return closeError;

  state.pending = {category: undefined, path: value, reason: undefined};

  return undefined;
};

const VALUE_FLAGS: Readonly<Partial<Record<string, ValueFlagHandler>>> = {
  '--category': applyCategory,
  '--out': (state, value) => {
    state.outPath = value;

    return undefined;
  },
  '--reason': applyReason,
  '--ship': (state, value) => {
    state.ships.push(value);

    return undefined;
  },
  '--withhold': openPendingWithhold,
};

const BARE_FLAGS: Readonly<
  Partial<Record<string, (state: ParseState) => void>>
> = {
  '--allow-undecided': (state) => {
    state.allowUndecided = true;
  },
  '--check': (state) => {
    state.check = true;
  },
  '--json': (state) => {
    state.json = true;
  },
  '--stdout': (state) => {
    state.stdout = true;
  },
};

/**
 * Own-property lookup. A bare `Record` index resolves every `Object.prototype`
 * member (`toString`, `constructor`, `__proto__`, …) to a truthy value, so an
 * argv token that happens to name one would slip past the unknown-flag guard:
 * the six method names would be accepted and silently ignored, and `__proto__`
 * would resolve to a non-callable and crash the parse.
 */
const lookUpFlagHandler = <Handler>(
  table: Readonly<Partial<Record<string, Handler>>>,
  token: string
): Handler | undefined =>
  Object.hasOwn(table, token) ? table[token] : undefined;

const validateFlagCombination = (state: ParseState): FlagParseResult => {
  const {allowUndecided, check, json, outPath, ships, stdout, withholds} =
    state;
  const hasAnswers = allowUndecided || ships.length > 0 || withholds.length > 0;

  // `--check` stays read-only: it answers nothing and writes nothing.
  if (check && (outPath !== undefined || stdout || hasAnswers)) {
    return {
      message:
        '--check is incompatible with --out / --stdout / --ship / --withhold / --allow-undecided',
      ok: false,
    };
  }

  if (!check && json) {
    return {message: '--json requires --check', ok: false};
  }

  return {
    flags: {allowUndecided, check, json, outPath, ships, stdout, withholds},
    ok: true,
  };
};

const parseFlags = (argv: readonly string[]): FlagParseResult => {
  const state: ParseState = {
    allowUndecided: false,
    check: false,
    json: false,
    outPath: undefined,
    pending: undefined,
    ships: [],
    stdout: false,
    withholds: [],
  };

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    const bare = lookUpFlagHandler(BARE_FLAGS, token);
    const valued = lookUpFlagHandler(VALUE_FLAGS, token);

    if (bare !== undefined) {
      bare(state);
    } else if (valued === undefined) {
      return {message: `unknown flag: ${token}`, ok: false};
    } else {
      const taken = takeValue(argv, index + 1, token);

      if (!taken.ok) return taken;

      const error = valued(state, taken.value);

      if (error !== undefined) return {message: error, ok: false};

      index += 1;
    }
  }

  // The last `--withhold` is closed by the end of argv rather than by a
  // following one.
  const closeError = closeWithhold(state.pending, state.withholds);

  if (closeError !== undefined) return {message: closeError, ok: false};

  return validateFlagCombination(state);
};

type RunOptions = {
  cwd?: string;
  generatedAt?: string;
};

const tryBuildManifestOrReport = (
  cwd: string,
  options: BuildOptions
): ManifestShape | null => {
  try {
    return buildManifest(cwd, options);
  } catch (error) {
    structuredError({
      code: 'manifest_build_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'release manifest',
    });

    return null;
  }
};

/**
 * Everything the answer gate needs, read once, before any write.
 *
 * `missing` is an oracle this command itself mutates: writing a withhold into
 * `.gaia/release-exclude` shrinks it. Snapshotting it up front is what stops
 * an early boundary write from making the remaining accounting trivially
 * satisfiable.
 */
type ManifestSnapshot = {
  excludeText: string;
  expected: ManifestShape;
  missing: string[];
  repoRoot: string;
};

const trySnapshotOrReport = (
  cwd: string,
  generatedAt: string | undefined
): ManifestSnapshot | null => {
  try {
    const repoRoot = resolveRepoRoot(cwd);
    const manifestPath = resolveManifestPath(repoRoot);
    const excludeText = readFileSync(resolveExcludePath(repoRoot), 'utf8');
    const expected = buildManifest(cwd, {excludeText, generatedAt, repoRoot});
    const committed = readCommittedManifest(manifestPath);

    if (committed.kind === 'invalid') {
      structuredError({
        code: 'manifest_parse_failed',
        message: committed.message,
        path: manifestPath,
        subcommand: 'release manifest',
      });

      return null;
    }

    // An absent manifest means nothing has been acknowledged: every classified
    // path is unanswered, so bootstrapping one from nothing needs the escape
    // hatch. That is correct and intended.
    const actual =
      committed.kind === 'absent' ?
        {files: {}, generated: '', version: expected.version}
      : committed.manifest;

    return {
      excludeText,
      expected,
      missing: computeMissing(expected, actual),
      repoRoot,
    };
  } catch (error) {
    // The `.gaia/release-exclude` read lives inside this try (not at the top
    // of `run`) so an absent or unreadable boundary file stays the exit-2
    // `manifest_build_failed` the CLI has always reported, rather than an
    // uncaught throw.
    structuredError({
      code: 'manifest_build_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'release manifest',
    });

    return null;
  }
};

const resolveOutputTarget = (
  cwd: string,
  repoRoot: string,
  outPath: string | undefined
): string => {
  if (outPath === undefined) {
    return path.join(repoRoot, '.gaia', 'manifest.json');
  }

  return path.isAbsolute(outPath) ? outPath : path.join(cwd, outPath);
};

const tryWriteManifestOrReport = (
  target: string,
  serialized: string
): boolean => {
  try {
    atomicWriteFileSync(target, serialized);

    return true;
  } catch (error) {
    structuredError({
      code: 'manifest_write_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'release manifest',
    });

    return false;
  }
};

const tryWriteExcludeOrReport = (
  target: string,
  excludeText: string
): boolean => {
  try {
    atomicWriteFileSync(target, excludeText);

    return true;
  } catch (error) {
    structuredError({
      code: 'exclude_write_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'release manifest',
    });

    return false;
  }
};

/** Brief stdout summary: file count + per-class breakdown. */
const reportSummary = (
  manifest: ManifestShape,
  cwd: string,
  target: string
): void => {
  const counts: Record<ManifestClass, number> = {
    owned: 0,
    shared: 0,
    'wiki-owned': 0,
  };

  for (const manifestClass of Object.values(manifest.files)) {
    counts[manifestClass] += 1;
  }

  const total = Object.keys(manifest.files).length;
  process.stdout.write(
    `release manifest: wrote ${total} files (owned=${counts.owned}, shared=${counts.shared}, wiki-owned=${counts['wiki-owned']}) → ${path.relative(cwd, target) || target}\n`
  );
};

const reportAnswerErrors = (errors: readonly AnswerError[]): void => {
  for (const error of errors) {
    structuredError({
      code: error.code,
      message: error.message,
      paths: error.paths,
      subcommand: 'release manifest',
    });
  }
};

type EmitOptions = {
  cwd: string;
  generatedAt: string | undefined;
  snapshot: ManifestSnapshot;
  /** `undefined` means `--stdout`: the manifest goes to stdout, not to a file. */
  target: string | undefined;
  withholds: readonly WithholdAnswer[];
};

/**
 * Steps after the gate has passed: apply the answers, then emit. The boundary
 * write happens in every output mode, because a withhold is an answer, not an
 * output: `--stdout` changes where the manifest goes, never whether the
 * boundary moves. The post-withhold manifest is built in memory first, so
 * neither file is touched until both are known-good.
 */
const applyAnswersAndEmit = (options: EmitOptions): number => {
  const {cwd, generatedAt, snapshot, target, withholds} = options;
  const {excludeText, expected, repoRoot} = snapshot;
  const hasWithholds = withholds.length > 0;
  const newExcludeText =
    hasWithholds ? applyWithholds(excludeText, withholds) : excludeText;
  const manifest =
    hasWithholds ?
      tryBuildManifestOrReport(cwd, {
        excludeText: newExcludeText,
        generatedAt,
        repoRoot,
      })
    : expected;

  if (manifest === null) return UNEXPECTED_EXIT;

  if (
    hasWithholds &&
    !tryWriteExcludeOrReport(resolveExcludePath(repoRoot), newExcludeText)
  ) {
    return UNEXPECTED_EXIT;
  }

  const serialized = serialize(manifest);

  if (target === undefined) {
    process.stdout.write(serialized);

    return EXIT_CODES.OK;
  }

  if (!tryWriteManifestOrReport(target, serialized)) return UNEXPECTED_EXIT;

  reportSummary(manifest, cwd, target);

  return EXIT_CODES.OK;
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
      subcommand: 'release manifest',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const {allowUndecided, check, json, outPath, ships, stdout, withholds} =
    parsed.flags;

  if (check) return runCheck(cwd, options.generatedAt, json);

  const snapshot = trySnapshotOrReport(cwd, options.generatedAt);

  if (snapshot === null) return UNEXPECTED_EXIT;

  const errors = validateAnswers(
    {allowUndecided, ships, withholds},
    snapshot.missing,
    parseExcludeCategories(snapshot.excludeText)
  );

  // The gate sits on the PRODUCTION of manifest content, not on the write to
  // `.gaia/manifest.json`: `--stdout` and `--out` are emitting paths too, and
  // an unanswered file must not reach any of them. Nothing has been written at
  // this point, so both files stay byte-identical.
  if (errors.length > 0) {
    reportAnswerErrors(errors);

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const target =
    stdout ? undefined : resolveOutputTarget(cwd, snapshot.repoRoot, outPath);

  // Checked before either write, so a bad `--out` can't leave a withhold
  // banked in the boundary file with no manifest to match it.
  if (target !== undefined && !existsSync(path.dirname(target))) {
    structuredError({
      code: 'output_dir_missing',
      message: `output directory does not exist: ${path.dirname(target)}`,
      subcommand: 'release manifest',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  return applyAnswersAndEmit({
    cwd,
    generatedAt: options.generatedAt,
    snapshot,
    target,
    withholds,
  });
};
