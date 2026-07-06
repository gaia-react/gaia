/**
 * `gaia wiki dead-paths` handler.
 *
 * Scans `wiki/**` markdown files for backticked repo-relative paths that
 * reference files no longer present on disk. Detects rot like a wiki page
 * citing `.claude/hooks/wiki-stop-safety-net.sh` after that hook has been
 * deleted or renamed. Also flags any reference to sibling-monorepo paths
 * (`studio/`, `website/`); those reach outside the GAIA repo and never
 * resolve on a single-repo clone.
 *
 * Output: newline-separated `wiki/path:line  dead-path` entries. Exit 0
 * always; finding rot is informational, not a failure.
 */
import {readdirSync, readFileSync, statSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';

const HELP_TEXT = `Usage: gaia wiki dead-paths [--json]

  Scan wiki/**/*.md for backticked repo-relative paths under .claude/, .gaia/,
  app/, test/, wiki/ that no longer exist on disk, plus any reference to
  sibling-monorepo paths (studio/, website/) which reach outside the GAIA
  tarball and never resolve on a single-repo clone. Excludes wiki/log.md
  and wiki/meta/** (audit artifacts that legitimately reference historical
  paths).
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const TRACKED_PREFIXES = [
  '.claude/',
  '.gaia/',
  'app/',
  'test/',
  'wiki/',
] as const;

/**
 * Sibling-monorepo segments that the maintainer's working tree contains
 * (`gaia/`, `studio/`, `website/` are siblings) but the GAIA tarball does
 * not. Any wiki citation containing one of these segments is dead on every
 * clone except the maintainer's. The pattern matches both bare prefixes
 * (`studio/foo.md`) and relative escapes (`../../../studio/foo.md`).
 */
const SIBLING_REPO_PATTERN = /(?:^|\/)(studio|website)\//;

const SKIP_PATH_FRAGMENTS = [
  'wiki/log.md',
  'wiki/meta/',
  'wiki/.state.json',
] as const;

/**
 * Repo-relative prefixes that resolve to gitignored runtime artifacts. Wiki
 * references to these paths describe shapes, not files we expect to exist.
 */
const RUNTIME_PREFIXES = ['.gaia/local/'] as const;

const PATH_TOKEN_PATTERN = /`([^`\n]+?)`/g;

/**
 * Placeholder markers in wiki examples: `<name>`, `${VAR}`, `*.ts`, and
 * convention-marker runs like `SPEC-NNN.md` / `XXX-XXX`.
 */
const PLACEHOLDER_PATTERN = /[<>*${}]|N{3,}|X{3,}/;

/**
 * Decision-record bullets explicitly documenting that a path was removed or
 * renamed. Decision pages legitimately reference paths that no longer exist;
 * the bullet itself is the explanation. Match the canonical bullet form:
 *
 *   - **Removed** `path/that/was/removed.ts`
 *   - **Deleted** `...`
 *   - **Renamed** `...`
 *   - **Migrated** `...`
 */
const HISTORICAL_BULLET_PATTERN =
  /^\s*-\s+\*\*(Removed|Deleted|Renamed|Migrated|Replaced)\*\*/i;

type DeadRef = {
  filePath: string;
  line: number;
  path: string;
};

type RunOptions = {
  cwd?: string;
};

const isTrackedPath = (token: string): boolean => {
  if (PLACEHOLDER_PATTERN.test(token)) return false;
  if (!token.includes('/')) return false;
  if (!/\.[a-z0-9]{1,8}$/i.test(token)) return false;
  if (RUNTIME_PREFIXES.some((prefix) => token.startsWith(prefix))) return false;
  if (SIBLING_REPO_PATTERN.test(token)) return true;

  return TRACKED_PREFIXES.some((prefix) => token.startsWith(prefix));
};

const shouldSkipFile = (relPath: string): boolean =>
  SKIP_PATH_FRAGMENTS.some((fragment) => relPath.startsWith(fragment));

const walkMarkdown = (root: string, dir: string): string[] => {
  const entries = readdirSync(dir, {withFileTypes: true});
  const out: string[] = [];

  for (const entry of entries) {
    const full = path.join(dir, entry.name);

    if (entry.isDirectory()) {
      out.push(...walkMarkdown(root, full));
    } else if (entry.isFile() && entry.name.endsWith('.md')) {
      out.push(path.relative(root, full));
    }
  }

  return out;
};

const pathExists = (root: string, candidate: string): boolean => {
  try {
    statSync(path.join(root, candidate));

    return true;
  } catch {
    return false;
  }
};

// A tracked token is dead when it points outside this repo (sibling-monorepo
// segments never resolve on a single-repo clone) or when it simply doesn't
// exist on disk.
const isDeadToken = (cwd: string, token: string): boolean =>
  SIBLING_REPO_PATTERN.test(token) || !pathExists(cwd, token);

type FileContext = {
  cwd: string;
  filePath: string;
};

const collectDeadPathsInLine = (
  ctx: FileContext,
  lineNumber: number,
  line: string
): readonly DeadRef[] => {
  if (HISTORICAL_BULLET_PATTERN.test(line)) return [];

  const refs: DeadRef[] = [];

  for (const match of line.matchAll(PATH_TOKEN_PATTERN)) {
    // The capture group `([^`\n]+?)` isn't inside an optional quantifier or
    // alternation, so it always participates once `match` exists; without
    // `noUncheckedIndexedAccess`, TS already types `match[1]` as `string`.
    const token = match[1];

    if (isTrackedPath(token) && isDeadToken(ctx.cwd, token)) {
      refs.push({filePath: ctx.filePath, line: lineNumber, path: token});
    }
  }

  return refs;
};

const collectDeadPathsInFile = (ctx: FileContext): readonly DeadRef[] => {
  const content = readFileSync(path.join(ctx.cwd, ctx.filePath), 'utf8');
  const lines = content.split('\n');

  return lines.flatMap((line, index) =>
    collectDeadPathsInLine(ctx, index + 1, line)
  );
};

export const findDeadPaths = (cwd: string): readonly DeadRef[] => {
  const wikiDir = path.join(cwd, 'wiki');

  try {
    statSync(wikiDir);
  } catch {
    return [];
  }

  const files = walkMarkdown(cwd, wikiDir);

  return files
    .filter((filePath) => !shouldSkipFile(filePath))
    .flatMap((filePath) => collectDeadPathsInFile({cwd, filePath}));
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  let json = false;

  for (const token of argv) {
    if (HELP_TOKENS.has(token)) {
      process.stdout.write(HELP_TEXT);

      return EXIT_CODES.OK;
    }

    if (token === '--json') {
      json = true;
    } else {
      structuredError({
        code: 'invalid_arguments',
        message: `unknown flag: ${token}`,
        subcommand: 'wiki dead-paths',
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }
  }

  try {
    const cwd = options.cwd ?? process.cwd();
    const dead = findDeadPaths(cwd);

    if (json) {
      process.stdout.write(`${JSON.stringify({dead}, null, 2)}\n`);

      return EXIT_CODES.OK;
    }

    if (dead.length === 0) return EXIT_CODES.OK;

    const lines = dead.map((ref) => `${ref.filePath}:${ref.line}  ${ref.path}`);
    process.stdout.write(`${lines.join('\n')}\n`);

    return EXIT_CODES.OK;
  } catch (error) {
    structuredError({
      code: 'dead_paths_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'wiki dead-paths',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }
};
