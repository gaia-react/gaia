import {load as parseYaml} from 'js-yaml';
import {z} from 'zod';
/**
 * `gaia-maintainer release scrub` handler.
 *
 * Bundle-time discipline for the GAIA release tarball. Runs inside
 * `release.yml` between the staging step (rsync from `git ls-files` minus
 * `.gaia/release-exclude`) and the final `tar -czf`. Four transforms run
 * in order against the staging tree:
 *
 *   1. marker-strip: remove maintainer-only blocks delimited by HTML
 *      comment markers. Source becomes superset; bundle is subset.
 *
 *   2. json-strip: delete maintainer-only keys from structured JSON files
 *      using dot-notation paths (e.g. "scripts.test:forensics"). Dots are
 *      path separators; a literal dot inside a key name is escaped as `\.`.
 *
 *   3. json-strip-array-element: remove a single array element by predicate
 *      from a structured JSON file (e.g. a maintainer-only hook registration
 *      inside `.claude/settings.json`), the shape json-strip cannot express.
 *
 *   4. leak-check: run codified audit patterns from
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
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import {extractWikilinks} from '../wiki/util/wikilinks.js';
import {parseExcludeLines} from './manifest.js';
import {stripMarkerBlocks} from './marker-strip.js';

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
//   - `excluded-titles`: the release-excluded wiki page-title set, matched as
//     bare Title-Case prose (the leak the three checks above each miss).
//
// Every member of the check union parses strictly, so an unknown key is rejected
// rather than silently stripped. This matters most for `title-opt-out`, which is
// valid ONLY on the `excluded-titles` variant: a strip-and-pass would drop a
// maintainer's opt-out and ship the very leak it guards against.
const StaticLeakCheckSchema = z.strictObject({
  ...leakCheckBaseShape,
  pattern: z.string().min(1),
});

const OtherDerivedLeakCheckSchema = z.strictObject({
  ...leakCheckBaseShape,
  derive: z.literal(['excluded-slugs', 'excluded-workflows']),
});

const TitleDerivedLeakCheckSchema = z.strictObject({
  ...leakCheckBaseShape,
  derive: z.literal('excluded-titles'),
  // Titles subtracted from the derived set by case-sensitive exact equality.
  // The generics that appear in ordinary prose on nearly every page live here.
  'title-opt-out': z.array(z.string()).optional(),
});

const LeakCheckSchema = z.object({
  checks: z
    .array(
      z.union([
        TitleDerivedLeakCheckSchema,
        OtherDerivedLeakCheckSchema,
        StaticLeakCheckSchema,
      ])
    )
    .min(1),
  type: z.literal('leak-check'),
});

const JsonStripSchema = z.object({
  keys: z.array(z.string().min(1)).min(1),
  paths: z.array(z.string().min(1)).min(1),
  type: z.literal('json-strip'),
});

// Removes a single array element by predicate, the shape `json-strip` cannot
// express (it deletes object keys only). A selector's `path` walks the JSON by
// dot notation; a `[]` suffix on a segment marks an array to iterate, and the
// final `[]` segment names the array elements are removed from. `match` is a
// non-empty key→value map; an element is removed only when every match entry
// equals the element's own value, so a stale selector that matches nothing is a
// silent no-op rather than a corruption of the shipped file.
const JsonStripArrayElementSchema = z.object({
  paths: z.array(z.string().min(1)).min(1),
  selectors: z
    .array(
      z.object({
        match: z
          .record(z.string(), z.string())
          .refine((entries) => Object.keys(entries).length > 0, {
            message: 'match requires at least one key',
          }),
        path: z.string().min(1),
      })
    )
    .min(1),
  type: z.literal('json-strip-array-element'),
});

const ConfigSchema = z.object({
  transforms: z
    .array(
      z.union([
        MarkerStripSchema,
        JsonStripSchema,
        JsonStripArrayElementSchema,
        LeakCheckSchema,
      ])
    )
    .min(1),
});

export type ScrubConfig = z.infer<typeof ConfigSchema>;
type DerivedLeakCheck =
  | z.infer<typeof OtherDerivedLeakCheckSchema>
  | z.infer<typeof TitleDerivedLeakCheckSchema>;
type JsonStripArrayElementTransform = z.infer<
  typeof JsonStripArrayElementSchema
>;
type JsonStripTransform = z.infer<typeof JsonStripSchema>;
type LeakCheckEntry = LeakCheckTransform['checks'][number];
type LeakCheckTransform = z.infer<typeof LeakCheckSchema>;
type MarkerStripTransform = z.infer<typeof MarkerStripSchema>;
type StaticLeakCheck = z.infer<typeof StaticLeakCheckSchema>;
type TitleDerivedLeakCheck = z.infer<typeof TitleDerivedLeakCheckSchema>;

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
    } else if (entry.isFile()) {
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
    reason: 'end_without_start' | 'start_without_end';
  }[];
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
    if (matchesAnyGlob(relativePath, transform.paths)) {
      const absolutePath = path.join(stagingRoot, relativePath);
      const source = readFileSync(absolutePath, 'utf8');
      const hasAnyMarker =
        source.includes(transform.start) || source.includes(transform.end);

      if (hasAnyMarker) {
        const result = stripMarkerBlocks(
          source,
          transform.start,
          transform.end
        );

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
    } else if (char === '.') {
      segments.push(current);
      current = '';
    } else {
      current += char;
    }
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
    if (!Object.hasOwn(obj, head)) return false;

    delete obj[head];

    return true;
  }

  const next = obj[head];

  if (typeof next !== 'object' || next === null || Array.isArray(next)) {
    return false;
  }

  return deleteKeyPath(next as Record<string, unknown>, rest);
};

/**
 * Strips the configured key paths from one JSON file in place. Returns the
 * count of keys actually removed (0 for a non-object file or a file with no
 * matching keys); the file is rewritten only when that count is positive.
 */
