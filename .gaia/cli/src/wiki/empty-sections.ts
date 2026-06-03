/**
 * `gaia wiki empty-sections [--json]` handler.
 *
 * Flags LEAF markdown headings (`#`..`######`) that have no body. A heading
 * H at level L is empty only when, within its section span (the lines after
 * H up to the next heading of level <= L, or end of file), there is BOTH:
 *   1. no child heading (no heading of level > L), AND
 *   2. no non-blank, non-heading content line.
 *
 * A parent heading (one that has child headings) is never flagged — its
 * children are evaluated individually, and a genuinely-empty leaf child gets
 * flagged on its own. Content inside fenced code blocks (```) counts as body
 * and a `#` inside a fence is not a heading; the leading frontmatter block is
 * stripped before evaluation.
 *
 * Scans `wiki/**\/*.md` except `wiki/meta/**` (dated audit artifacts) and the
 * auto-managed sentinels `wiki/hot.md` and `wiki/log.md`.
 *
 * Output: one `path:line  heading` line per finding, or a clean message.
 * With `--json`, emits { "empty": [ { path, line, heading } ] }. Exit 0
 * always — empty sections are informational, not a failure.
 */
import {readdirSync, readFileSync, statSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {parseFrontmatter} from './util/frontmatter.js';

const HELP_TEXT = `Usage: gaia wiki empty-sections [--json]

  Scan wiki/**/*.md (excluding wiki/meta/**, wiki/hot.md, wiki/log.md) for
  LEAF headings with no body — no child heading and no non-blank, non-heading
  content before the next sibling/shallower heading or EOF. Parent headings
  are never flagged. Fenced code blocks and the frontmatter block are handled.
  Without --json, prints one "path:line  heading" line per finding. With
  --json, emits { "empty": [ { path, line, heading } ] }.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const SKIP_PATH_FRAGMENTS = ['wiki/meta/'] as const;
const SKIP_PATHS = new Set(['wiki/hot.md', 'wiki/log.md']);

const ATX_HEADING_PATTERN = /^ {0,3}(#{1,6})(?:\s|$)/u;
const FENCE_PATTERN = /^\s*(?:```|~~~)/u;

type EmptySection = {
  heading: string;
  line: number;
  path: string;
};

type RunOptions = {
  cwd?: string;
};

const shouldSkipFile = (relPath: string): boolean =>
  SKIP_PATHS.has(relPath) ||
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

type Heading = {
  hasContent: boolean;
  level: number;
  line: number;
  text: string;
};

/**
 * Build the ordered heading list for one page body, tracking whether each
 * heading was followed (before the next heading) by any non-blank,
 * non-heading content line. Fenced-code lines count as content; a `#` inside
 * a fence is never a heading. `bodyLineOffset` is the number of frontmatter
 * lines stripped ahead of `body`, so reported lines map back to the file.
 */
const collectHeadings = (body: string, bodyLineOffset: number): Heading[] => {
  const headings: Heading[] = [];
  const lines = body.split('\n');
  let inFence = false;

  for (const [index, line] of lines.entries()) {
    if (FENCE_PATTERN.test(line)) {
      inFence = !inFence;
      if (headings.length > 0) (headings.at(-1) as Heading).hasContent = true;
      continue;
    }

    if (inFence) {
      if (headings.length > 0) (headings.at(-1) as Heading).hasContent = true;
      continue;
    }

    const match = ATX_HEADING_PATTERN.exec(line);

    if (match !== null) {
      headings.push({
        hasContent: false,
        level: (match[1] as string).length,
        line: bodyLineOffset + index + 1,
        text: line.trim(),
      });
      continue;
    }

    if (line.trim() !== '' && headings.length > 0) {
      (headings.at(-1) as Heading).hasContent = true;
    }
  }

  return headings;
};

/**
 * A heading is empty only when it is a LEAF (no following heading is deeper,
 * before a sibling/shallower heading closes its span) AND it carries no body
 * content. Parent headings are skipped; their children are evaluated on their
 * own.
 */
const findInBody = (
  body: string,
  bodyLineOffset: number,
  relPath: string
): EmptySection[] => {
  const headings = collectHeadings(body, bodyLineOffset);
  const found: EmptySection[] = [];

  for (const [index, heading] of headings.entries()) {
    if (heading.hasContent) continue;

    // Walk forward to the end of this heading's span (next heading of level
    // <= its level). A deeper heading inside the span makes it a parent.
    let hasChildHeading = false;

    for (let next = index + 1; next < headings.length; next += 1) {
      const candidate = headings[next] as Heading;

      if (candidate.level <= heading.level) break;
      hasChildHeading = true;
      break;
    }

    if (hasChildHeading) continue;

    found.push({heading: heading.text, line: heading.line, path: relPath});
  }

  return found;
};

export const findEmptySections = (cwd: string): readonly EmptySection[] => {
  const wikiDir = path.join(cwd, 'wiki');

  try {
    statSync(wikiDir);
  } catch {
    return [];
  }

  const empty: EmptySection[] = [];
  const files = walkMarkdown(cwd, wikiDir).sort();

  for (const filePath of files) {
    if (shouldSkipFile(filePath)) continue;

    const content = readFileSync(path.join(cwd, filePath), 'utf8');
    const {body} = parseFrontmatter(content);
    const offset = content.split('\n').length - body.split('\n').length;
    empty.push(...findInBody(body, offset, filePath));
  }

  return empty;
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
      subcommand: 'wiki empty-sections',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  try {
    const cwd = options.cwd ?? process.cwd();
    const empty = findEmptySections(cwd);

    if (json) {
      process.stdout.write(`${JSON.stringify({empty}, null, 2)}\n`);

      return EXIT_CODES.OK;
    }

    if (empty.length === 0) {
      process.stdout.write('No empty sections found.\n');

      return EXIT_CODES.OK;
    }

    const lines = empty.map(
      (section) => `${section.path}:${section.line}  ${section.heading}`
    );
    process.stdout.write(`${lines.join('\n')}\n`);

    return EXIT_CODES.OK;
  } catch (error) {
    structuredError({
      code: 'empty_sections_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'wiki empty-sections',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }
};
