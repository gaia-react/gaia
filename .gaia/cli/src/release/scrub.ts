/**
 * `gaia-maintainer release scrub` handler.
 *
 * Bundle-time discipline for the GAIA release tarball. Runs inside
 * `release.yml` between the staging step (rsync from `git ls-files` minus
 * `.gaia/release-exclude`) and the final `tar -czf`. Three transforms run
 * in order against the staging tree:
 *
 *   1. marker-strip — remove maintainer-only blocks delimited by HTML
 *      comment markers. Source becomes superset; bundle is subset.
 *
 *   2. json-strip — delete maintainer-only keys from structured JSON files
 *      using dot-notation paths (e.g. "scripts.test:forensics"). Dots are
 *      path separators; key names must not contain literal dots.
 *
 *   3. leak-check — run codified audit patterns from
 *      `.claude/rules/wiki-style.md` Audit section + the distribution-
 *      boundary classes in `.gaia/cli/health/taxonomy.md` against the
 *      post-strip staging tree. Non-empty match = build failure with a
 *      structured leak report.
 *
 * Read-only on the source repo. Writes happen in place inside the
 * staging directory.
 *
 * Exit codes:
 *   0 — clean (no leaks; transforms applied successfully)
 *   1 — user-correctable (leaks detected, unbalanced markers, missing
 *       staging dir, malformed config flags)
 *   2 — unexpected (config parse error, filesystem IO failure)
 */