const stripJsonKeysFromFile = (
  absolutePath: string,
  relativePath: string,
  keySegments: readonly (readonly string[])[]
): number => {
  let parsed: unknown;

  try {
    parsed = JSON.parse(readFileSync(absolutePath, 'utf8'));
  } catch (error) {
    throw new Error(
      `Failed to parse JSON at ${relativePath}: ${error instanceof Error ? error.message : String(error)}`
    );
  }

  const isPlainObject =
    typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed);

  if (!isPlainObject) return 0;

  const obj = parsed as Record<string, unknown>;
  let removed = 0;

  for (const segments of keySegments) {
    if (deleteKeyPath(obj, segments)) removed += 1;
  }

  if (removed > 0) {
    atomicWriteFileSync(absolutePath, `${JSON.stringify(obj, null, 2)}\n`);
  }

  return removed;
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
    if (matchesAnyGlob(relativePath, transform.paths)) {
      const absolutePath = path.join(stagingRoot, relativePath);
      const removed = stripJsonKeysFromFile(
        absolutePath,
        relativePath,
        keySegments
      );

      if (removed > 0) {
        filesTouched.push(relativePath);
        keysRemoved += removed;
      }
    }
  }

  return {filesTouched, keysRemoved};
};

// ---------------------------------------------------------------------------
// JSON strip array element
// ---------------------------------------------------------------------------

export type JsonStripArrayElementResult = {
  elementsRemoved: number;
  filesTouched: readonly string[];
};

type ResolvedSelector = {
  match: Readonly<Record<string, string>>;
  segments: readonly SelectorSegment[];
};
type SelectorSegment = {isArray: boolean; key: string};

/**
 * Split a selector path into ordered segments. A `[]` suffix marks a segment
 * whose value is an array: `PreToolUse[]` iterates each element of the
 * `PreToolUse` array, and a trailing `[]` names the array elements are removed
 * from. A segment without `[]` is a plain object-key descent.
 *
 * `hooks.PreToolUse[].hooks[]` →
 *   [{key:'hooks',isArray:false}, {key:'PreToolUse',isArray:true},
 *    {key:'hooks',isArray:true}]
 */
