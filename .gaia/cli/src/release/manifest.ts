import {load as parseYaml} from 'js-yaml';
import {z} from 'zod';
/**
 * Classifier, exclude-pattern parsing, manifest build, and drift engine for
 * `gaia-maintainer release manifest`.
 *
 * Walks `git ls-files`, subtracts paths matched by `.gaia/release-exclude`
 * and adopter-owned sentinels, classifies each remaining path, and returns
 * a deterministic (alphabetically sorted) manifest shape.
 *
 * Port of `.gaia/scripts/generate-manifest.mjs`. Output is byte-identical
 * to the script for the current repo state; see the snapshot test in
 * `manifest.test.ts`.
 *
 * Also lints the classifier sets for entries that are dead code because
 * release-exclude already masks them, and lints every owned `.sh`-bearing
 * directory against the scrub `maintainer-paths` scope and `runtime-deps`'s
 * `SCAN_GLOBS` (`lintScanScopes`), so a shipped script tree can't fall
 * outside both distribution-boundary leak checks at once.
 *
 * The CLI flag grammar, `--check` report rendering, and the `run` entrypoint
 * that consume the pieces here live in `manifest-cli.ts`.
 */
import {execFileSync} from 'node:child_process';
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {hasRejectedExcludeMetacharacter} from './manifest-answers.js';
import {scanRegionDeclarations} from './region-scan.js';
import type {RegionDeclaration} from './region-scan.js';
import {SCAN_GLOBS} from './scan-globs.js';

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

// Escapes every regex metacharacter, including `*`. `.gaia/release-exclude`
// entries are literal paths, matched the same way by the shell staging
// pipeline (`release.yml`) and the distribution bats suite; a compiler that
// rewrote `*` into a glob, or left `[](){}^$|` unescaped, would silently
// disagree with both of them (or crash on a bracketed path). See
// `validateExcludeText` below, which is the loud-rejection half of the same
// fix: this escaping is defense-in-depth for any direct caller.
const escapeRegExp = (pattern: string): string =>
  pattern.replaceAll(/[.*+?^${}()|[\]\\]/g, String.raw`\$&`);

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

/**
 * Validate the RAW `.gaia/release-exclude` text, before `parseExcludeLines`
 * trims it. Every non-comment line must be a bare literal path: no glob or
 * regex metacharacter (the same set `manifest-answers.ts` rejects for a
 * `--withhold` path, via `hasRejectedExcludeMetacharacter`) and no leading or
 * trailing whitespace. The shell staging pipeline and the distribution bats
 * suite both treat every line as a literal path; a glob-shaped or indented
 * entry would make this TS parser silently omit a still-shipping file from
 * the manifest, so this throws loudly instead of building a manifest the
 * other parsers disagree with.
 */
export const validateExcludeText = (text: string): void => {
  const offenders = text.split('\n').filter((line) => {
    // A CRLF checkout leaves a trailing `\r` on every line after the `\n`
    // split; that is a line-ending artifact, not indentation, so it's
    // stripped before the whitespace comparison. `parseExcludeLines`
    // tolerates it via `trim()`; this raw-text validator must match.
    const normalized = line.replace(/\r$/, '');
    const trimmed = normalized.trim();

    if (trimmed.length === 0 || trimmed.startsWith('#')) return false;

    return normalized !== trimmed || hasRejectedExcludeMetacharacter(trimmed);
  });

  if (offenders.length > 0) {
    throw new Error(
      `.gaia/release-exclude entries must be literal paths (no glob/regex metacharacters, no indentation); offending line(s): ${offenders
        .map((line) => JSON.stringify(line))
        .join(', ')}`
    );
  }
};

/**
 * The compiled anchored-regex STRINGS for a `.gaia/release-exclude` body, one
 * per non-comment/non-blank line: `^<escaped>(/|$)`. This is the single source
 * of the escape + anchor transform; both the `RegExp[]` form below and the
 * subcommand's stdout derive from it, so the CLI never carries a second compiler.
 *
 * Emitted from the string form, NOT `RegExp.prototype.source`: `.source` escapes
 * `/` to `\/` and renders the empty pattern as `(?:)`, which would diverge from
 * the shell `awk | sed | awk` text on every slash-bearing line.
 */
