import {z} from 'zod';
/**
 * `gaia-maintainer release manifest` CLI: `--check` report rendering and the
 * emit/run entrypoint. Flag grammar (argv parsing, flag-combination
 * validation, `--help` text) lives in `manifest-cli-args.ts`.
 *
 * Stdout summary reports file count and per-class breakdown on a plain
 * write.
 *
 * `--check` mode reads the committed manifest, regenerates an expected
 * manifest in memory via `./manifest.js`, and exits non-zero on any drift.
 * Also surfaces the classifier-set and scan-scope lint results `./manifest.js`
 * computes, so a shipped script tree can't fall outside both distribution-
 * boundary leak checks at once. Wired into `release.yml` so a stale
 * committed manifest fails the build at tag-time before any bundle work
 * runs.
 *
 * Refuses, in every output mode, to produce a manifest while any file that
 * would newly ship lacks an explicit answer; see `manifest-answers.ts`.
 */
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
import {HELP_TEXT, HELP_TOKENS, parseFlags} from './manifest-cli-args.js';
import {
  buildManifest,
  computeDrift,
  computeMissing,
  lintClassifierSets,
  lintScanScopes,
  ManifestSchema,
  parseExcludePatterns,
  readMaintainerPathsScope,
  resolveExcludePath,
  resolveManifestPath,
  resolveRepoRoot,
  serialize,
} from './manifest.js';
import type {
  BuildOptions,
  ManifestClass,
  ManifestDrift,
  ManifestShape,
} from './manifest.js';

const UNEXPECTED_EXIT = 2;

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
    return 'release manifest --check: clean (manifest matches classifier + .gaia/VERSION; this checks bookkeeping, not the distribution boundary)\n';
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