const parseSelectorPath = (selectorPath: string): SelectorSegment[] =>
  selectorPath.split('.').map((raw) => {
    const isArray = raw.endsWith('[]');

    return {isArray, key: isArray ? raw.slice(0, -2) : raw};
  });

/**
 * An element matches when it is a plain object and every `match` entry equals
 * the element's own value for that key. An empty `match` never reaches here
 * (the schema rejects it), so this cannot degenerate into matching everything.
 */
const elementMatchesSelector = (
  element: unknown,
  match: Readonly<Record<string, string>>
): boolean => {
  if (
    typeof element !== 'object' ||
    element === null ||
    Array.isArray(element)
  ) {
    return false;
  }

  const record = element as Record<string, unknown>;

  return Object.entries(match).every(([key, value]) => record[key] === value);
};

/**
 * Walk `segments` from `node`, removing every matching element from the array
 * the terminal `[]` segment names. Purely defensive: any structural surprise
 * (a missing key, or a value whose shape does not match the segment kind) ends
 * the walk with zero removals rather than throwing, so a selector that has
 * drifted from the file cannot corrupt it. Returns the count removed.
 */
const removeMatchingArrayElements = (
  node: unknown,
  segments: readonly SelectorSegment[],
  match: Readonly<Record<string, string>>
): number => {
  if (segments.length === 0) return 0;

  if (typeof node !== 'object' || node === null || Array.isArray(node)) {
    return 0;
  }

  const [segment, ...rest] = segments as [
    SelectorSegment,
    ...SelectorSegment[],
  ];
  const child = (node as Record<string, unknown>)[segment.key];

  if (!segment.isArray) {
    return removeMatchingArrayElements(child, rest, match);
  }

  if (!Array.isArray(child)) return 0;

  if (rest.length > 0) {
    let removed = 0;

    for (const element of child) {
      removed += removeMatchingArrayElements(element, rest, match);
    }

    return removed;
  }

  // Terminal array: splice matching elements in place, back-to-front so
  // earlier indices stay valid. An emptied array stays as `[]` (neither
  // collapsed nor removed); the parent entry is left intact.
  let removed = 0;

  for (let index = child.length - 1; index >= 0; index -= 1) {
    if (elementMatchesSelector(child[index], match)) {
      child.splice(index, 1);
      removed += 1;
    }
  }

  return removed;
};

/**
 * Applies the resolved selectors to one JSON file in place. Returns the count
 * of elements actually removed (0 for a non-object file or when no selector
 * matches); the file is rewritten only when that count is positive.
 */
const stripArrayElementsFromFile = (
  absolutePath: string,
  relativePath: string,
  selectors: readonly ResolvedSelector[]
): number => {
  let parsed: unknown;

  try {
    parsed = JSON.parse(readFileSync(absolutePath, 'utf8'));
  } catch (error) {
    throw new Error(
      `Failed to parse JSON at ${relativePath}: ${error instanceof Error ? error.message : String(error)}`
    );
  }

  const isPlainObject =
    typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed);

  if (!isPlainObject) return 0;

  let removed = 0;

  for (const selector of selectors) {
    removed += removeMatchingArrayElements(
      parsed,
      selector.segments,
      selector.match
    );
  }

  if (removed > 0) {
    atomicWriteFileSync(absolutePath, `${JSON.stringify(parsed, null, 2)}\n`);
  }

  return removed;
};