export const compileExcludeRegexStrings = (text: string): string[] =>
  parseExcludeLines(text).map((line) => `^${escapeRegExp(line)}(/|$)`);

/**
 * The exact bytes `release exclude-regex` writes to stdout: each compiled
 * pattern on its own line with a trailing newline, byte-identical to the
 * retired `awk | sed | awk` pipeline. The empty exclude list yields the EMPTY
 * string (zero bytes), never a lone newline, so a shell `[ -s ]` check stays a
 * faithful "exclude nothing" signal.
 */
export const renderExcludeRegex = (text: string): string =>
  compileExcludeRegexStrings(text)
    .map((pattern) => `${pattern}\n`)
    .join('');

export const parseExcludePatterns = (text: string): RegExp[] =>
  compileExcludeRegexStrings(text).map((source) => new RegExp(source));

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

const RegionRegenerateSchema = z.object({
  args: z.array(z.string()),
  interpreter: z.string().min(1),
  operand: z.string().min(1),
});

const RegionDeclarationSchema = z.object({
  endMarker: z.string().min(1),
  id: z.string().min(1),
  paths: z.array(z.string()),
  regenerate: RegionRegenerateSchema,
  startMarker: z.string().min(1),
});

/**
 * Runtime shape of `.gaia/manifest.json`. The committed manifest is
 * untrusted input (hand-edits, merge conflicts, a stale schema), so
 * `--check` validates it against this schema before diffing rather than
 * blindly casting `as ManifestShape`.
 *
 * `regions` is additive and optional: a manifest predating the generated-
 * region mechanism has no such key and must still parse and validate clean.
 */
export const ManifestSchema = z.object({
  files: z.record(z.string(), ManifestClassSchema),
  generated: z.string(),
  regions: z.array(RegionDeclarationSchema).optional(),
  version: z.string(),
});

export type BuildOptions = {
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

export type ManifestShape = z.infer<typeof ManifestSchema>;

export const resolveRepoRoot = (cwd: string): string =>
  execFileSync('git', ['rev-parse', '--show-toplevel'], {
    cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  }).trim();

export const resolveExcludePath = (repoRoot: string): string =>
  path.resolve(repoRoot, '.gaia/release-exclude');

export const resolveManifestPath = (repoRoot: string): string =>
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
  validateExcludeText(excludeText);
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
  const regions = scanRegionDeclarations(repoRoot, files);

  return {
    files,
    generated: options.generatedAt ?? new Date().toISOString(),
    regions,
    version,
  };
};

