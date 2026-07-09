/**
 * `gaia-maintainer release runtime-deps` handler.
 *
 * Catches the class of leak that the bundle-time scrub cannot see:
 * runtime references in shipped scripts that resolve to release-excluded
 * paths. Lexical scrubbing strips marker-delimited prose, but a hook that
 * spawns `bash .gaia/scripts/foo.sh` keeps working in the maintainer's
 * tree and silently breaks on adopter clones if `.gaia/scripts/` is
 * release-excluded.
 *
 * Walks shipped shell scripts under `.gaia/statusline/`,
 * `.gaia/cli/templates/`, `.gaia/scripts/`, `.claude/hooks/`,
 * `.github/actions/`, `.github/audit/`, and
 * `.specify/extensions/gaia/lib/` (recursing into nested directories),
 * extracts repo-relative path
 * constants, and verifies each is either:
 *
 *   - present in `.gaia/manifest.json` (a shipped file), or
 *   - an adopter-owned sentinel (`wiki/hot.md`, `wiki/log.md`,
 *     `.gaia/VERSION`, `.gaia/manifest.json`), or
 *   - a runtime-allocated path on adopter machines (under
 *     `.gaia/local/`, `.claude/handoff/`,
 *     `.claude/worktrees/`, `.claude/agent-memory/`, `.claude/audit/`,
 *     or one of the per-session marker files).
 *
 * Anything else is a runtime-dependency leak.
 *
 * Read-only. No writes anywhere.
 *
 * Exit codes:
 *   0: no leaks
 *   1: leaks detected, missing inputs, bad flags
 *   2: unexpected (manifest parse failure, IO error)
 */