const applyJsonStripArrayElement = (
  stagingRoot: string,
  files: readonly string[],
  transform: JsonStripArrayElementTransform
): JsonStripArrayElementResult => {
  const filesTouched: string[] = [];
  let elementsRemoved = 0;
  const selectors: ResolvedSelector[] = transform.selectors.map((selector) => ({
    match: selector.match,
    segments: parseSelectorPath(selector.path),
  }));

  for (const relativePath of files) {
    if (matchesAnyGlob(relativePath, transform.paths)) {
      const absolutePath = path.join(stagingRoot, relativePath);
      const removed = stripArrayElementsFromFile(
        absolutePath,
        relativePath,
        selectors
      );

      if (removed > 0) {
        filesTouched.push(relativePath);
        elementsRemoved += removed;
      }
    }
  }

  return {elementsRemoved, filesTouched};
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

type FileScanArgs = {
  check: LeakCheckEntry;
  files: readonly string[];
  stagingRoot: string;
};

/**
 * Shared skeleton for every leak-check kind: walk each in-scope,
 * not-path-allowlisted file, split into lines, skip line-allowlisted lines,
 * and delegate to `findLeaksInLine` for the check-specific match logic
 * (literal regex, wikilink lookup, or excluded-workflow substring search).
 */
const scanForLeaks = (
  {check, files, stagingRoot}: FileScanArgs,
  findLeaksInLine: (
    line: string,
    lineNumber: number,
    relativePath: string
  ) => readonly Leak[]
): Leak[] => {
  const lineAllowlist = (check['line-allowlist'] ?? []).map(
    (raw) => new RegExp(raw)
  );
  const pathAllowlist = check['path-allowlist'] ?? [];
  const leaks: Leak[] = [];

  for (const relativePath of files) {
    const inScope =
      matchesAnyGlob(relativePath, check.scope) &&
      !matchesAnyGlob(relativePath, pathAllowlist);

    if (inScope) {
      const source = readFileSync(path.join(stagingRoot, relativePath), 'utf8');

      for (const [index, line] of source.split('\n').entries()) {
        if (!lineAllowlist.some((rx) => rx.test(line))) {
          leaks.push(...findLeaksInLine(line, index + 1, relativePath));
        }
      }
    }
  }

  return leaks;
};

const runLeakCheck = (
  stagingRoot: string,
  files: readonly string[],
  check: StaticLeakCheck
): readonly Leak[] => {
  const pattern = new RegExp(check.pattern);

  return scanForLeaks(
    {check, files, stagingRoot},
    (line, lineNumber, relativePath) => {
      const match = pattern.exec(line);

      return match === null ?
          []
        : [
            {
              check: check.id,
              file: relativePath,
              line: lineNumber,
              match: match[0],
            },
          ];
    }
  );
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
// Adds the slug(s) contributed by one `.gaia/release-exclude` line: a `.md`
// exclude contributes its own basename slug; a bare-directory exclude
// contributes the directory's own slug plus every `.md` page beneath it.
// Guard-clause early returns (not `continue`): this runs once per line from
// a plain `for` loop in the caller, not from inside a loop itself.
const addSlugsForExcludeLine = (
  line: string,
  cwd: string,
  addSlug: (value: string) => void
): void => {
  if (line !== 'wiki' && !line.startsWith('wiki/')) return;

  if (line.endsWith('.md')) {
    addSlug(slugFromPath(line));

    return;
  }

  const absolute = path.join(cwd, line);

  if (!isDirectory(absolute)) return;

  addSlug(path.basename(line));

  for (const relative of walkFiles(absolute)) {
    if (relative.endsWith('.md')) addSlug(slugFromPath(relative));
  }
};

const buildExcludedSlugSet = (cwd: string): Set<string> => {
  const lines = parseExcludeLines(
    readFileSync(path.join(cwd, RELEASE_EXCLUDE_PATH), 'utf8')
  );
  const slugs = new Set<string>();

  const addSlug = (value: string): void => {
    slugs.add(value.toLowerCase());
  };

  for (const line of lines) {
    addSlugsForExcludeLine(line, cwd, addSlug);
  }

  return slugs;
};

type DerivedCheckArgs = {
  check: DerivedLeakCheck;
  cwd: string;
  files: readonly string[];
  stagingRoot: string;
};

const runDerivedWikilinkCheck = ({
  check,
  cwd,
  files,
  stagingRoot,
}: DerivedCheckArgs): readonly Leak[] => {
  const excludedSlugs = buildExcludedSlugSet(cwd);

  return scanForLeaks(
    {check, files, stagingRoot},
    (line, lineNumber, relativePath) =>
      extractWikilinks(line)
        .filter((target) => excludedSlugs.has(target.toLowerCase()))
        .map((target) => ({
          check: check.id,
          file: relativePath,
          line: lineNumber,
          match: `[[${target}]]`,
        }))
  );
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
    if (line.startsWith(`${WORKFLOWS_DIR}/`) && line.endsWith('.yml')) {
      const templatePath = path.join(
        cwd,
        SHIPPED_WORKFLOW_TEMPLATES_DIR,
        `${path.basename(line)}.tmpl`
      );

      // A shipped `.tmpl` means the workflow is rendered onto adopters on
      // demand, so a reference to it is not a boundary leak; keep it out of
      // the set.
      if (!existsSync(templatePath)) {
        paths.add(line);
      }
    }
  }

  return paths;
};

const runDerivedWorkflowCheck = ({
  check,
  cwd,
  files,
  stagingRoot,
}: DerivedCheckArgs): readonly Leak[] => {
  const neverPresent = buildNeverPresentWorkflowSet(cwd);

  if (neverPresent.size === 0) return [];

  return scanForLeaks(
    {check, files, stagingRoot},
    (line, lineNumber, relativePath) =>
      [...neverPresent]
        .filter((excludedPath) => line.includes(excludedPath))
        .map((excludedPath) => ({
          check: check.id,
          file: relativePath,
          line: lineNumber,
          match: excludedPath,
        }))
  );
};

// ---------------------------------------------------------------------------
// Derived excluded-titles check
// ---------------------------------------------------------------------------

// Literal regex-escape set for a title body. Matches `escapeRegExp` in
// `manifest.js`: `-` is deliberately absent, harmless as a literal outside a
// character class, and the token boundaries below handle hyphen adjacency.
const TITLE_ESCAPE = /[.*+?^${}()|[\]\\]/g;
// Exclude BOTH brackets from the inner class: a wikilink target never contains
// one, and excluding `[` keeps overlapping `[[` prefixes from forcing a rescan
// (linear, not polynomial).
const WIKILINK_SPAN = /\[\[[^[\]]*\]\]/g;
const INLINE_CODE_SPAN = /`[^`]*`/g;

// Adds the page title(s) contributed by one `.gaia/release-exclude` line: a
// `.md` exclude contributes its own case-preserved basename; a bare-directory
// exclude contributes the case-preserved basename of every `.md` page beneath
// it, and NOT the directory basename itself (a directory name is not a page a
// reader follows, and as a lowercase common word it appears in ordinary prose).
// Guard-clause early returns (not `continue`): this runs once per line from a
// plain `for` loop in the caller, not from inside a loop itself.
const addTitlesForExcludeLine = (
  line: string,
  cwd: string,
  addTitle: (value: string) => void
): void => {
  if (line !== 'wiki' && !line.startsWith('wiki/')) return;

  if (line.endsWith('.md')) {
    addTitle(slugFromPath(line));

    return;
  }

  const absolute = path.join(cwd, line);

  if (!isDirectory(absolute)) return;

  for (const relative of walkFiles(absolute)) {
    if (relative.endsWith('.md')) addTitle(slugFromPath(relative));
  }
};

/**
 * Build the set of release-excluded wiki page TITLES from `.gaia/release-exclude`
 * resolved against `cwd`, the source repo.
 *
 * Distinct from `buildExcludedSlugSet`: titles are case-PRESERVED (bare prose is
 * matched case-sensitively) and the bare-directory basename is never
 * contributed. Reading from `cwd` is load-bearing: `release-exclude` excludes
 * itself, so a staging read yields an empty set and passes silently.
 */
const buildExcludedTitleSet = (cwd: string): Set<string> => {
  const lines = parseExcludeLines(
    readFileSync(path.join(cwd, RELEASE_EXCLUDE_PATH), 'utf8')
  );
  const titles = new Set<string>();

  for (const line of lines) {
    addTitlesForExcludeLine(line, cwd, (value) => titles.add(value));
  }

  return titles;
};

const escapeTitle = (title: string): string =>
  title.replaceAll(TITLE_ESCAPE, String.raw`\$&`);

// Case-sensitive (no `i` flag), whole-token: alphanumerics AND hyphens are
// token-internal, so `Bundle-time Scrub` never fires inside `Bundle-time
// Scrubbing` and `CLI-Binary-Split` never fires inside `CLI-Binary-Split-Extra`
// or `Pre-CLI-Binary-Split`.
const titleToRegex = (title: string): RegExp =>
  new RegExp(String.raw`(?<![\w-])${escapeTitle(title)}(?![\w-])`);

