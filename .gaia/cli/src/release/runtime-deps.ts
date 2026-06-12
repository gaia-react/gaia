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
 * Walks shipped shell scripts under `.gaia/statusline/` and
 * `.claude/hooks/`, extracts repo-relative path constants, and verifies
 * each is either:
 *
 *   - present in `.gaia/manifest.json` (a shipped file), or
 *   - an adopter-owned sentinel (`wiki/hot.md`, `wiki/log.md`,
 *     `.gaia/VERSION`, `.gaia/manifest.json`), or
 *   - a runtime-allocated path on adopter machines (under
 *     `.gaia/local/`, `.gaia/cache/`, `.claude/handoff/`,
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
import {ADOPTER_OWNED_SENTINELS as GIT_TRACKED_SENTINELS} from './manifest.js';
import {structuredError} from '../stderr.js';

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

const SCAN_GLOBS = ['.gaia/statusline', '.claude/hooks'] as const;

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
 * slashes so that bare directory references (e.g. `.gaia/cache/*` glob
 * matches that decay to `.gaia/cache` after extraction) also pass.
 */
const RUNTIME_PREFIXES: readonly string[] = [
  '.gaia/local',
  '.gaia/cache',
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
 *     (installed on demand by `/setup-gaia-ci`), and when absent on an adopter
 *     clone the path simply never appears in the diff, so the bypass returns
 *     the normal deny. A path constant, not a runtime dependency.
 */
const PROSE_PATH_ALLOWLIST: ReadonlySet<string> = new Set([
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

  while (end < line.length && PATH_BODY_CHAR.test(line[end] as string)) {
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
    const ch = line[cursor] as string;

    if (ch === '$') return true;

    if (ch === '/' || ch === '{' || ch === '}' || PATH_BODY_CHAR.test(ch)) {
      cursor -= 1;
      continue;
    }

    return false;
  }

  return false;
};

export const extractPathRefs = (
  filePath: string,
  source: string
): readonly PathRef[] => {
  const refs: PathRef[] = [];
  const lines = source.split('\n');

  for (const [index, line] of lines.entries()) {
    const stripped = stripCommentSuffix(line);

    if (stripped.length === 0) continue;

    for (const prefix of PATH_PREFIXES) {
      let cursor = 0;

      while (cursor <= stripped.length - prefix.length) {
        const found = stripped.indexOf(prefix, cursor);

        if (found === -1) break;
        // Substring-vs-rooted-path discrimination. A `.gaia/` preceded by
        // a path-body char usually means we're inside a larger absolute
        // path (`/var/log/.gaia/...`); skip. The exception is shell
        // variable expansion (`$PROJECT_ROOT/.gaia/...`), where the
        // static portion is the project-relative path we care about.
        const leading = found === 0 ? '' : (stripped[found - 1] as string);

        if (
          leading.length > 0 &&
          PATH_BODY_CHAR.test(leading) &&
          !isVariableExpansionContext(stripped, found)
        ) {
          cursor = found + 1;
          continue;
        }

        const candidate = expandPath(stripped, found);
        // Skip pure-prefix matches (`.gaia/` with no body).
        if (candidate.length > prefix.length) {
          // Trim trailing dots/slashes which are likely not part of the
          // intended path token.
          const trimmed = candidate.replace(/[./]+$/, '');

          if (
            trimmed.length > prefix.length &&
            !PROSE_PATH_ALLOWLIST.has(trimmed)
          ) {
            refs.push({filePath, line: index + 1, path: trimmed});
          }
        }
        cursor = found + candidate.length;
      }
    }
  }

  return refs;
};

const isShippedPath = (
  candidate: string,
  manifest: ReadonlySet<string>
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

  return false;
};

const walkScripts = (root: string): string[] => {
  const out: string[] = [];

  for (const sub of SCAN_GLOBS) {
    const absolute = path.join(root, sub);

    try {
      statSync(absolute);
    } catch {
      continue;
    }

    out.push(...walkSh(root, absolute));
  }

  return out;
};

const walkSh = (root: string, dir: string): string[] => {
  const out: string[] = [];

  for (const entry of readdirSync(dir, {withFileTypes: true})) {
    const full = path.join(dir, entry.name);

    if (entry.isDirectory()) {
      out.push(...walkSh(root, full));
      continue;
    }

    if (entry.isFile() && entry.name.endsWith('.sh')) {
      out.push(path.relative(root, full).split(path.sep).join('/'));
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

type Flags = {
  json: boolean;
  manifestPath: string | undefined;
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
  let json = false;
  let manifestPath: string | undefined;
  let stagingDir: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string;

    if (token === '--staging') {
      const taken = takeValue(argv, index + 1, '--staging');

      if (!taken.ok) return taken;
      stagingDir = taken.value;
      index += 1;
      continue;
    }

    if (token === '--manifest') {
      const taken = takeValue(argv, index + 1, '--manifest');

      if (!taken.ok) return taken;
      manifestPath = taken.value;
      index += 1;
      continue;
    }

    if (token === '--json') {
      json = true;
      continue;
    }

    return {message: `unknown flag: ${token}`, ok: false};
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

  const out: string[] = [];

  out.push(
    `release runtime-deps: scanned ${report.scanned_files.length} script(s)`
  );

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
      subcommand: 'release runtime-deps',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const root =
    parsed.flags.stagingDir ?
      path.isAbsolute(parsed.flags.stagingDir) ?
        parsed.flags.stagingDir
      : path.join(cwd, parsed.flags.stagingDir)
    : cwd;

  try {
    statSync(root);
  } catch {
    structuredError({
      code: 'root_missing',
      message: `scan root not found: ${root}`,
      subcommand: 'release runtime-deps',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const manifestPath =
    parsed.flags.manifestPath ?
      path.isAbsolute(parsed.flags.manifestPath) ?
        parsed.flags.manifestPath
      : path.join(cwd, parsed.flags.manifestPath)
    : path.join(root, '.gaia', 'manifest.json');

  let manifest: ReadonlySet<string>;

  try {
    manifest = loadManifest(manifestPath);
  } catch (error) {
    structuredError({
      code: 'manifest_load_failed',
      message: error instanceof Error ? error.message : String(error),
      path: manifestPath,
      subcommand: 'release runtime-deps',
    });

    return UNEXPECTED_EXIT;
  }

  let scriptFiles: readonly string[];

  try {
    scriptFiles = walkScripts(root);
  } catch (error) {
    structuredError({
      code: 'walk_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'release runtime-deps',
    });

    return UNEXPECTED_EXIT;
  }

  const leaks: Leak[] = [];

  for (const scriptPath of scriptFiles) {
    const source = readFileSync(path.join(root, scriptPath), 'utf8');
    const refs = extractPathRefs(scriptPath, source);

    for (const ref of refs) {
      // Self-reference: a script citing its own path is fine.
      if (ref.path === scriptPath) continue;
      if (isShippedPath(ref.path, manifest)) continue;

      leaks.push({file: ref.filePath, line: ref.line, path: ref.path});
    }
  }

  const report: Report = {leaks, scanned_files: scriptFiles};
  process.stdout.write(renderReport(report, parsed.flags.json));

  return leaks.length > 0 ? EXIT_CODES.UNKNOWN_SUBCOMMAND : EXIT_CODES.OK;
};