import {readdirSync, readFileSync, statSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {ADOPTER_OWNED_SENTINELS as GIT_TRACKED_SENTINELS} from './manifest.js';

const HELP_TEXT = `Usage: gaia-maintainer release runtime-deps [--staging <dir>] [--manifest <path>] [--json]

  Scan shipped shell scripts for runtime path references that resolve to
  release-excluded files.

  Flags:
    --staging <dir>   Scan inside <dir> instead of process.cwd(). Used
                      from release.yml to scan the post-scrub staging tree.
    --manifest <path> Manifest file to verify against (default:
                      .gaia/manifest.json under the staging or repo root).
    --json            Emit a structured JSON report on stdout.

  Exit codes:
    0  no leaks
    1  leaks detected, missing inputs, bad flags
    2  unexpected (manifest parse failure, IO error)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const UNEXPECTED_EXIT = 2;

// `walkSh` below collects `*.sh` only. `.gaia/cli/templates` currently has
// zero `.sh` files (only `*.tmpl`); this entry future-proofs any future
// `.sh` landing under templates. Template CONTENT leaks (`.tmpl`, any
// extension) are a separate concern owned by the scrub `maintainer-paths`
// check in `.gaia/release-scrub.yml`, whose scope includes
// `.gaia/cli/templates/**` and scans file content regardless of extension.
const SCAN_GLOBS = [
  '.gaia/statusline',
  '.gaia/cli/templates',
  '.gaia/scripts',
  '.claude/hooks',
  '.github/actions',
  '.github/audit',
  '.specify/extensions/gaia/lib',
] as const;

/**
 * Sentinels that ship in the tarball but are intentionally absent from
 * `.gaia/manifest.json` because adopters take ownership at first install.
 *
 * The git-tracked subset is the single canonical set exported by
 * `manifest.ts` (`classifyPath` maps those to `null`). This scan adds
 * `.gaia/automation.json`, a runtime file created on the adopter side,
 * never git-tracked, so it cannot live in the manifest's set; to cover
 * references found in the extracted staging tree.
 */
const ADOPTER_OWNED_SENTINELS: ReadonlySet<string> = new Set([
  ...GIT_TRACKED_SENTINELS,
  '.gaia/automation.json',
]);

/**
 * Path prefixes that are runtime-allocated on the adopter side. Files
 * created at runtime under these directories are valid call targets even
 * though they aren't tracked in the manifest. Listed without trailing
 * slashes so that bare directory references (e.g. `.gaia/local/*` glob
 * matches that decay to `.gaia/local` after extraction) also pass.
 */
const RUNTIME_PREFIXES: readonly string[] = [
  '.gaia/local',
  '.claude/handoff',
  '.claude/worktrees',
  '.claude/agent-memory',
  '.claude/audit',
];

/**
 * Per-session marker files written by hooks. These are gitignored on the
 * source side and recreated on each session by the hook that owns them.
 */
const RUNTIME_MARKERS: ReadonlySet<string> = new Set([
  '.claude/i18n-strings-checked',
  '.claude/wiki-drift-checked',
  // Runtime-created sentinel: wiki-recompact-sentinel.sh (PostCompact) writes
  // this file and wiki-recompact-inject.sh (UserPromptSubmit) reads and clears
  // it. Created on first compaction event; never a shipped dependency.
  '.claude/wiki-recompact-pending',
  '.claude/wiki-safety-checked',
]);

const PATH_PREFIXES = ['.gaia/', '.claude/', '.specify/', '.github/'] as const;

/**
 * Path tokens referenced inside shipped scripts that are NOT runtime
 * dependencies, so they must not be reported as leaks. Two categories:
 * descriptive prose (an in-scope directory named as an example in
 * operator-facing error/help text), and path constants the script feeds to
 * git plumbing (`git diff`, `git cat-file`) rather than sourcing or invoking,
 * which resolve to a benign "absent" branch when the file is not installed.
 *
 * Entries are exact, fully-qualified tokens (the trimmed output of
 * `extractPathRefs`). Exact-match is deliberate: allowlisting
 * `.github/workflows` does NOT suppress a genuine leak to a file under it,
 * `.github/workflows/foo.yml` is a distinct, longer token that still flags.
 * This is the documented channel for false-positives, add the exact token
 * plus a justification rather than reword the reference.
 *
 *   - `.github/workflows`: named in `.claude/hooks/pr-merge-audit-check.sh`'s
 *     merge-gate error message as an example in-scope path, alongside `app/`,
 *     `test/`, `configs`. The directory is release-excluded; the reference is
 *     descriptive, not an invocation. An inline-ignore comment cannot annotate
 *     the occurrence because it lives inside a multi-line quoted `reason="..."`
 *     string that renders to the operator, hence this central allowlist.
 *   - `.github/workflows/code-review-audit.yml`: the workflow path constant in
 *     the same hook's `check_self_mod_only_update_pr()` bypass. It is compared
 *     against the PR's changed-file list and against the bundled template's
 *     git blob; it is never sourced or executed. The file is release-excluded
 *     (installed on demand by `/setup-gaia`), and when absent on an adopter
 *     clone the path simply never appears in the diff, so the bypass returns
 *     the normal deny. A path constant, not a runtime dependency.
 *   - `.claude/projects`: Claude Code's own global session-transcript
 *     directory, `$HOME/.claude/projects`, referenced by
 *     `token-tally-review.sh`. It lives outside the repo on every machine and
 *     structurally can never have a manifest entry.
 */
const PROSE_PATH_ALLOWLIST: ReadonlySet<string> = new Set([
  '.claude/projects',
  '.github/workflows',
  '.github/workflows/code-review-audit.yml',
]);

const PATH_BODY_CHAR = /[a-zA-Z0-9._/-]/;

/**
 * A path-constant occurrence found in a shipped script.
 */
export type PathRef = {
  filePath: string;
  line: number;
  path: string;
};

const stripCommentSuffix = (line: string): string => {
  // Conservative: strip only line-leading `#` comments. Mid-line `#` is
  // ambiguous in shell (could be inside a string, a parameter expansion,
  // or a glob), so we leave those intact and accept that some prose-y
  // mid-line comments may produce occurrences. The rest of the pipeline
  // tolerates extra occurrences as long as they resolve to shipped paths.
  if (/^\s*#/.test(line)) return '';

  return line;
};

const expandPath = (line: string, start: number): string => {
  let end = start;

  while (end < line.length && PATH_BODY_CHAR.test(line[end])) {
    end += 1;
  }

  return line.slice(start, end);
};

/**
 * When a `.gaia/...` (or `.claude/...`, `.specify/...`, `.github/...`)
 * occurrence is preceded by a path-body character (typically `/`), we
 * usually want to skip it as a substring inside an unrelated absolute
 * path. The exception is variable-expansion idioms like
 * `"$PROJECT_ROOT/.gaia/scripts/check-updates.sh"`, those resolve to a
 * project-relative path at runtime, so the static portion IS the
 * project path. Detect those by scanning back through path-like chars
 * for a `$`.
 */
const isVariableExpansionContext = (line: string, found: number): boolean => {
  let cursor = found - 1;

  while (cursor >= 0) {
    const ch = line[cursor];

    if (ch === '$') return true;

    if (!(ch === '/' || ch === '{' || ch === '}' || PATH_BODY_CHAR.test(ch))) {
      return false;
    }

    cursor -= 1;
  }

  return false;
};

// Trim trailing dots/slashes, which are likely not part of the intended path
// token. A bounded loop rather than a trailing-quantifier regex (`/[./]+$/`),
// which a static ReDoS check flags as backtracking-prone regardless of this
// pattern's actual (linear) cost.
const trimTrailingDotsSlashes = (candidate: string): string => {
  let trimmed = candidate;

  while (
    trimmed.length > 0 &&
    (trimmed.endsWith('.') || trimmed.endsWith('/'))
  ) {
    trimmed = trimmed.slice(0, -1);
  }

  return trimmed;
};

type PrefixScanArgs = {
  filePath: string;
  lineNumber: number;
  prefix: string;
  stripped: string;
};

/**
 * Handles a single `indexOf` hit for `prefix` at position `found`: decides
 * whether it's a genuine rooted-path occurrence (returning a `PathRef`) or a
 * substring of a larger absolute path (`ref: null`), and returns the cursor
 * position to resume scanning from.
 */
const consumeStep = (
  args: PrefixScanArgs & {found: number}
): {nextCursor: number; ref: null | PathRef} => {
  const {filePath, found, lineNumber, prefix, stripped} = args;

  // Substring-vs-rooted-path discrimination. A `.gaia/` preceded by a
  // path-body char usually means we're inside a larger absolute path
  // (`/var/log/.gaia/...`); skip. The exception is shell variable
  // expansion (`$PROJECT_ROOT/.gaia/...`), where the static portion is
  // the project-relative path we care about.
  const leading = found === 0 ? '' : stripped[found - 1];
  const isSubstring =
    leading.length > 0 &&
    PATH_BODY_CHAR.test(leading) &&
    !isVariableExpansionContext(stripped, found);

  if (isSubstring) return {nextCursor: found + 1, ref: null};

  const candidate = expandPath(stripped, found);
  const nextCursor = found + candidate.length;

  // Skip pure-prefix matches (`.gaia/` with no body).
  if (candidate.length <= prefix.length) return {nextCursor, ref: null};

  const trimmed = trimTrailingDotsSlashes(candidate);

  if (trimmed.length <= prefix.length || PROSE_PATH_ALLOWLIST.has(trimmed)) {
    return {nextCursor, ref: null};
  }

  return {nextCursor, ref: {filePath, line: lineNumber, path: trimmed}};
};

/**
 * Finds every rooted-path occurrence of `prefix` in a single
 * (comment-stripped) line, applying the substring-vs-rooted-path and
 * variable-expansion discrimination, and returns one `PathRef` per genuine
 * occurrence.
 */
const collectPrefixRefs = (args: PrefixScanArgs): PathRef[] => {
  const {prefix, stripped} = args;
  const refs: PathRef[] = [];
  let cursor = 0;

  while (cursor <= stripped.length - prefix.length) {
    const found = stripped.indexOf(prefix, cursor);

    if (found === -1) break;

    const {nextCursor, ref} = consumeStep({...args, found});

    if (ref !== null) refs.push(ref);
    cursor = nextCursor;
  }

  return refs;
};

export const extractPathRefs = (
  filePath: string,
  source: string
): readonly PathRef[] => {
  const refs: PathRef[] = [];

  for (const [index, line] of source.split('\n').entries()) {
    const stripped = stripCommentSuffix(line);

    if (stripped.length > 0) {
      for (const prefix of PATH_PREFIXES) {
        refs.push(
          ...collectPrefixRefs({
            filePath,
            lineNumber: index + 1,
            prefix,
            stripped,
          })
        );
      }
    }
  }

  return refs;
};

/**
 * Every ancestor directory of every manifest entry, e.g. the entry
 * `.claude/hooks/wiki-session-start.sh` contributes `.claude/hooks` and
 * `.claude`. Computed once per run (not per candidate) and used by
 * `isShippedPath` to resolve bare directory tokens, the shape a `SCAN_GLOBS`
 * directory decays to when a script references it via a glob
 * (`.claude/hooks/*.sh`) rather than a specific file.
 */
const computeShippedDirs = (
  manifest: ReadonlySet<string>
): ReadonlySet<string> => {
  const dirs = new Set<string>();

  for (const filePath of manifest) {
    let dir = path.dirname(filePath);

    // Stop at an already-recorded ancestor: recording a directory records its
    // whole ancestor chain in the same pass, so the rest is already present.
    while (dir !== '.' && !dirs.has(dir)) {
      dirs.add(dir);

      const parent = path.dirname(dir);

      // `path.dirname` is a fixed point at a filesystem root (`'/'` -> `'/'`),
      // so an absolute key never drains to `'.'`. Manifest keys are
      // repo-relative by construction, but `loadManifest` takes `Object.keys`
      // off unvalidated JSON, so bound the walk explicitly here rather than
      // spin forever on a corrupt manifest. This is the loop's termination
      // guarantee; the `dirs.has` test above it is only an optimization.
      if (parent === dir) break;

      dir = parent;
    }
  }

  return dirs;
};

const isShippedPath = (
  candidate: string,
  manifest: ReadonlySet<string>,
  shippedDirs: ReadonlySet<string>
): boolean => {
  if (manifest.has(candidate)) return true;
  if (ADOPTER_OWNED_SENTINELS.has(candidate)) return true;
  if (RUNTIME_MARKERS.has(candidate)) return true;

  if (
    RUNTIME_PREFIXES.some(
      (prefix) => candidate === prefix || candidate.startsWith(`${prefix}/`)
    )
  ) {
    return true;
  }

  // A bare directory ships when at least one manifest entry lives beneath
  // it, that's the precise semantics of "this directory exists on an
  // adopter machine." A directory with zero manifest entries beneath it
  // (e.g. `.gaia/scripts/tests`, release-excluded; or `.gaia/cli/src`,
  // maintainer-only source never shipped) correctly still fails this check
  // and remains a leak.
  if (shippedDirs.has(candidate)) return true;

  return false;
};

const walkSh = (root: string, dir: string): string[] => {
  const out: string[] = [];

  for (const entry of readdirSync(dir, {withFileTypes: true})) {
    const full = path.join(dir, entry.name);

    if (entry.isDirectory()) {
      out.push(...walkSh(root, full));
    } else if (entry.isFile() && entry.name.endsWith('.sh')) {
      out.push(path.relative(root, full).split(path.sep).join('/'));
    }
  }

  return out;
};

const walkScripts = (root: string): string[] => {
  const out: string[] = [];

  for (const sub of SCAN_GLOBS) {
    const absolute = path.join(root, sub);
    let exists = true;

    try {
      statSync(absolute);
    } catch {
      exists = false;
    }

    if (exists) {
      out.push(...walkSh(root, absolute));
    }
  }

  return out;
};

const loadManifest = (manifestPath: string): ReadonlySet<string> => {
  const raw = readFileSync(manifestPath, 'utf8');
  const parsed = JSON.parse(raw) as {files?: Record<string, unknown>};

  if (parsed.files === undefined) {
    throw new Error(`manifest at ${manifestPath} has no "files" field`);
  }

  return new Set(Object.keys(parsed.files));
};

// ---------------------------------------------------------------------------
// Flags
// ---------------------------------------------------------------------------

type FlagParseFailure = {message: string; ok: false};

type FlagParseResult = FlagParseFailure | FlagParseSuccess;
type FlagParseSuccess = {flags: Flags; ok: true};
type Flags = {
  json: boolean;
  manifestPath: string | undefined;
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
  let json = false;
  let manifestPath: string | undefined;
  let stagingDir: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--staging') {
      const taken = takeValue(argv, index + 1, '--staging');

      if (!taken.ok) return taken;
      stagingDir = taken.value;
      index += 1;
    } else if (token === '--manifest') {
      const taken = takeValue(argv, index + 1, '--manifest');

      if (!taken.ok) return taken;
      manifestPath = taken.value;
      index += 1;
    } else if (token === '--json') {
      json = true;
    } else {
      return {message: `unknown flag: ${token}`, ok: false};
    }
  }

  return {flags: {json, manifestPath, stagingDir}, ok: true};
};