// A fence delimiter opens or closes a fenced code block: a line whose trimmed
// text begins with three backticks or three tildes.
const isFenceDelimiter = (line: string): boolean => {
  const trimmed = line.trim();

  return trimmed.startsWith('```') || trimmed.startsWith('~~~');
};

// Remove `[[wikilink]]` and inline `` `code` `` spans (the span only, keeping
// surrounding text) so a title inside either is not matched while a bare title
// sharing the line still is. Order is independent: neither strip reintroduces
// the other's delimiters.
const stripSkippedSpans = (line: string): string =>
  line.replaceAll(WIKILINK_SPAN, '').replaceAll(INLINE_CODE_SPAN, '');

type TitleMatcher = {regex: RegExp; title: string};

/**
 * Scan one post-strip staging file for bare-title leaks with its OWN full
 * line-stream walk (not `scanForLeaks`), tracking fenced-code-block state per
 * file. Every line is observed so a fence delimiter always toggles state, even
 * a line-allowlisted one; routing this through `scanForLeaks` would drop
 * allowlisted lines before the walk and desync the fence counter.
 */
const findTitleLeaksInFile = (
  file: {content: string; id: string; path: string},
  matchers: readonly TitleMatcher[],
  lineAllowlist: readonly RegExp[]
): Leak[] => {
  const leaks: Leak[] = [];
  let insideFence = false;

  for (const [index, line] of file.content.split('\n').entries()) {
    if (isFenceDelimiter(line)) {
      insideFence = !insideFence;
    } else if (!insideFence && !lineAllowlist.some((rx) => rx.test(line))) {
      const residue = stripSkippedSpans(line);

      for (const {regex, title} of matchers) {
        if (regex.test(residue)) {
          leaks.push({
            check: file.id,
            file: file.path,
            line: index + 1,
            match: title,
          });
        }
      }
    }
  }

  return leaks;
};

