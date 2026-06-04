/**
 * `gaia wiki frontmatter [--json]` handler.
 *
 * Flags wiki pages missing required frontmatter. The required-field floor is
 * `type` and `status`, the two fields essentially all GAIA pages carry. A
 * page gaps if it is missing the frontmatter block entirely, or if either
 * required field is absent or null.
 *
 * Scans `wiki/**\/*.md` except `wiki/meta/**` (dated audit artifacts that do
 * not follow the page frontmatter convention).
 *
 * Output: one `path: missing a, b` line per gap, or a clean message. With
 * `--json`, emits { "gaps": [ { path, missing } ] }. Exit 0 always; gaps
 * are informational, not a failure.
 */
import {readdirSync, readFileSync, statSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {parseFrontmatter} from './util/frontmatter.js';

const HELP_TEXT = `Usage: gaia wiki frontmatter [--json]

  Scan wiki/**/*.md (excluding wiki/meta/**) for pages missing required
  frontmatter. Required floor is type and status. Without --json, prints one
  "path: missing a, b" line per gap. With --json, emits
  { "gaps": [ { path, missing } ] }.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const REQUIRED_FIELDS = ['type', 'status'] as const;

const SKIP_PATH_FRAGMENTS = ['wiki/meta/'] as const;

type Gap = {
  missing: string[];
  path: string;
};

type RunOptions = {
  cwd?: string;
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

const hasField = (
  frontmatter: ReturnType<typeof parseFrontmatter>['frontmatter'],
  field: string
): boolean =>
  Object.prototype.hasOwnProperty.call(frontmatter, field) &&
  frontmatter[field] !== null;

export const findFrontmatterGaps = (cwd: string): readonly Gap[] => {
  const wikiDir = path.join(cwd, 'wiki');

  try {
    statSync(wikiDir);
  } catch {
    return [];
  }

  const gaps: Gap[] = [];
  const files = walkMarkdown(cwd, wikiDir).sort();

  for (const filePath of files) {
    if (shouldSkipFile(filePath)) continue;

    const content = readFileSync(path.join(cwd, filePath), 'utf8');
    const {frontmatter} = parseFrontmatter(content);
    const missing = REQUIRED_FIELDS.filter(
      (field) => !hasField(frontmatter, field)
    );

    if (missing.length > 0) {
      gaps.push({missing, path: filePath});
    }
  }

  return gaps;
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
      subcommand: 'wiki frontmatter',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  try {
    const cwd = options.cwd ?? process.cwd();
    const gaps = findFrontmatterGaps(cwd);

    if (json) {
      process.stdout.write(`${JSON.stringify({gaps}, null, 2)}\n`);

      return EXIT_CODES.OK;
    }

    if (gaps.length === 0) {
      process.stdout.write('No frontmatter gaps found.\n');

      return EXIT_CODES.OK;
    }

    const lines = gaps.map(
      (gap) => `${gap.path}: missing ${gap.missing.join(', ')}`
    );
    process.stdout.write(`${lines.join('\n')}\n`);

    return EXIT_CODES.OK;
  } catch (error) {
    structuredError({
      code: 'frontmatter_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'wiki frontmatter',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }
};
