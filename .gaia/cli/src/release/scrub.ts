/**
 * `gaia-maintainer release scrub` handler.
 *
 * Bundle-time discipline for the GAIA release tarball. Runs inside
 * `release.yml` between the staging step (rsync from `git ls-files` minus
 * `.gaia/release-exclude`) and the final `tar -czf`. Three transforms run
 * in order against the staging tree:
 *
 *   1. marker-strip: remove maintainer-only blocks delimited by HTML
 *      comment markers. Source becomes superset; bundle is subset.
 *
 *   2. json-strip: delete maintainer-only keys from structured JSON files
 *      using dot-notation paths (e.g. "scripts.test:forensics"). Dots are
 *      path separators; a literal dot inside a key name is escaped as `\.`.
 *
 *   3. leak-check: run codified audit patterns from
 *      `.claude/rules/wiki-style.md` Audit section + the distribution-
 *      boundary classes in `.gaia/cli/health/taxonomy.md` against the
 *      post-strip staging tree. Non-empty match = build failure with a
 *      structured leak report.
 *
 * Read-only on the source repo. Writes happen in place inside the
 * staging directory.
 *
 * Exit codes:
 *   0: clean (no leaks; transforms applied successfully)
 *   1: user-correctable (leaks detected, unbalanced markers, missing
 *       staging dir, malformed config flags)
 *   2: unexpected (config parse error, filesystem IO failure)
 */
import {existsSync, readdirSync, readFileSync, statSync} from 'node:fs';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import path from 'node:path';
import {load as parseYaml} from 'js-yaml';
import {z} from 'zod';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {extractWikilinks} from '../wiki/util/wikilinks.js';
import {parseExcludeLines} from './manifest.js';

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
const RELEASE_EXCLUDE_PATH = '.gaia/release-exclude';
const WORKFLOWS_DIR = '.github/workflows';
const SHIPPED_WORKFLOW_TEMPLATES_DIR = '.gaia/cli/templates/workflows';

// ---------------------------------------------------------------------------
// Config schema
// ---------------------------------------------------------------------------

const MarkerStripSchema = z.object({
  end: z.string().min(1),
  paths: z.array(z.string().min(1)).min(1),
  start: z.string().min(1),
  type: z.literal('marker-strip'),
});

const leakCheckBaseShape = {
  description: z.string().optional(),
  id: z.string().min(1),
  'line-allowlist': z.array(z.string()).optional(),
  'path-allowlist': z.array(z.string()).optional(),
  scope: z.array(z.string().min(1)).min(1),
};

// A static check runs a literal regex line-by-line. A derived check builds its
// match set at scan time instead, from `.gaia/release-exclude`, so it cannot
// drift away from the manifest the way a hand-maintained alternation does:
//   - `excluded-slugs`: the release-excluded wiki-slug set (wikilink-to-excluded).
//   - `excluded-workflows`: release-excluded `.github/workflows/*.yml` that never
//     reach an adopter (no on-demand render template), whose curated-regex gap is
//     what the `maintainer-paths` check structurally cannot close.
const StaticLeakCheckSchema = z.object({
  ...leakCheckBaseShape,
  pattern: z.string().min(1),
});

const DerivedLeakCheckSchema = z.object({
  ...leakCheckBaseShape,
  derive: z.literal(['excluded-slugs', 'excluded-workflows']),
});

