/**
 * `gaia wiki dead-paths` handler.
 *
 * Scans `wiki/**` markdown files for backticked repo-relative paths that
 * reference files no longer present on disk. Detects rot like a wiki page
 * citing `.claude/hooks/wiki-stop-safety-net.sh` after that hook has been
 * deleted or renamed.
 *
 * Output: newline-separated `wiki/path:line  dead-path` entries. Exit 0
 * always — finding rot is informational, not a failure.
 */
import {readdirSync, readFileSync, statSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';

const HELP_TEXT = `Usage: gaia wiki dead-paths [--json]

  Scan wiki/**/*.md for backticked repo-relative paths under .claude/, .gaia/,
  app/, test/, wiki/ that no longer exist on disk. Excludes wiki/log.md and
  wiki/meta/** (audit artifacts that legitimately reference historical paths).
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const TRACKED_PREFIXES = ['.claude/', '.gaia/', 'app/', 'test/', 'wiki/'] as const;

const SKIP_PATH_FRAGMENTS = [
  'wiki/log.md',
  'wiki/meta/',
  'wiki/.state.json',
] as const;

/**
 * Repo-relative prefixes that resolve to gitignored runtime artifacts. Wiki
 * references to these paths describe shapes, not files we expect to exist.
 */
const RUNTIME_PREFIXES = ['.gaia/local/', '.gaia/cache/'] as const;

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
      continue;
    }

    if (entry.isFile() && entry.name.endsWith('.md')) {
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

export const findDeadPaths = (cwd: string): readonly DeadRef[] => {
  const wikiDir = path.join(cwd, 'wiki');

  try {
    statSync(wikiDir);
  } catch {
    return [];
  }

  const dead: DeadRef[] = [];
  const files = walkMarkdown(cwd, wikiDir);

  for (const filePath of files) {
    if (shouldSkipFile(filePath)) continue;

    const content = readFileSync(path.join(cwd, filePath), 'utf8');
    const lines = content.split('\n');

    for (const [index, line] of lines.entries()) {
      if (HISTORICAL_BULLET_PATTERN.test(line)) continue;

      const matches = line.matchAll(PATH_TOKEN_PATTERN);

      for (const match of matches) {
        const token = match[1];

        if (token === undefined) continue;
        if (!isTrackedPath(token)) continue;
        if (pathExists(cwd, token)) continue;

        dead.push({filePath, line: index + 1, path: token});
      }
    }
  }

  return dead;
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
      continue;
    }
    structuredError({
      code: 'invalid_arguments',
      message: `unknown flag: ${token}`,
      subcommand: 'wiki dead-paths',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  try {
    const cwd = options.cwd ?? process.cwd();
    const dead = findDeadPaths(cwd);

    if (json) {
      process.stdout.write(`${JSON.stringify({dead}, null, 2)}\n`);

      return EXIT_CODES.OK;
    }

    if (dead.length === 0) return EXIT_CODES.OK;

    const lines = dead.map(
      (ref) => `${ref.filePath}:${ref.line}  ${ref.path}`
    );
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
