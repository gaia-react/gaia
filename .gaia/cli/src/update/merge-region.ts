/**
 * `gaia update merge-region --baseline <file> --latest <file> --current <file>
 *   --start-marker <text> --end-marker <text>` handler.
 *
 * Region-aware verdict oracle for a declared generated region inside an owned
 * file (SPEC-057). The merge walk's per-file decision table currently
 * compares an owned file whole-file with `cmp -s`, so any divergence
 * anywhere in the file, including inside a marker-delimited block a shipped
 * command regenerates, becomes a full-file conflict patch. This oracle masks
 * the declared region on each of the three sides (baseline / latest /
 * current) with `./region-markers.js`'s `maskRegion`, then classifies the
 * normalized result the same way the two existing field-aware oracles
 * (`merge-workspace.ts`, `merge-audit-ci.ts`) classify their own fields.
 *
 * It is READ-ONLY: `computeRegionMerge` is a pure function of its five string
 * arguments, no `node:fs` call, no process spawn, no write of any kind. It
 * also emits the normalized bodies, because nothing else in the flow can
 * parse a region and the conflict patch has to be built from somewhere.
 *
 * Two normalization rules, deliberately different:
 *
 *   - a side whose scan is `absent` is compared unmasked while the other
 *     sides are still masked ("normalize each side independently")
 *   - if any side scans `malformed`, the whole comparison bails: no side is
 *     masked, every `normalized.*` field carries its own raw content, and
 *     the verdict falls out of the unmodified whole-file comparison
 *     ("never partially normalized")
 *
 * Verdict order, over `normalized.*`:
 *   1. baseline === latest   → no-upstream-change
 *   2. current === baseline  → no-adopter-drift
 *   3. current === latest    → already-latest
 *   4. otherwise              → conflict
 */
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {maskRegion} from './region-markers.js';
import type {RegionMalformation, RegionScan} from './region-markers.js';