const LeakCheckSchema = z.object({
  checks: z
    .array(z.union([DerivedLeakCheckSchema, StaticLeakCheckSchema]))
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
type StaticLeakCheck = z.infer<typeof StaticLeakCheckSchema>;
type DerivedLeakCheck = z.infer<typeof DerivedLeakCheckSchema>;

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
  unbalanced: readonly {
    file: string;
    line: number;
    reason: 'start_without_end' | 'end_without_start';
  }[];
};

const stripMarkerBlocks = (
  source: string,
  startMarker: string,
  endMarker: string
): {
  blocks: number;
  output: string;
  unbalanced: {
    line: number;
    reason: 'end_without_start' | 'start_without_end';
  }[];
} => {
  const lines = source.split('\n');
  const out: string[] = [];
  const unbalanced: {
    line: number;
    reason: 'end_without_start' | 'start_without_end';
  }[] = [];
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
  const unbalanced: {
    file: string;
    line: number;
    reason: 'end_without_start' | 'start_without_end';
  }[] = [];
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
      unbalanced.push({
        file: relativePath,
        line: issue.line,
        reason: issue.reason,
      });
    }

    if (result.blocks > 0) {
      atomicWriteFileSync(absolutePath, result.output);
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

/**
 * Split a dot-notation key path into segments. A literal `.` inside a key
 * name is expressed with a backslash escape (`\.`), so a package.json key
 * that contains a dot, e.g. `exports.\.\/feature`, stays addressable.
 *
 * `scripts.test:forensics` → `['scripts', 'test:forensics']`
 * String.raw`scripts.foo\.bar` → `['scripts', 'foo.bar']`
 *
 * A trailing lone backslash is treated literally.
 *
 * Rejects malformed input: an empty segment (produced by a leading,
 * trailing, or doubled dot, or an empty key string) is never a valid
 * object key path, so it throws rather than silently mis-targeting.
 */
export const parseKeyPath = (key: string): string[] => {
  const segments: string[] = [];
  let current = '';

  for (let index = 0; index < key.length; index += 1) {
    const char = key[index];

    if (char === '\\' && key[index + 1] === '.') {
      current += '.';
      index += 1;
      continue;
    }

    if (char === '.') {
      segments.push(current);
      current = '';
      continue;
    }

    current += char;
  }

  segments.push(current);

  if (segments.some((segment) => segment.length === 0)) {
    throw new Error(
      `malformed key path "${key}": empty segment (leading/trailing/double dot)`
    );
  }

  return segments;
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
  const keySegments = transform.keys.map((k) => parseKeyPath(k));

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

    if (
      typeof parsed !== 'object' ||
      parsed === null ||
      Array.isArray(parsed)
    ) {
      continue;
    }

    const obj = parsed as Record<string, unknown>;
    let removed = 0;

    for (const segments of keySegments) {
      if (deleteKeyPath(obj, segments)) removed++;
    }

    if (removed > 0) {
      atomicWriteFileSync(absolutePath, `${JSON.stringify(obj, null, 2)}\n`);
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
  check: StaticLeakCheck
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
// Derived wikilink-to-excluded check
// ---------------------------------------------------------------------------

const isDerivedCheck = (check: LeakCheckEntry): check is DerivedLeakCheck =>
  'derive' in check;

const slugFromPath = (filePath: string): string =>
  path.basename(filePath, '.md');

const isDirectory = (absolutePath: string): boolean => {
  try {
    return statSync(absolutePath).isDirectory();
  } catch {
    return false;
  }
};

/**
 * Build the set of release-excluded wiki slugs from `.gaia/release-exclude`
 * resolved against `cwd`, the source repo.
 *
 * Reading from `cwd` is load-bearing: `release-exclude` excludes itself, so it
 * never reaches the staging tree the other checks scan. Deriving from staging
 * would yield an empty set and pass silently, worse than the drift this fix
 * removes.
 *
 * A `.md` exclude contributes its basename slug directly. A bare-directory
 * exclude contributes the directory's own slug plus the slug of every `.md`
 * page beneath it, the entity pages and dated audit artifacts that are never
 * enumerated as their own exclude lines. Slugs are lowercased for the
 * case-insensitive matching Obsidian uses to resolve wikilinks.
 */
const buildExcludedSlugSet = (cwd: string): Set<string> => {
  const lines = parseExcludeLines(
    readFileSync(path.join(cwd, RELEASE_EXCLUDE_PATH), 'utf8')
  );
  const slugs = new Set<string>();
  const addSlug = (value: string): void => {
    slugs.add(value.toLowerCase());
  };

  for (const line of lines) {
    if (line !== 'wiki' && !line.startsWith('wiki/')) continue;

    if (line.endsWith('.md')) {
      addSlug(slugFromPath(line));
      continue;
    }

    const absolute = path.join(cwd, line);

    if (!isDirectory(absolute)) continue;

    addSlug(path.basename(line));

    for (const relative of walkFiles(absolute)) {
      if (relative.endsWith('.md')) addSlug(slugFromPath(relative));
    }
  }

  return slugs;
};

const runDerivedWikilinkCheck = (
  stagingRoot: string,
  files: readonly string[],
  check: DerivedLeakCheck,
  cwd: string
): readonly Leak[] => {
  const excludedSlugs = buildExcludedSlugSet(cwd);
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

      for (const target of extractWikilinks(line)) {
        if (!excludedSlugs.has(target.toLowerCase())) continue;

        leaks.push({
          check: check.id,
          file: relativePath,
          line: index + 1,
          match: `[[${target}]]`,
        });
      }
    }
  }

  return leaks;
};

// ---------------------------------------------------------------------------
// Derived excluded-workflow check
// ---------------------------------------------------------------------------

/**
 * Build the set of release-excluded `.github/workflows/*.yml` paths that never
 * reach an adopter machine, derived from `.gaia/release-exclude` resolved
 * against `cwd` (the source repo).
 *
 * `.github/workflows/` is the one distribution-boundary directory where some
 * files ship and some do not, so the curated `maintainer-paths` alternation
 * cannot blanket it (most workflows ship) and cannot enumerate every excluded
 * one without drifting. This set is derived instead: an excluded workflow whose
 * on-demand render template is absent from `.gaia/cli/templates/workflows/` is
 * never installable on an adopter, so a shipped-surface reference to it is a
 * dangling pointer. `code-review-audit.yml` is excluded from the tarball yet
 * DOES have a `.tmpl` (installed on demand by `/setup-gaia`), so references to
 * it are legitimate and it is intentionally kept out of this set.
 *
 * Reading the exclude list from `cwd` mirrors `buildExcludedSlugSet`: the file
 * excludes itself, so it never reaches the staging tree the other checks scan.
 */
const buildNeverPresentWorkflowSet = (cwd: string): Set<string> => {
  const lines = parseExcludeLines(
    readFileSync(path.join(cwd, RELEASE_EXCLUDE_PATH), 'utf8')
  );
  const paths = new Set<string>();

  for (const line of lines) {
    if (!line.startsWith(`${WORKFLOWS_DIR}/`) || !line.endsWith('.yml')) {
      continue;
    }

    const templatePath = path.join(
      cwd,
      SHIPPED_WORKFLOW_TEMPLATES_DIR,
      `${path.basename(line)}.tmpl`
    );

    // A shipped `.tmpl` means the workflow is rendered onto adopters on demand,
    // so a reference to it is not a boundary leak; keep it out of the set.
    if (existsSync(templatePath)) continue;

    paths.add(line);
  }

  return paths;
};

const runDerivedWorkflowCheck = (
  stagingRoot: string,
  files: readonly string[],
  check: DerivedLeakCheck,
  cwd: string
): readonly Leak[] => {
  const neverPresent = buildNeverPresentWorkflowSet(cwd);

  if (neverPresent.size === 0) return [];

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

      for (const excludedPath of neverPresent) {
        if (!line.includes(excludedPath)) continue;

        leaks.push({
          check: check.id,
          file: relativePath,
          line: index + 1,
          match: excludedPath,
        });
      }
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

  if (value === undefined)
    return {message: `${flag} requires a value`, ok: false};

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
  unbalanced_markers: readonly {
    file: string;
    line: number;
    reason: string;
  }[];
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
  const stagingDir =
    path.isAbsolute(parsed.flags.stagingDir) ?
      parsed.flags.stagingDir
    : path.join(cwd, parsed.flags.stagingDir);
  const configPath =
    parsed.flags.configPath ?
      path.isAbsolute(parsed.flags.configPath) ?
        parsed.flags.configPath
      : path.join(cwd, parsed.flags.configPath)
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
  const unbalanced: {file: string; line: number; reason: string}[] = [];
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
      // post-strip tree because we re-read each file fresh inside the check.
      // Derived checks additionally read source inputs from cwd (see
      // buildExcludedSlugSet) rather than the staging tree.
      for (const check of transform.checks) {
        if (isDerivedCheck(check)) {
          const runDerived =
            check.derive === 'excluded-workflows' ?
              runDerivedWorkflowCheck
            : runDerivedWikilinkCheck;
          leaks.push(...runDerived(stagingDir, stagedFiles, check, cwd));
          continue;
        }

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