type DerivedTitleCheckArgs = {
  check: TitleDerivedLeakCheck;
  cwd: string;
  files: readonly string[];
  stagingRoot: string;
};

const runDerivedTitleCheck = ({
  check,
  cwd,
  files,
  stagingRoot,
}: DerivedTitleCheckArgs): readonly Leak[] => {
  const optOut = new Set(check['title-opt-out']);
  const matchers: TitleMatcher[] = [...buildExcludedTitleSet(cwd)]
    .filter((title) => !optOut.has(title))
    .map((title) => ({regex: titleToRegex(title), title}));

  if (matchers.length === 0) return [];

  const lineAllowlist = (check['line-allowlist'] ?? []).map(
    (raw) => new RegExp(raw)
  );
  const pathAllowlist = check['path-allowlist'] ?? [];
  const leaks: Leak[] = [];

  for (const relativePath of files) {
    const inScope =
      matchesAnyGlob(relativePath, check.scope) &&
      !matchesAnyGlob(relativePath, pathAllowlist);

    if (inScope) {
      const content = readFileSync(
        path.join(stagingRoot, relativePath),
        'utf8'
      );

      leaks.push(
        ...findTitleLeaksInFile(
          {content, id: check.id, path: relativePath},
          matchers,
          lineAllowlist
        )
      );
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

type FlagParseFailure = {message: string; ok: false};

type FlagParseResult = FlagParseFailure | FlagParseSuccess;
type FlagParseSuccess = {flags: Flags; ok: true};
type Flags = {
  configPath: string | undefined;
  json: boolean;
  stagingDir: string | undefined;
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

const parseFlags = (argv: readonly string[]): FlagParseResult => {
  let configPath: string | undefined;
  let json = false;
  let stagingDir: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--config') {
      const taken = takeValue(argv, index + 1, '--config');

      if (!taken.ok) return taken;
      configPath = taken.value;
      index += 1;
    } else if (token === '--json') {
      json = true;
    } else if (token.startsWith('--')) {
      return {message: `unknown flag: ${token}`, ok: false};
    } else if (stagingDir === undefined) {
      stagingDir = token;
    } else {
      return {message: `unexpected positional: ${token}`, ok: false};
    }
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
  json_strip_array_element: {
    elements_removed: number;
    files_touched: readonly string[];
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

  const out: string[] = [
    `release scrub: stripped ${report.marker_strip.blocks_stripped} marker block(s) across ${report.marker_strip.files_touched.length} file(s)`,
    `release scrub: removed ${report.json_strip.keys_removed} json key(s) from ${report.json_strip.files_touched.length} file(s)`,
    `release scrub: removed ${report.json_strip_array_element.elements_removed} json array element(s) from ${report.json_strip_array_element.files_touched.length} file(s)`,
  ];

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

const resolveAbsolute = (cwd: string, value: string): string =>
  path.isAbsolute(value) ? value : path.join(cwd, value);

const tryVerifyExists = (target: string): boolean => {
  try {
    statSync(target);

    return true;
  } catch {
    return false;
  }
};

const tryLoadConfigOrReport = (configPath: string): null | ScrubConfig => {
  try {
    return loadConfig(configPath);
  } catch (error) {
    structuredError({
      code: 'config_load_failed',
      message: error instanceof Error ? error.message : String(error),
      path: configPath,
      subcommand: 'release scrub',
    });

    return null;
  }
};

const tryWalkFilesOrReport = (stagingDir: string): null | readonly string[] => {
  try {
    return walkFiles(stagingDir);
  } catch (error) {
    structuredError({
      code: 'staging_walk_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'release scrub',
    });

    return null;
  }
};

type ScrubContext = {
  cwd: string;
  stagedFiles: readonly string[];
  stagingDir: string;
};

/**
 * Runs every check in one `leak-check` transform: derived checks (which also
 * read source inputs from `ctx.cwd` rather than the staging tree, see
 * `buildExcludedSlugSet`) and static regex checks alike.
 */
const runLeakChecksForTransform = (
  checks: readonly LeakCheckEntry[],
  ctx: ScrubContext
): Leak[] => {
  const leaks: Leak[] = [];

  for (const check of checks) {
    if (isDerivedCheck(check)) {
      const args = {
        cwd: ctx.cwd,
        files: ctx.stagedFiles,
        stagingRoot: ctx.stagingDir,
      };

      if (check.derive === 'excluded-titles') {
        leaks.push(...runDerivedTitleCheck({check, ...args}));
      } else {
        const runDerived =
          check.derive === 'excluded-workflows' ?
            runDerivedWorkflowCheck
          : runDerivedWikilinkCheck;

        leaks.push(...runDerived({check, ...args}));
      }
    } else {
      leaks.push(...runLeakCheck(ctx.stagingDir, ctx.stagedFiles, check));
    }
  }

  return leaks;
};

type TransformResults = {
  jsonStripArrayElementFiles: string[];
  jsonStripArrayElementsRemoved: number;
  jsonStripFiles: string[];
  jsonStripKeysRemoved: number;
  leaks: Leak[];
  stripBlocks: number;
  stripFiles: string[];
  unbalanced: {file: string; line: number; reason: string}[];
};

// After marker-strip and json-strip land, leak-check sees the post-strip
// tree because we re-read each file fresh inside the check.
const runTransforms = (
  config: ScrubConfig,
  ctx: ScrubContext
): TransformResults => {
  const results: TransformResults = {
    jsonStripArrayElementFiles: [],
    jsonStripArrayElementsRemoved: 0,
    jsonStripFiles: [],
    jsonStripKeysRemoved: 0,
    leaks: [],
    stripBlocks: 0,
    stripFiles: [],
    unbalanced: [],
  };

  for (const transform of config.transforms) {
    if (transform.type === 'marker-strip') {
      const result = applyMarkerStrip(
        ctx.stagingDir,
        ctx.stagedFiles,
        transform
      );
      results.stripBlocks += result.blocksStripped;
      results.stripFiles.push(...result.filesTouched);
      results.unbalanced.push(...result.unbalanced);
    } else if (transform.type === 'json-strip') {
      const result = applyJsonStrip(ctx.stagingDir, ctx.stagedFiles, transform);
      results.jsonStripKeysRemoved += result.keysRemoved;
      results.jsonStripFiles.push(...result.filesTouched);
    } else if (transform.type === 'json-strip-array-element') {
      const result = applyJsonStripArrayElement(
        ctx.stagingDir,
        ctx.stagedFiles,
        transform
      );
      results.jsonStripArrayElementsRemoved += result.elementsRemoved;
      results.jsonStripArrayElementFiles.push(...result.filesTouched);
    } else {
      results.leaks.push(...runLeakChecksForTransform(transform.checks, ctx));
    }
  }

  return results;
};

const tryRunTransformsOrReport = (
  config: ScrubConfig,
  ctx: ScrubContext
): null | TransformResults => {
  try {
    return runTransforms(config, ctx);
  } catch (error) {
    structuredError({
      code: 'transform_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'release scrub',
    });

    return null;
  }
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
  const stagingDir = resolveAbsolute(cwd, parsed.flags.stagingDir);
  const configPath =
    parsed.flags.configPath === undefined ?
      path.join(cwd, DEFAULT_CONFIG_PATH)
    : resolveAbsolute(cwd, parsed.flags.configPath);

  if (!tryVerifyExists(stagingDir)) {
    structuredError({
      code: 'staging_dir_missing',
      message: `staging directory not found: ${stagingDir}`,
      subcommand: 'release scrub',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const config = tryLoadConfigOrReport(configPath);

  if (config === null) return UNEXPECTED_EXIT;

  const stagedFiles = tryWalkFilesOrReport(stagingDir);

  if (stagedFiles === null) return UNEXPECTED_EXIT;

  const results = tryRunTransformsOrReport(config, {
    cwd,
    stagedFiles,
    stagingDir,
  });

  if (results === null) return UNEXPECTED_EXIT;

  const report: Report = {
    json_strip: {
      files_touched: results.jsonStripFiles,
      keys_removed: results.jsonStripKeysRemoved,
    },
    json_strip_array_element: {
      elements_removed: results.jsonStripArrayElementsRemoved,
      files_touched: results.jsonStripArrayElementFiles,
    },
    leaks: results.leaks,
    marker_strip: {
      blocks_stripped: results.stripBlocks,
      files_touched: results.stripFiles,
    },
    unbalanced_markers: results.unbalanced,
  };

  process.stdout.write(renderHumanReport(report, parsed.flags.json));

  if (results.unbalanced.length > 0 || results.leaks.length > 0) {
    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  return EXIT_CODES.OK;
};