// ---------------------------------------------------------------------------
// Run
// ---------------------------------------------------------------------------

type Leak = {
  file: string;
  line: number;
  path: string;
};

type Report = {
  leaks: readonly Leak[];
  scanned_files: readonly string[];
};

type RunOptions = {
  cwd?: string;
};

const renderReport = (report: Report, jsonMode: boolean): string => {
  if (jsonMode) return `${JSON.stringify(report, null, 2)}\n`;

  const out: string[] = [
    `release runtime-deps: scanned ${report.scanned_files.length} script(s)`,
  ];

  if (report.leaks.length > 0) {
    out.push('', `runtime-dependency leaks (${report.leaks.length}):`);

    for (const leak of report.leaks) {
      out.push(`  ${leak.file}:${leak.line}  ${leak.path}`);
    }
  } else {
    out.push('runtime-dependency leaks: none');
  }

  return `${out.join('\n')}\n`;
};

// Resolves a possibly-relative CLI path flag against `cwd`, or falls back to
// `fallback` when the flag is absent.
const resolvePathFlag = (
  cwd: string,
  fallback: string,
  flag: string | undefined
): string => {
  if (flag === undefined) return fallback;

  return path.isAbsolute(flag) ? flag : path.join(cwd, flag);
};

const tryVerifyRootExists = (root: string): boolean => {
  try {
    statSync(root);

    return true;
  } catch {
    return false;
  }
};