import {readdirSync, readFileSync, statSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {load as parseYaml} from 'js-yaml';
import {z} from 'zod';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';

const HELP_TEXT = `Usage: gaia-maintainer release scrub <staging-dir> [--config <path>] [--json]

  Apply bundle-time scrub transforms (marker-strip + leak-check) to a
  staging directory produced by release.yml. Writes in place inside
  <staging-dir>; treats the source repo as read-only.

  Flags:
    --config <path>  Override config path (default: .gaia/release-scrub.yml
                     resolved against process.cwd()).
    --json           Emit a structured JSON report on stdout instead of
                     human-readable summary.

  Exit codes:
    0  clean
    1  leaks detected, unbalanced markers, missing staging dir, bad flags
    2  config parse error or filesystem IO failure
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const UNEXPECTED_EXIT = 2;
const DEFAULT_CONFIG_PATH = '.gaia/release-scrub.yml';

// ---------------------------------------------------------------------------
// Config schema
// ---------------------------------------------------------------------------

const MarkerStripSchema = z.object({
  end: z.string().min(1),
  paths: z.array(z.string().min(1)).min(1),
  start: z.string().min(1),
  type: z.literal('marker-strip'),
});

const LeakCheckSchema = z.object({
  checks: z
    .array(
      z.object({
        description: z.string().optional(),
        id: z.string().min(1),
        'line-allowlist': z.array(z.string()).optional(),
        'path-allowlist': z.array(z.string()).optional(),
        pattern: z.string().min(1),
        scope: z.array(z.string().min(1)).min(1),
      })
    )
    .min(1),
  type: z.literal('leak-check'),
});

const JsonStripSchema = z.object({
  keys: z.array(z.string().min(1)).min(1),
  paths: z.array(z.string().min(1)).min(1),
  type: z.literal('json-strip'),
});

const ConfigSchema = z.object({
  transforms: z
    .array(z.union([MarkerStripSchema, JsonStripSchema, LeakCheckSchema]))
    .min(1),
});

export type ScrubConfig = z.infer<typeof ConfigSchema>;
type MarkerStripTransform = z.infer<typeof MarkerStripSchema>;
type JsonStripTransform = z.infer<typeof JsonStripSchema>;
type LeakCheckTransform = z.infer<typeof LeakCheckSchema>;
type LeakCheckEntry = LeakCheckTransform['checks'][number];

// ---------------------------------------------------------------------------
// Glob → regex
// ---------------------------------------------------------------------------

const REGEX_SPECIAL = /[.+^$()[\]{}|\\]/g;
const SENTINEL_DIRSTAR = ' DIRSTAR ';
const SENTINEL_STAR = ' STAR ';

/**
 * Convert a posix-style glob (`**`, `*`) into an anchored RegExp. Globs are
 * matched against repo-relative POSIX paths.
 */
export const globToRegex = (glob: string): RegExp => {
  const escaped = glob.replaceAll(REGEX_SPECIAL, String.raw`\$&`);
  const transformed = escaped
    .replaceAll('**/', SENTINEL_DIRSTAR)
    .replaceAll('**', SENTINEL_STAR)
    .replaceAll('*', '[^/]*')
    .replaceAll(SENTINEL_STAR, '.*')
    .replaceAll(SENTINEL_DIRSTAR, '(?:.*/)?');

  return new RegExp(`^${transformed}$`);
};

const matchesAnyGlob = (
  relativePath: string,
  globs: readonly string[]
): boolean => globs.some((glob) => globToRegex(glob).test(relativePath));

// ---------------------------------------------------------------------------
// Walk
// ---------------------------------------------------------------------------

const walkFiles = (root: string, current: string = root): string[] => {
  const out: string[] = [];

  for (const entry of readdirSync(current, {withFileTypes: true})) {
    const full = path.join(current, entry.name);

    if (entry.isDirectory()) {
      out.push(...walkFiles(root, full));
      continue;
    }

    if (entry.isFile()) {
      out.push(path.relative(root, full).split(path.sep).join('/'));
    }
  }

  return out;
};

// ---------------------------------------------------------------------------
// Marker strip
// ---------------------------------------------------------------------------

export type MarkerStripResult = {
  blocksStripped: number;
  filesTouched: readonly string[];
  unbalanced: ReadonlyArray<{
    file: string;
    line: number;
    reason: 'start_without_end' | 'end_without_start';
  }>;
};

const stripMarkerBlocks = (
  source: string,
  startMarker: string,
  endMarker: string
): {
  blocks: number;
  output: string;
  unbalanced: Array<{
    line: number;
    reason: 'end_without_start' | 'start_without_end';
  }>;
} => {
  const lines = source.split('\n');
  const out: string[] = [];
  const unbalanced: Array<{
    line: number;
    reason: 'end_without_start' | 'start_without_end';
  }> = [];
  let inBlock = false;
  let blockStartLine = 0;
  let blocks = 0;

  for (const [index, line] of lines.entries()) {
    const lineNumber = index + 1;
    const hasStart = line.includes(startMarker);
    const hasEnd = line.includes(endMarker);

    if (!inBlock && hasStart && hasEnd) {
      // Single-line block: drop the entire line.
      blocks += 1;
      continue;
    }

    if (!inBlock && hasStart) {
      inBlock = true;
      blockStartLine = lineNumber;
      continue;
    }

    if (inBlock && hasEnd) {
      inBlock = false;
      blocks += 1;
      continue;
    }

    if (!inBlock && hasEnd) {
      unbalanced.push({line: lineNumber, reason: 'end_without_start'});
      out.push(line);
      continue;
    }

    if (!inBlock) out.push(line);
  }

  if (inBlock) {
    unbalanced.push({line: blockStartLine, reason: 'start_without_end'});
  }

  return {blocks, output: out.join('\n'), unbalanced};
};

const applyMarkerStrip = (
  stagingRoot: string,
  files: readonly string[],
  transform: MarkerStripTransform
): MarkerStripResult => {
  const filesTouched: string[] = [];
  const unbalanced: Array<{
    file: string;
    line: number;
    reason: 'end_without_start' | 'start_without_end';
  }> = [];
  let blocksStripped = 0;

  for (const relativePath of files) {
    if (!matchesAnyGlob(relativePath, transform.paths)) continue;

    const absolutePath = path.join(stagingRoot, relativePath);
    const source = readFileSync(absolutePath, 'utf8');

    if (!source.includes(transform.start) && !source.includes(transform.end)) {
      continue;
    }

    const result = stripMarkerBlocks(source, transform.start, transform.end);

    for (const issue of result.unbalanced) {
      unbalanced.push({file: relativePath, line: issue.line, reason: issue.reason});
    }

    if (result.blocks > 0) {
      writeFileSync(absolutePath, result.output, 'utf8');
      filesTouched.push(relativePath);
      blocksStripped += result.blocks;
    }
  }

  return {blocksStripped, filesTouched, unbalanced};
};

// ---------------------------------------------------------------------------
// JSON strip
// ---------------------------------------------------------------------------

export type JsonStripResult = {
  filesTouched: readonly string[];
  keysRemoved: number;
};

const deleteKeyPath = (
  obj: Record<string, unknown>,
  segments: readonly string[]
): boolean => {
  if (segments.length === 0) return false;

  const [head, ...rest] = segments as [string, ...string[]];

  if (rest.length === 0) {
    if (!Object.prototype.hasOwnProperty.call(obj, head)) return false;

    delete obj[head];

    return true;
  }

  const next = obj[head];

  if (typeof next !== 'object' || next === null || Array.isArray(next)) {
    return false;
  }

  return deleteKeyPath(next as Record<string, unknown>, rest);
};

const applyJsonStrip = (
  stagingRoot: string,
  files: readonly string[],
  transform: JsonStripTransform
): JsonStripResult => {
  const filesTouched: string[] = [];
  let keysRemoved = 0;
  const keySegments = transform.keys.map((k) => k.split('.'));

  for (const relativePath of files) {
    if (!matchesAnyGlob(relativePath, transform.paths)) continue;

    const absolutePath = path.join(stagingRoot, relativePath);
    let parsed: unknown;

    try {
      parsed = JSON.parse(readFileSync(absolutePath, 'utf8'));
    } catch (error) {
      throw new Error(
        `Failed to parse JSON at ${relativePath}: ${error instanceof Error ? error.message : String(error)}`
      );
    }

    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      continue;
    }

    const obj = parsed as Record<string, unknown>;
    let removed = 0;

    for (const segments of keySegments) {
      if (deleteKeyPath(obj, segments)) removed++;
    }

    if (removed > 0) {
      writeFileSync(absolutePath, `${JSON.stringify(obj, null, 2)}\n`, 'utf8');
      filesTouched.push(relativePath);
      keysRemoved += removed;
    }
  }

  return {filesTouched, keysRemoved};
};

// ---------------------------------------------------------------------------
// Leak check
// ---------------------------------------------------------------------------

export type Leak = {
  check: string;
  file: string;
  line: number;
  match: string;
};

const runLeakCheck = (
  stagingRoot: string,
  files: readonly string[],
  check: LeakCheckEntry
): readonly Leak[] => {
  const pattern = new RegExp(check.pattern);
  const lineAllowlist = (check['line-allowlist'] ?? []).map(
    (raw) => new RegExp(raw)
  );
  const pathAllowlist = check['path-allowlist'] ?? [];
  const leaks: Leak[] = [];

  for (const relativePath of files) {
    if (!matchesAnyGlob(relativePath, check.scope)) continue;
    if (matchesAnyGlob(relativePath, pathAllowlist)) continue;

    const source = readFileSync(path.join(stagingRoot, relativePath), 'utf8');
    const lines = source.split('\n');

    for (const [index, line] of lines.entries()) {
      if (lineAllowlist.some((rx) => rx.test(line))) continue;

      const match = pattern.exec(line);

      if (match === null) continue;

      leaks.push({
        check: check.id,
        file: relativePath,
        line: index + 1,
        match: match[0],
      });
    }
  }

  return leaks;
};

// ---------------------------------------------------------------------------
// Config loading
// ---------------------------------------------------------------------------

export const loadConfig = (configPath: string): ScrubConfig => {
  const raw = readFileSync(configPath, 'utf8');
  const parsed = parseYaml(raw);

  return ConfigSchema.parse(parsed);
};

// ---------------------------------------------------------------------------
// Flags
// ---------------------------------------------------------------------------

type Flags = {
  configPath: string | undefined;
  json: boolean;
  stagingDir: string | undefined;
};

type FlagParseSuccess = {flags: Flags; ok: true};
type FlagParseFailure = {message: string; ok: false};
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
  let configPath: string | undefined;
  let json = false;
  let stagingDir: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string;

    if (token === '--config') {
      const taken = takeValue(argv, index + 1, '--config');

      if (!taken.ok) return taken;
      configPath = taken.value;
      index += 1;
      continue;
    }

    if (token === '--json') {
      json = true;
      continue;
    }

    if (token.startsWith('--')) {
      return {message: `unknown flag: ${token}`, ok: false};
    }

    if (stagingDir !== undefined) {
      return {message: `unexpected positional: ${token}`, ok: false};
    }

    stagingDir = token;
  }

  return {flags: {configPath, json, stagingDir}, ok: true};
};

// ---------------------------------------------------------------------------
// Run
// ---------------------------------------------------------------------------

type Report = {
  json_strip: {
    files_touched: readonly string[];
    keys_removed: number;
  };
  leaks: readonly Leak[];
  marker_strip: {
    blocks_stripped: number;
    files_touched: readonly string[];
  };
  unbalanced_markers: ReadonlyArray<{
    file: string;
    line: number;
    reason: string;
  }>;
};

type RunOptions = {
  cwd?: string;
};

const renderHumanReport = (report: Report, jsonMode: boolean): string => {
  if (jsonMode) return `${JSON.stringify(report, null, 2)}\n`;

  const out: string[] = [];

  out.push(
    `release scrub: stripped ${report.marker_strip.blocks_stripped} marker block(s) across ${report.marker_strip.files_touched.length} file(s)`
  );
  out.push(
    `release scrub: removed ${report.json_strip.keys_removed} json key(s) from ${report.json_strip.files_touched.length} file(s)`
  );

  if (report.unbalanced_markers.length > 0) {
    out.push('', `unbalanced markers (${report.unbalanced_markers.length}):`);

    for (const issue of report.unbalanced_markers) {
      out.push(`  ${issue.file}:${issue.line}  ${issue.reason}`);
    }
  }

  if (report.leaks.length > 0) {
    out.push('', `leaks (${report.leaks.length}):`);

    for (const leak of report.leaks) {
      out.push(`  [${leak.check}] ${leak.file}:${leak.line}  ${leak.match}`);
    }
  } else {
    out.push('leaks: none');
  }

  return `${out.join('\n')}\n`;
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
      subcommand: 'release scrub',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (parsed.flags.stagingDir === undefined) {
    structuredError({
      code: 'missing_staging_dir',
      message: 'staging directory argument required',
      subcommand: 'release scrub',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const stagingDir = path.isAbsolute(parsed.flags.stagingDir)
    ? parsed.flags.stagingDir
    : path.join(cwd, parsed.flags.stagingDir);
  const configPath = parsed.flags.configPath
    ? (path.isAbsolute(parsed.flags.configPath)
      ? parsed.flags.configPath
      : path.join(cwd, parsed.flags.configPath))
    : path.join(cwd, DEFAULT_CONFIG_PATH);

  try {
    statSync(stagingDir);
  } catch {
    structuredError({
      code: 'staging_dir_missing',
      message: `staging directory not found: ${stagingDir}`,
      subcommand: 'release scrub',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let config: ScrubConfig;

  try {
    config = loadConfig(configPath);
  } catch (error) {
    structuredError({
      code: 'config_load_failed',
      message: error instanceof Error ? error.message : String(error),
      path: configPath,
      subcommand: 'release scrub',
    });

    return UNEXPECTED_EXIT;
  }

  let stagedFiles: readonly string[];

  try {
    stagedFiles = walkFiles(stagingDir);
  } catch (error) {
    structuredError({
      code: 'staging_walk_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'release scrub',
    });

    return UNEXPECTED_EXIT;
  }

  let stripBlocks = 0;
  const stripFiles: string[] = [];
  const unbalanced: Array<{file: string; line: number; reason: string}> = [];
  let jsonStripKeysRemoved = 0;
  const jsonStripFiles: string[] = [];
  const leaks: Leak[] = [];

  try {
    for (const transform of config.transforms) {
      if (transform.type === 'marker-strip') {
        const result = applyMarkerStrip(stagingDir, stagedFiles, transform);
        stripBlocks += result.blocksStripped;
        stripFiles.push(...result.filesTouched);

        for (const issue of result.unbalanced) unbalanced.push(issue);
        continue;
      }

      if (transform.type === 'json-strip') {
        const result = applyJsonStrip(stagingDir, stagedFiles, transform);
        jsonStripKeysRemoved += result.keysRemoved;
        jsonStripFiles.push(...result.filesTouched);
        continue;
      }

      // After marker-strip and json-strip land, leak-check sees the
      // post-strip tree because we re-read each file fresh inside runLeakCheck.
      for (const check of transform.checks) {
        leaks.push(...runLeakCheck(stagingDir, stagedFiles, check));
      }
    }
  } catch (error) {
    structuredError({
      code: 'transform_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'release scrub',
    });

    return UNEXPECTED_EXIT;
  }

  const report: Report = {
    json_strip: {
      files_touched: jsonStripFiles,
      keys_removed: jsonStripKeysRemoved,
    },
    leaks,
    marker_strip: {
      blocks_stripped: stripBlocks,
      files_touched: stripFiles,
    },
    unbalanced_markers: unbalanced,
  };

  process.stdout.write(renderHumanReport(report, parsed.flags.json));

  if (unbalanced.length > 0 || leaks.length > 0) {
    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  return EXIT_CODES.OK;
};