export const serialize = (manifest: ManifestShape): string =>
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
export const readMaintainerPathsScope = (
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
  regionDrift: readonly {
    /** One-line description of a mismatched marker pair or regeneration vector. */
    contractDrift?: string;
    /** In the committed declaration, absent from the fresh scan. */
    extra: readonly string[];
    /** In the fresh scan, absent from the committed declaration. */
    missing: readonly string[];
    regionId: string;
  }[];
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

export type LintResults = {
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
export const computeMissing = (
  expected: ManifestShape,
  actual: ManifestShape
): string[] =>
  computeMissingEntries(expected, actual).map((entry) => entry.file);

const pathSymmetricDiff = (
  actualPaths: readonly string[],
  expectedPaths: readonly string[]
): {extra: string[]; missing: string[]} => {
  const actualSet = new Set(actualPaths);
  const expectedSet = new Set(expectedPaths);

  return {
    extra: actualPaths
      .filter((entry) => !expectedSet.has(entry))
      .toSorted((a, b) => a.localeCompare(b)),
    missing: expectedPaths
      .filter((entry) => !actualSet.has(entry))
      .toSorted((a, b) => a.localeCompare(b)),
  };
};

const argsEqual = (a: readonly string[], b: readonly string[]): boolean =>
  a.length === b.length && a.every((value, index) => value === b[index]);

/**
 * A declared marker pair and regeneration vector are a stable contract
 * across releases; a changed one must fail loudly rather than migrate
 * silently. Returns `undefined` when every contract field agrees.
 */
const describeContractDrift = (
  actual: RegionDeclaration,
  expected: RegionDeclaration
): string | undefined => {
  const diffs: string[] = [];

  if (actual.startMarker !== expected.startMarker) {
    diffs.push(
      `startMarker: committed ${JSON.stringify(actual.startMarker)} vs expected ${JSON.stringify(expected.startMarker)}`
    );
  }

  if (actual.endMarker !== expected.endMarker) {
    diffs.push(
      `endMarker: committed ${JSON.stringify(actual.endMarker)} vs expected ${JSON.stringify(expected.endMarker)}`
    );
  }

  if (actual.regenerate.interpreter !== expected.regenerate.interpreter) {
    diffs.push(
      `regenerate.interpreter: committed ${JSON.stringify(actual.regenerate.interpreter)} vs expected ${JSON.stringify(expected.regenerate.interpreter)}`
    );
  }

  if (actual.regenerate.operand !== expected.regenerate.operand) {
    diffs.push(
      `regenerate.operand: committed ${JSON.stringify(actual.regenerate.operand)} vs expected ${JSON.stringify(expected.regenerate.operand)}`
    );
  }

  if (!argsEqual(actual.regenerate.args, expected.regenerate.args)) {
    diffs.push(
      `regenerate.args: committed ${JSON.stringify(actual.regenerate.args)} vs expected ${JSON.stringify(expected.regenerate.args)}`
    );
  }

  return diffs.length === 0 ? undefined : diffs.join('; ');
};

/**
 * Region declarations, matched by `id`, over `expected` (a fresh scan) vs
 * `actual` (the committed manifest). A committed manifest with no `regions`
 * key at all is treated as an empty list, so every expected region falls
 * into the id-only-in-expected case below, which is the correct, expected
 * drift report until the manifest is regenerated.
 */
const computeRegionDrift = (
  expectedRegions: readonly RegionDeclaration[],
  actualRegions: readonly RegionDeclaration[]
): ManifestDrift['regionDrift'] => {
  const expectedById = new Map(expectedRegions.map((r) => [r.id, r]));
  const actualById = new Map(actualRegions.map((r) => [r.id, r]));
  const uniqueIds = [
    ...new Set([...expectedById.keys(), ...actualById.keys()]),
  ];
  const ids = uniqueIds.toSorted((a, b) => a.localeCompare(b));

  const drift: ManifestDrift['regionDrift'][number][] = [];

  for (const id of ids) {
    const expected = expectedById.get(id);
    const actual = actualById.get(id);

    if (expected === undefined && actual !== undefined) {
      drift.push({
        extra: actual.paths.toSorted((a, b) => a.localeCompare(b)),
        missing: [],
        regionId: id,
      });
    } else if (actual === undefined && expected !== undefined) {
      drift.push({
        extra: [],
        missing: expected.paths.toSorted((a, b) => a.localeCompare(b)),
        regionId: id,
      });
    } else if (expected !== undefined && actual !== undefined) {
      const {extra, missing} = pathSymmetricDiff(actual.paths, expected.paths);
      const contractDrift = describeContractDrift(actual, expected);

      if (
        extra.length > 0 ||
        missing.length > 0 ||
        contractDrift !== undefined
      ) {
        drift.push({
          ...(contractDrift === undefined ? {} : {contractDrift}),
          extra,
          missing,
          regionId: id,
        });
      }
    }
  }

  return drift;
};

export const computeDrift = (
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

  const regionDrift = computeRegionDrift(
    expected.regions ?? [],
    actual.regions ?? []
  );

  const versionDrift =
    expected.version === actual.version ?
      undefined
    : {actual: actual.version, expected: expected.version};

  return {
    classifierOverlaps,
    drift,
    extra,
    missing,
    regionDrift,
    scanScopeGaps,
    versionDrift,
  };
};