const tryLoadManifestOrReport = (
  manifestPath: string
): null | ReadonlySet<string> => {
  try {
    return loadManifest(manifestPath);
  } catch (error) {
    structuredError({
      code: 'manifest_load_failed',
      message: error instanceof Error ? error.message : String(error),
      path: manifestPath,
      subcommand: 'release runtime-deps',
    });

    return null;
  }
};

const tryWalkScriptsOrReport = (root: string): null | readonly string[] => {
  try {
    return walkScripts(root);
  } catch (error) {
    structuredError({
      code: 'walk_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'release runtime-deps',
    });

    return null;
  }
};

// Scans every script's extracted path refs for leaks: a reference that is
// neither a self-reference nor a shipped/adopter-owned/runtime path.
const collectLeaks = (
  root: string,
  scriptFiles: readonly string[],
  manifest: ReadonlySet<string>
): Leak[] => {
  const leaks: Leak[] = [];
  const shippedDirs = computeShippedDirs(manifest);

  for (const scriptPath of scriptFiles) {
    const source = readFileSync(path.join(root, scriptPath), 'utf8');
    const refs = extractPathRefs(scriptPath, source);

    for (const ref of refs) {
      // Self-reference: a script citing its own path is fine.
      const isLeak =
        ref.path !== scriptPath &&
        !isShippedPath(ref.path, manifest, shippedDirs);

      if (isLeak) {
        leaks.push({file: ref.filePath, line: ref.line, path: ref.path});
      }
    }
  }

  return leaks;
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
      subcommand: 'release runtime-deps',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const root = resolvePathFlag(cwd, cwd, parsed.flags.stagingDir);

  if (!tryVerifyRootExists(root)) {
    structuredError({
      code: 'root_missing',
      message: `scan root not found: ${root}`,
      subcommand: 'release runtime-deps',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const manifestPath = resolvePathFlag(
    cwd,
    path.join(root, '.gaia', 'manifest.json'),
    parsed.flags.manifestPath
  );
  const manifest = tryLoadManifestOrReport(manifestPath);

  if (manifest === null) return UNEXPECTED_EXIT;

  const scriptFiles = tryWalkScriptsOrReport(root);

  if (scriptFiles === null) return UNEXPECTED_EXIT;

  const leaks = collectLeaks(root, scriptFiles, manifest);
  const report: Report = {leaks, scanned_files: scriptFiles};
  process.stdout.write(renderReport(report, parsed.flags.json));

  return leaks.length > 0 ? EXIT_CODES.UNKNOWN_SUBCOMMAND : EXIT_CODES.OK;
};
