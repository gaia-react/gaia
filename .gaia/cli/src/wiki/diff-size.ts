/**
 * `gaia wiki diff-size` handler.
 *
 * Computes how much of `wiki/**` changed between a base ref (default
 * `HEAD~1`) and `HEAD`, expressed as a percentage of the base tree's line
 * count. Used by the auto-merge partial in
 * `automation/templates/workflows/partials/auto-merge.yml.tmpl` to gate
 * automatic merging when a CI run produces an outsized wiki diff.
 *
 * Numerator: `lines_added + lines_removed` summed across changed wiki
 * files via `git diff --numstat`. Matches what `git diff --shortstat`
 * reports.
 * Denominator: total line count of `wiki/**` at the base ref.
 *
 * Output: prints `exceeded` or `ok` (newline-terminated) to stdout. The
 * auto-merge partial reads the trimmed value via `$(...)` and matches on
 * `= "exceeded"`. `--json` emits a structured object instead.
 */
import {execFileSync} from 'node:child_process';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';

const HELP_TEXT = `Usage: gaia wiki diff-size --threshold-pct <N> [--base <ref>] [--json]

  Compute wiki/** lines-changed (added + removed) between <base> (default
  HEAD~1) and HEAD as a percentage of the base tree's wiki line count.
  Prints "exceeded" if the ratio is strictly greater than <N>, else "ok".

  --threshold-pct N   Required. Integer or decimal; comparison is strict.
  --base <ref>        Git ref to diff against. Default: HEAD~1.
  --json              Emit { decision, ratio_pct, base_lines,
                      changed_lines, threshold_pct } instead of the bare
                      keyword.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const WIKI_PREFIX = 'wiki/';

type DiffSizeResult = {
  baseLines: number;
  changedLines: number;
  decision: 'exceeded' | 'ok';
  ratioPct: number;
  thresholdPct: number;
};

type ComputeOptions = {
  base?: string;
  cwd: string;
  thresholdPct: number;
};

const git = (cwd: string, args: readonly string[]): string =>
  execFileSync('git', ['-C', cwd, ...args], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });

/**
 * List `(path, size_bytes)` tuples for every blob under `wiki/` at the
 * given ref. Returns an empty list when the ref has no `wiki/` subtree.
 */
const wikiBlobsAtRef = (
  cwd: string,
  ref: string
): readonly {path: string; sizeBytes: number}[] => {
  let raw: string;

  try {
    raw = git(cwd, ['ls-tree', '-r', '-l', ref, '--', 'wiki/']);
  } catch {
    return [];
  }

  const out: {path: string; sizeBytes: number}[] = [];

  for (const line of raw.split('\n')) {
    if (line.length === 0) continue;
    // ls-tree -l format: "<mode> <type> <object> <size>\t<path>"
    const tab = line.indexOf('\t');

    if (tab === -1) continue;

    const meta = line.slice(0, tab).trim().split(/\s+/);
    const sizeToken = meta[3];
    const filePath = line.slice(tab + 1);

    if (sizeToken === undefined || sizeToken === '-') continue;

    const sizeBytes = Number.parseInt(sizeToken, 10);

    if (!Number.isNaN(sizeBytes)) out.push({path: filePath, sizeBytes});
  }

  return out;
};

/**
 * Returns the line count of `<ref>:<path>`, defined as the number of `\n`
 * occurrences in the blob. Files with no trailing newline still report
 * their internal newline count, matching `wc -l` on a piped blob.
 */
const blobLineCount = (cwd: string, ref: string, filePath: string): number => {
  let raw: string;

  try {
    raw = git(cwd, ['cat-file', '-p', `${ref}:${filePath}`]);
  } catch {
    return 0;
  }

  let count = 0;

  for (const char of raw) if (char === '\n') count += 1;

  return count;
};

const sumWikiLinesAtRef = (cwd: string, ref: string): number => {
  let total = 0;

  for (const blob of wikiBlobsAtRef(cwd, ref)) {
    total += blobLineCount(cwd, ref, blob.path);
  }

  return total;
};

/**
 * Sum `lines_added + lines_removed` across all `wiki/**` files in the
 * `<base>...HEAD` diff. Binary files (numstat reports `-\t-`) are
 * skipped — the wiki vault is text-only, so this is informational.
 */
