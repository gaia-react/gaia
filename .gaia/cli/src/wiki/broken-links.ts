/**
 * `gaia wiki broken-links [--json]` handler.
 *
 * Resolution is by slug (file basename) or H1 title, case-insensitive, over
 * every live page, including `wiki/meta/`, `wiki/log.md` and `wiki/hot.md`:
 * those are exempt from being scanned, not from being linked to. `[[#Heading]]`
 * names the page it sits on, so it is neither resolved nor counted.
 *
 * `extractWikilinks` in `util/wikilinks.ts` is deliberately not reused: its
 * callers count inbound and outbound links and it knows nothing of code spans,
 * escaped table pipes, folder prefixes or line numbers, so reusing it reports
 * all four as false positives.
 *
 * Exit 0 on every completed scan; a dangling link is a finding, not a failure.
 */
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {parseFrontmatter} from './util/frontmatter.js';
import {
  collectWikiMarkdown,
  isGeneratedContentExempt,
  isWikiScanExempt,
} from './util/markdown-corpus.js';

const HELP_TEXT = `Usage: gaia wiki broken-links [--json]

  Report [[wikilinks]] in wiki/**/*.md whose target page does not exist, with
  the file line of each. Without --json, prints one "path:line  target" line
  per finding and nothing when clean. With --json, emits
  { "broken": [ { path, line, target } ] }.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const FENCE_PATTERN = /^\s*(?:```|~~~)/u;
const CODE_SPAN_PATTERN = /(?<!`)(`+)(?!`).+?(?<!`)\1(?!`)/gu;
const WIKILINK_PATTERN = /\[\[([^[\]]+)\]\]/gu;

// A link into an archive is never a live target: archived pages keep their
// historical record, so a dangling link inside one is not worth repairing and
// a page linking to one has lost its target.
const ARCHIVE_PREFIX = 'wiki/_archived/';

/** One wikilink whose target matches no live wiki page. */
export type BrokenLink = {line: number; path: string; target: string};

/** The scan's result: the broken links plus how many cross-page links it examined. */
export type BrokenLinkScan = {broken: BrokenLink[]; scannedLinkCount: number};

type RunOptions = {
  cwd?: string;
};

const isArchived = (relPath: string): boolean =>
  relPath.startsWith(ARCHIVE_PREFIX);

const shouldSkipFile = (relPath: string): boolean =>
  isArchived(relPath) ||
  isWikiScanExempt(relPath) ||
  isGeneratedContentExempt(relPath);

const firstHeading = (body: string): string | undefined => {
  for (const line of body.split('\n')) {
    const trimmed = line.trim();

    if (trimmed.startsWith('# ')) return trimmed.slice(2).trim();
  }

  return undefined;
};

const buildTargetKeys = (
  cwd: string,
  corpus: readonly string[]
): Set<string> => {
  const keys = new Set<string>();

  for (const relPath of corpus) {
    if (!isArchived(relPath)) {
      keys.add(path.posix.basename(relPath, '.md').toLowerCase());

      const {body} = parseFrontmatter(
        readFileSync(path.join(cwd, relPath), 'utf8')
      );
      const title = firstHeading(body);

      if (title !== undefined && title !== '') keys.add(title.toLowerCase());
    }
  }

  return keys;
};

const blankCodeSpans = (line: string): string =>
  line.replaceAll(CODE_SPAN_PATTERN, (span) => ' '.repeat(span.length));

// The alias separator is the first `|`, and inside a table it arrives escaped
// as `\|`, so the backslash is dropped with it.
const titlePartOf = (raw: string): string => {
  const pipeIndex = raw.indexOf('|');
  const beforeAlias = pipeIndex === -1 ? raw : raw.slice(0, pipeIndex);
  const withoutEscape =
    beforeAlias.endsWith('\\') ? beforeAlias.slice(0, -1) : beforeAlias;
  const hashIndex = withoutEscape.indexOf('#');

  return (
    hashIndex === -1 ? withoutEscape : (
      withoutEscape.slice(0, hashIndex)
    )).trim();
};

const resolves = (title: string, keys: ReadonlySet<string>): boolean => {
  const finalSegment = title.split('/').at(-1) ?? title;

  return keys.has(finalSegment.trim().toLowerCase());
};

const crossPageTitles = (line: string): string[] =>
  [...blankCodeSpans(line).matchAll(WIKILINK_PATTERN)]
    .map((match) => titlePartOf(match[1] ?? ''))
    .filter((title) => title !== '');

const scanPage = (
  relPath: string,
  content: string,
  keys: ReadonlySet<string>
): BrokenLinkScan => {
  const broken: BrokenLink[] = [];
  let scannedLinkCount = 0;
  let inFence = false;

  for (const [index, line] of content.split('\n').entries()) {
    if (FENCE_PATTERN.test(line)) {
      inFence = !inFence;
    } else if (!inFence) {
      const titles = crossPageTitles(line);
      scannedLinkCount += titles.length;

      for (const title of titles) {
        if (!resolves(title, keys)) {
          broken.push({line: index + 1, path: relPath, target: title});
        }
      }
    }
  }

  return {broken, scannedLinkCount};
};

/** Every dangling wikilink under `cwd`'s wiki, plus how many links were examined. */
export const findBrokenLinks = (cwd: string): BrokenLinkScan => {
  const corpus = collectWikiMarkdown(cwd);
  const keys = buildTargetKeys(cwd, corpus);
  const result: BrokenLinkScan = {broken: [], scannedLinkCount: 0};

  for (const relPath of corpus.filter((entry) => !shouldSkipFile(entry))) {
    const page = scanPage(
      relPath,
      readFileSync(path.join(cwd, relPath), 'utf8'),
      keys
    );
    result.broken.push(...page.broken);
    result.scannedLinkCount += page.scannedLinkCount;
  }

  return result;
};

/** CLI entry: scan the wiki and print broken links; exits 0 on any completed scan. */
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
        subcommand: 'wiki broken-links',
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }
  }

  try {
    const {broken} = findBrokenLinks(options.cwd ?? process.cwd());

    if (json) {
      // The array replacer fixes the key order, which the sorted-keys lint
      // would otherwise reorder in an object literal.
      process.stdout.write(
        `${JSON.stringify({broken}, ['broken', 'path', 'line', 'target'])}\n`
      );
    } else if (broken.length > 0) {
      const lines = broken.map(
        (link) => `${link.path}:${link.line}  ${link.target}`
      );
      process.stdout.write(`${lines.join('\n')}\n`);
    }

    return EXIT_CODES.OK;
  } catch (error) {
    structuredError({
      code: 'broken_links_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'wiki broken-links',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }
};