const HELP_TEXT = `Usage: gaia update merge-region --baseline <file> --latest <file> --current <file> --start-marker <text> --end-marker <text> [--json]

  Region-aware three-way verdict for a marker-delimited generated region
  inside an owned file. Masks the declared region on each side (a side with
  no markers is compared unmasked; any malformed side bails the whole
  comparison to raw content) and classifies the normalized result as
  no-upstream-change, no-adopter-drift, already-latest, or conflict.

  Read-only: never writes a file. The /update-gaia skill uses the verdict to
  decide whether the path needs a conflict patch.

  Exit codes:
    0  success (every verdict, including malformed or absent markers)
    1  user-correctable error (missing flag / file, empty marker, unreadable file)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

export type RegionMergeReport = {
  markers: {
    /** True when any side scanned malformed, so NO side was masked. */
    bailed: boolean;
    baseline: RegionSideState;
    current: RegionSideState;
    latest: RegionSideState;
  };
  normalized: {baseline: string; current: string; latest: string};
  verdict:
    'already-latest' | 'conflict' | 'no-adopter-drift' | 'no-upstream-change';
};

export type RegionSideState = {
  /** Present only when `scan` is 'malformed'. */
  detail?: RegionMalformation;
  /** Whether this side's content was actually masked in `normalized`. */
  masked: boolean;
  /** What the parser saw on this side. */
  scan: 'absent' | 'malformed' | 'region';
};

type Flags = {
  baseline: string;
  current: string;
  endMarker: string;
  json: boolean;
  latest: string;
  startMarker: string;
};

type ParsedFlagsResult =
  {flags: Flags; ok: true} | {message: string; ok: false};

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

const VALUE_FLAGS: Readonly<Record<string, keyof Flags>> = {
  '--baseline': 'baseline',
  '--current': 'current',
  '--end-marker': 'endMarker',
  '--latest': 'latest',
  '--start-marker': 'startMarker',
};

// `Record<string, T>` indexing types as `T`, never `undefined`, without
// `noUncheckedIndexedAccess` — but `token` may not be one of VALUE_FLAGS'
// five known keys, and that absence is exactly what routes to the
// unknown-flag branch below.
const lookupValueFlag = (token: string): keyof Flags | undefined =>
  (VALUE_FLAGS as Record<string, keyof Flags | undefined>)[token];

const parseFlags = (argv: readonly string[]): ParsedFlagsResult => {
  const collected: Partial<Record<keyof Flags, string>> = {};
  let json = false;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    const field = lookupValueFlag(token);

    if (token === '--json') {
      json = true;
    } else if (field === undefined) {
      return {message: `unknown flag: ${token}`, ok: false};
    } else {
      const taken = takeValue(argv, index + 1, token);

      if (!taken.ok) return taken;
      collected[field] = taken.value;
      index += 1;
    }
  }

  const {baseline, current, endMarker, latest, startMarker} = collected;

  if (baseline === undefined)
    return {message: '--baseline is required', ok: false};

  if (latest === undefined) return {message: '--latest is required', ok: false};

  if (current === undefined)
    return {message: '--current is required', ok: false};

  if (startMarker === undefined)
    return {message: '--start-marker is required', ok: false};

  if (endMarker === undefined)
    return {message: '--end-marker is required', ok: false};

  if (startMarker.trim() === '')
    return {message: '--start-marker must not be empty', ok: false};

  if (endMarker.trim() === '')
    return {message: '--end-marker must not be empty', ok: false};

  return {
    flags: {baseline, current, endMarker, json, latest, startMarker},
    ok: true,
  };
};

const resolveVerdict = (normalized: {
  baseline: string;
  current: string;
  latest: string;
}): RegionMergeReport['verdict'] => {
  if (normalized.baseline === normalized.latest) return 'no-upstream-change';
  if (normalized.current === normalized.baseline) return 'no-adopter-drift';
  if (normalized.current === normalized.latest) return 'already-latest';

  return 'conflict';
};

const buildSideState = (scan: RegionScan, masked: boolean): RegionSideState =>
  scan.kind === 'malformed' ?
    {detail: scan.reason, masked, scan: scan.kind}
  : {masked, scan: scan.kind};

/**
 * Pure computation: masks the declared region on each side and classifies
 * the normalized result. No I/O.
 */
/* eslint-disable max-params -- signature frozen by README.md C3 / task-region-oracle.md's interface contract; positional (baseline, latest, current) matches merge-audit-ci.ts and merge-workspace.ts, plus the marker pair the other two oracles don't need. */
export const computeRegionMerge = (
  baseline: string,
  latest: string,
  current: string,
  startMarker: string,
  endMarker: string
): RegionMergeReport => {
  const baselineMask = maskRegion(baseline, startMarker, endMarker);
  const latestMask = maskRegion(latest, startMarker, endMarker);
  const currentMask = maskRegion(current, startMarker, endMarker);

  const bailed = [baselineMask.scan, latestMask.scan, currentMask.scan].some(
    (scan) => scan.kind === 'malformed'
  );

  const normalized =
    bailed ?
      {baseline, current, latest}
    : {
        baseline: baselineMask.masked,
        current: currentMask.masked,
        latest: latestMask.masked,
      };

  const markers = {
    bailed,
    baseline: buildSideState(
      baselineMask.scan,
      !bailed && baselineMask.scan.kind === 'region'
    ),
    current: buildSideState(
      currentMask.scan,
      !bailed && currentMask.scan.kind === 'region'
    ),
    latest: buildSideState(
      latestMask.scan,
      !bailed && latestMask.scan.kind === 'region'
    ),
  };

  return {markers, normalized, verdict: resolveVerdict(normalized)};
};
/* eslint-enable max-params */

const describeSide = (side: RegionSideState): string => {
  const detail = side.detail === undefined ? '' : `/${side.detail}`;

  return `${side.scan}${detail} (masked: ${side.masked})`;
};

const printHuman = (report: RegionMergeReport): void => {
  const lines = [
    'gaia update merge-region',
    `  Verdict:  ${report.verdict}`,
    `  Bailed:   ${report.markers.bailed}`,
    `  Baseline: ${describeSide(report.markers.baseline)}`,
    `  Latest:   ${describeSide(report.markers.latest)}`,
    `  Current:  ${describeSide(report.markers.current)}`,
  ];

  process.stdout.write(`${lines.join('\n')}\n`);
};

type LoadResult =
  | {
      code: 'region_file_missing' | 'region_read_failed';
      message: string;
      ok: false;
    }
  | {content: string; ok: true};

const loadRegionFile = (absPath: string, role: string): LoadResult => {
  if (!existsSync(absPath)) {
    return {
      code: 'region_file_missing',
      message: `${role} file not found: ${absPath}`,
      ok: false,
    };
  }

  try {
    return {content: readFileSync(absPath, 'utf8'), ok: true};
  } catch (error) {
    return {
      code: 'region_read_failed',
      message: `${role} file could not be read (${absPath}): ${
        error instanceof Error ? error.message : String(error)
      }`,
      ok: false,
    };
  }
};

type RunOptions = {
  cwd?: string;
};

const resolvePath = (cwd: string, value: string): string =>
  path.isAbsolute(value) ? value : path.join(cwd, value);

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
      subcommand: 'update merge-region',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const inputs: [string, string][] = [
    ['baseline', resolvePath(cwd, parsed.flags.baseline)],
    ['latest', resolvePath(cwd, parsed.flags.latest)],
    ['current', resolvePath(cwd, parsed.flags.current)],
  ];

  const contents: string[] = [];

  for (const [role, absPath] of inputs) {
    const result = loadRegionFile(absPath, role);

    if (!result.ok) {
      structuredError({
        code: result.code,
        message: result.message,
        subcommand: 'update merge-region',
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }

    contents.push(result.content);
  }

  const [baseline, latest, current] = contents as [string, string, string];
  const report = computeRegionMerge(
    baseline,
    latest,
    current,
    parsed.flags.startMarker,
    parsed.flags.endMarker
  );

  if (parsed.flags.json) {
    process.stdout.write(`${JSON.stringify(report)}\n`);
  } else {
    printHuman(report);
  }

  return EXIT_CODES.OK;
};