const sumChangedLines = (cwd: string, base: string): number => {
  let raw: string;

  try {
    raw = git(cwd, [
      'diff',
      '--numstat',
      '-z',
      `${base}...HEAD`,
      '--',
      'wiki/',
    ]);
  } catch {
    return 0;
  }

  let total = 0;

  for (const entry of raw.split('\0')) {
    if (entry.length === 0) continue;
    if (!entry.includes('\t')) continue;

    const parts = entry.split('\t');
    const addedToken = parts[0];
    const removedToken = parts[1];
    const filePath = parts[2];

    if (
      addedToken === undefined ||
      removedToken === undefined ||
      filePath === undefined
    )
      continue;

    if (!filePath.startsWith(WIKI_PREFIX)) continue;
    if (addedToken === '-' || removedToken === '-') continue;

    const added = Number.parseInt(addedToken, 10);
    const removed = Number.parseInt(removedToken, 10);

    if (!Number.isNaN(added)) total += added;
    if (!Number.isNaN(removed)) total += removed;
  }

  return total;
};

export const computeDiffSize = (options: ComputeOptions): DiffSizeResult => {
  const base = options.base ?? 'HEAD~1';
  const baseLines = sumWikiLinesAtRef(options.cwd, base);
  const changedLines = sumChangedLines(options.cwd, base);

  const ratioPct = baseLines === 0
    ? changedLines === 0
      ? 0
      : Number.POSITIVE_INFINITY
    : (changedLines / baseLines) * 100;

  const decision: DiffSizeResult['decision'] =
    ratioPct > options.thresholdPct ? 'exceeded' : 'ok';

  return {
    baseLines,
    changedLines,
    decision,
    ratioPct,
    thresholdPct: options.thresholdPct,
  };
};

type ParsedArgs = {
  base?: string;
  json: boolean;
  thresholdPct: number;
};

type ParseError = {
  error: string;
};

const parseArgs = (argv: readonly string[]): ParsedArgs | ParseError => {
  let json = false;
  let thresholdPct: number | undefined;
  let base: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--json') {
      json = true;
      continue;
    }
    if (token === '--threshold-pct') {
      const value = argv[index + 1];

      if (value === undefined) {
        return {error: '--threshold-pct requires a numeric value'};
      }

      const parsed = Number.parseFloat(value);

      if (!Number.isFinite(parsed)) {
        return {error: `--threshold-pct must be numeric, got: ${value}`};
      }
      thresholdPct = parsed;
      index += 1;
      continue;
    }
    if (token === '--base') {
      const value = argv[index + 1];

      if (value === undefined || value.length === 0) {
        return {error: '--base requires a ref'};
      }
      base = value;
      index += 1;
      continue;
    }

    return {error: `unknown flag: ${token}`};
  }

  if (thresholdPct === undefined) {
    return {error: '--threshold-pct is required'};
  }

  return {base, json, thresholdPct};
};

type RunOptions = {
  cwd?: string;
};

const emitJson = (result: DiffSizeResult): void => {
  const payload = {
    base_lines: result.baseLines,
    changed_lines: result.changedLines,
    decision: result.decision,
    ratio_pct: Number.isFinite(result.ratioPct) ? result.ratioPct : null,
    threshold_pct: result.thresholdPct,
  };
  process.stdout.write(`${JSON.stringify(payload, null, 2)}\n`);
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  for (const token of argv) {
    if (HELP_TOKENS.has(token)) {
      process.stdout.write(HELP_TEXT);

      return EXIT_CODES.OK;
    }
  }

  const parsed = parseArgs(argv);

  if ('error' in parsed) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.error,
      subcommand: 'wiki diff-size',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  try {
    const cwd = options.cwd ?? process.cwd();
    const result = computeDiffSize({
      base: parsed.base,
      cwd,
      thresholdPct: parsed.thresholdPct,
    });

    if (parsed.json) {
      emitJson(result);
    } else {
      process.stdout.write(`${result.decision}\n`);
    }

    return EXIT_CODES.OK;
  } catch (error) {
    structuredError({
      code: 'diff_size_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'wiki diff-size',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }
};
