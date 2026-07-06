/**
 * `gaia wiki near-collisions [--max-distance 3]` handler.
 *
 * Per-domain Levenshtein over slugs (filename without `.md`, lowercased,
 * with `_` and `-` collapsed to `-`). Tabular text output:
 *
 *   <domain>  <slugA>  <slugB>  <distance>
 *
 * Replaces the prose near-collision pass in `wiki/consolidate.md` Step 2c.
 */
import {existsSync, readdirSync, statSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from './util/git.js';

const HELP_TEXT = `Usage: gaia wiki near-collisions [--max-distance 3]

  Per-domain Levenshtein over slugs. Emits tab-separated rows:
  <domain>  <slugA>  <slugB>  <distance>
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const DEFAULT_MAX_DISTANCE = 3;

const DOMAIN_DIRS = [
  'components',
  'concepts',
  'decisions',
  'dependencies',
  'entities',
  'flows',
  'modules',
];

const SKIPPED_FILES = new Set(['_index.md', 'README.md']);

const normalizeSlug = (raw: string): string =>
  raw.toLowerCase().replaceAll('_', '-');

const levenshtein = (a: string, b: string): number => {
  if (a === b) return 0;
  if (a.length === 0) return b.length;
  if (b.length === 0) return a.length;

  const previous: number[] = Array.from(
    {length: b.length + 1},
    (_, index) => index
  );
  const current: number[] = Array.from({length: b.length + 1}, () => 0);

  for (let index = 1; index <= a.length; index += 1) {
    current[0] = index;

    for (let index_ = 1; index_ <= b.length; index_ += 1) {
      const cost = a.charAt(index - 1) === b.charAt(index_ - 1) ? 0 : 1;
      current[index_] = Math.min(
        (current[index_ - 1] ?? 0) + 1,
        (previous[index_] ?? 0) + 1,
        (previous[index_ - 1] ?? 0) + cost
      );
    }

    for (let index = 0; index <= b.length; index += 1) {
      previous[index] = current[index] ?? 0;
    }
  }

  return current[b.length] ?? 0;
};

type DomainSlugs = {
  domain: string;
  slugs: string[];
};

const collectDomainSlugs = (wikiRoot: string): DomainSlugs[] => {
  const collected: DomainSlugs[] = [];

  for (const domain of DOMAIN_DIRS) {
    const domainDir = path.join(wikiRoot, domain);

    if (!existsSync(domainDir) || !statSync(domainDir).isDirectory()) continue;

    const entries = readdirSync(domainDir, {withFileTypes: true});
    const slugs: string[] = [];

    for (const entry of entries) {
      if (!entry.isFile()) continue;
      if (!entry.name.endsWith('.md')) continue;
      if (SKIPPED_FILES.has(entry.name)) continue;
      if (entry.name.startsWith('_')) continue;
      slugs.push(entry.name.replace(/\.md$/u, ''));
    }
    slugs.sort();

    if (slugs.length >= 2) collected.push({domain, slugs});
  }

  return collected;
};

export type Collision = {
  distance: number;
  domain: string;
  slugA: string;
  slugB: string;
};

export const findCollisions = (
  domainGroups: readonly DomainSlugs[],
  maxDistance: number
): Collision[] => {
  const results: Collision[] = [];

  for (const {domain, slugs} of domainGroups) {
    for (let index = 0; index < slugs.length; index += 1) {
      const slugA = slugs[index];
      const normA = normalizeSlug(slugA);

      for (let index_ = index + 1; index_ < slugs.length; index_ += 1) {
        const slugB = slugs[index_];
        const normB = normalizeSlug(slugB);

        // Skip true duplicates (identical raw slug); that case can't
        // happen on a real filesystem and is meaningless to flag.
        if (slugA === slugB) continue;

        const distance = levenshtein(normA, normB);

        if (distance <= maxDistance) {
          results.push({distance, domain, slugA, slugB});
        }
      }
    }
  }

  results.sort((left, right) => {
    if (left.domain !== right.domain)
      return left.domain.localeCompare(right.domain);
    if (left.distance !== right.distance) return left.distance - right.distance;
    if (left.slugA !== right.slugA)
      return left.slugA.localeCompare(right.slugA);

    return left.slugB.localeCompare(right.slugB);
  });

  return results;
};

type FlagParseFailure = {
  message: string;
  ok: false;
};

type FlagParseSuccess = {
  flags: ParsedFlags;
  ok: true;
};

type ParsedFlags = {
  maxDistance: number;
};

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

const parseFlags = (
  argv: readonly string[]
): FlagParseFailure | FlagParseSuccess => {
  let maxDistance = DEFAULT_MAX_DISTANCE;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--max-distance') {
      const taken = takeValue(argv, index + 1, '--max-distance');

      if (!taken.ok) return taken;
      const parsed = Number.parseInt(taken.value, 10);

      if (Number.isNaN(parsed) || parsed < 1) {
        return {
          message: `--max-distance must be a positive integer (got: "${taken.value}")`,
          ok: false,
        };
      }
      maxDistance = parsed;
      index += 1;
      continue;
    }

    return {message: `unknown flag: ${token}`, ok: false};
  }

  return {flags: {maxDistance}, ok: true};
};

type RunOptions = {
  cwd?: string;
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
      subcommand: 'wiki near-collisions',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: 'gaia wiki near-collisions must run inside a git repository',
      subcommand: 'wiki near-collisions',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const wikiRoot = path.join(repoRoot, 'wiki');
  const domainGroups = collectDomainSlugs(wikiRoot);
  const collisions = findCollisions(domainGroups, parsed.flags.maxDistance);

  if (collisions.length === 0) return EXIT_CODES.OK;

  const lines = collisions.map(
    (collision) =>
      `${collision.domain}\t${collision.slugA}\t${collision.slugB}\t${collision.distance}`
  );
  process.stdout.write(`${lines.join('\n')}\n`);

  return EXIT_CODES.OK;
};
