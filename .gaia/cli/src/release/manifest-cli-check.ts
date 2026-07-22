import {z} from 'zod';
/**
 * `gaia-maintainer release manifest --check`: report rendering and the check
 * itself.
 *
 * Reads the committed manifest, regenerates an expected manifest in memory
 * via `./manifest.js`, and exits non-zero on any drift. Also surfaces the
 * classifier-set and scan-scope lint results `./manifest.js` computes, so a
 * shipped script tree can't fall outside both distribution-boundary leak
 * checks at once. Wired into `release.yml` so a stale committed manifest
 * fails the build at tag-time before any bundle work runs.
 *
 * `readCommittedManifest` and `UNEXPECTED_EXIT` are also consumed by
 * `manifest-cli.ts`'s emit/answer-gate path, which reads the same committed
 * manifest before validating answers against it.
 */
import {existsSync, readFileSync} from 'node:fs';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {
  buildManifest,
  computeDrift,
  lintClassifierSets,
  lintScanScopes,
  ManifestSchema,
  parseExcludePatterns,
  readMaintainerPathsScope,
  resolveExcludePath,
  resolveManifestPath,
  resolveRepoRoot,
} from './manifest.js';
import type {ManifestDrift, ManifestShape} from './manifest.js';

export const UNEXPECTED_EXIT = 2;

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

// Mirrors `manifest-answers.ts`'s own `unanswered_paths` language ("would
// newly ship with no explicit answer") so the CLI never describes the same
// fact two different ways depending on which code path notices it.
const renderMissingLines = (result: ManifestDrift): string[] =>
  result.missing.length === 0 ?
    []
  : [
      '',
      `will newly ship to adopters with no explicit answer (${result.missing.length}):`,
      ...result.missing.map(
        (entry) => `  + ${entry.file}  [${entry.expected}]`
      ),
      '',
      'Regenerating the manifest does not withhold these files; each one needs an explicit decision:',
      '  release manifest --ship <path>       accept that it ships',
      '  release manifest --withhold <path> --category <N> --reason <text>   keep it maintainer-only',
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

const renderRegionDriftLines = (result: ManifestDrift): string[] =>
  result.regionDrift.length === 0 ?
    []
  : [
      '',
      `region declaration drift (${result.regionDrift.length}):`,
      ...result.regionDrift.flatMap((entry) => [
        `  region: ${entry.regionId}`,
        ...entry.missing.map((file) => `    + ${file}`),
        ...entry.extra.map((file) => `    - ${file}`),
        ...(entry.contractDrift === undefined ?
          []
        : [`    ~ ${entry.contractDrift}`]),
      ]),
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
    result.regionDrift.length +
    (result.versionDrift === undefined ? 0 : 1);

  if (total === 0) {
    return 'release manifest --check: clean (manifest matches classifier + .gaia/VERSION; this checks bookkeeping, not the distribution boundary)\n';
  }

  const out = [
    `release manifest --check: ${total} issue(s)`,
    ...renderVersionDriftLines(result),
    ...renderMissingLines(result),
    ...renderExtraLines(result),
    ...renderDriftLines(result),
    ...renderRegionDriftLines(result),
    ...renderOverlapLines(result),
    ...renderScanScopeLines(result),
  ];

  return `${out.join('\n')}\n`;
};

export type CommittedManifest =
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
export const readCommittedManifest = (
  manifestPath: string
): CommittedManifest => {
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

export const runCheck = (
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
    result.regionDrift.length > 0 ||
    result.versionDrift !== undefined;

  return hasIssue ? EXIT_CODES.UNKNOWN_SUBCOMMAND : EXIT_CODES.OK;
};
