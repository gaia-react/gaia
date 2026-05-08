/**
 * `gaia wiki page-index [--json]` handler.
 *
 * Walks `wiki/<domain>/*.md`, parses frontmatter, and counts inbound /
 * outbound `[[wikilinks]]`. Replaces the prose Step 1 page-index walk in
 * `wiki/consolidate.md`.
 *
 * Skipped paths follow the same exclusions documented in
 * `wiki/consolidate.md` Step 1: per-domain `_index.md`, `_archived/`,
 * `meta/`, `entities/` are emitted as part of the index but the consumer
 * (consolidate, lint, orphans) is responsible for any further filtering.
 *
 * Outbound link counts are total wikilink occurrences in the page body.
 * Inbound counts are computed by matching either the page slug, the page
 * title, or any `[[<title>]]` reference across the corpus. Resolution
 * matches against both the slug (filename minus `.md`) and the title
 * (H1). Duplicate references inside one page count multiple times — that
 * matches how Obsidian counts them.
 */
import {existsSync, readdirSync, readFileSync, statSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {parseFrontmatter, type Frontmatter} from './util/frontmatter.js';
import {resolveRepoRoot} from './util/git.js';
import {extractWikilinks} from './util/wikilinks.js';

const HELP_TEXT = `Usage: gaia wiki page-index [--json]

  Walk wiki/<domain>/*.md, parse frontmatter, and count inbound/outbound
  wikilinks. Without --json, prints a tabular summary.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

export type PageEntry = {
  domain: string;
  inbound_links: number;
  outbound_links: number;
  path: string;
  status: string | null;
  tags: string[];
  title: string;
  type: string | null;
};

export type PageIndex = {
  pages: PageEntry[];
};

const DOMAIN_DIRS = [
  'components',
  'concepts',
  'decisions',
  'dependencies',
  'entities',
  'flows',
  'modules',
  'meta',
];

const SKIPPED_FILES = new Set(['_index.md', 'README.md']);

// Wiki-root pages whose outbound wikilinks count toward inbound counts of
// domain pages but which are not themselves emitted as indexable entries.
// `index.md` is the catalog; `overview.md` is the project landing page;
// `hot.md` is the auto-loaded recent-context cache. Pages reachable only
// from these would otherwise flag as orphans.
const ROOT_LINK_SOURCES = ['index.md', 'overview.md', 'hot.md'];

const slugFromPath = (filePath: string): string =>
  path.basename(filePath, '.md');

const extractTitle = (body: string, fallback: string): string => {
  const lines = body.split('\n');

  for (const line of lines) {
    const trimmed = line.trim();

    if (trimmed.startsWith('# ')) {
      return trimmed.slice(2).trim() || fallback;
    }
  }

  return fallback;
};

const stringValue = (value: Frontmatter[string]): string | null => {
  if (typeof value === 'string') return value;
  if (typeof value === 'number') return String(value);
  if (typeof value === 'boolean') return value ? 'true' : 'false';

  return null;
};

const arrayOfStrings = (value: Frontmatter[string]): string[] => {
  if (Array.isArray(value)) return value.filter((entry) => typeof entry === 'string');
  if (typeof value === 'string' && value.length > 0) return [value];

  return [];
};

type PageRecord = {
  body: string;
  domain: string;
  outboundTargets: string[];
  relativePath: string;
  slug: string;
  status: string | null;
  tags: string[];
  title: string;
  type: string | null;
};

const collectPages = (wikiRoot: string): PageRecord[] => {
  const pages: PageRecord[] = [];

  for (const domain of DOMAIN_DIRS) {
    const domainDir = path.join(wikiRoot, domain);

    if (!existsSync(domainDir) || !statSync(domainDir).isDirectory()) continue;

    const entries = readdirSync(domainDir, {withFileTypes: true});

    for (const entry of entries) {
      if (!entry.isFile()) continue;
      if (!entry.name.endsWith('.md')) continue;
      if (SKIPPED_FILES.has(entry.name)) continue;
      if (entry.name.startsWith('_')) continue;

      const absPath = path.join(domainDir, entry.name);
      const raw = readFileSync(absPath, 'utf8');
      const {body, frontmatter} = parseFrontmatter(raw);
      const slug = slugFromPath(entry.name);
      const title = extractTitle(body, slug);
      const targets = extractWikilinks(body);

      pages.push({
        body,
        domain,
        outboundTargets: targets,
        relativePath: path.posix.join('wiki', domain, entry.name),
        slug,
        status: stringValue(frontmatter.status),
        tags: arrayOfStrings(frontmatter.tags),
        title,
        type: stringValue(frontmatter.type),
      });
    }
  }

  return pages;
};

const collectRootLinkSources = (wikiRoot: string): string[][] => {
  const sources: string[][] = [];

  for (const filename of ROOT_LINK_SOURCES) {
    const absPath = path.join(wikiRoot, filename);

    if (!existsSync(absPath)) continue;
    const raw = readFileSync(absPath, 'utf8');
    const {body} = parseFrontmatter(raw);
    sources.push(extractWikilinks(body));
  }

  return sources;
};

const buildIndex = (
  pages: readonly PageRecord[],
  rootSources: readonly (readonly string[])[] = []
): PageIndex => {
  // Map every "name reachable by wikilink" → the canonical record so we can
  // tally inbound counts. We index by lowercased slug AND lowercased title
  // (Obsidian resolves wikilinks against either).
  const byKey = new Map<string, PageRecord>();

  for (const page of pages) {
    byKey.set(page.slug.toLowerCase(), page);
    byKey.set(page.title.toLowerCase(), page);
  }

  const inboundCounts = new Map<string, number>();

  const tallyTargets = (targets: readonly string[]): void => {
    for (const target of targets) {
      const matched = byKey.get(target.toLowerCase());

      if (matched === undefined) continue;
      const key = matched.relativePath;
      inboundCounts.set(key, (inboundCounts.get(key) ?? 0) + 1);
    }
  };

  for (const page of pages) tallyTargets(page.outboundTargets);
  for (const source of rootSources) tallyTargets(source);

  return {
    pages: pages.map((page) => ({
      domain: page.domain,
      inbound_links: inboundCounts.get(page.relativePath) ?? 0,
      outbound_links: page.outboundTargets.length,
      path: page.relativePath,
      status: page.status,
      tags: page.tags,
      title: page.title,
      type: page.type,
    })),
  };
};

const printHuman = (index: PageIndex): void => {
  if (index.pages.length === 0) {
    process.stdout.write('No wiki pages found.\n');

    return;
  }

  const lines = [`Indexed ${index.pages.length} page(s):`, ''];

  for (const page of index.pages) {
    lines.push(
      `  ${page.domain.padEnd(14)} ${page.title.padEnd(40)} in:${page.inbound_links} out:${page.outbound_links}`
    );
  }
  process.stdout.write(`${lines.join('\n')}\n`);
};

type RunOptions = {
  cwd?: string;
};

/** Internal helper that returns the parsed index without printing. */
export const computePageIndex = (cwd: string): PageIndex => {
  const repoRoot = resolveRepoRoot(cwd);
  const wikiRoot = path.join(repoRoot, 'wiki');
  const pages = collectPages(wikiRoot);
  const rootSources = collectRootLinkSources(wikiRoot);

  return buildIndex(pages, rootSources);
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
      subcommand: 'wiki page-index',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: 'gaia wiki page-index must run inside a git repository',
      subcommand: 'wiki page-index',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const wikiRoot = path.join(repoRoot, 'wiki');
  const pages = collectPages(wikiRoot);
  const rootSources = collectRootLinkSources(wikiRoot);
  const index = buildIndex(pages, rootSources);

  if (json) {
    process.stdout.write(`${JSON.stringify(index)}\n`);
  } else {
    printHuman(index);
  }

  return EXIT_CODES.OK;
};
