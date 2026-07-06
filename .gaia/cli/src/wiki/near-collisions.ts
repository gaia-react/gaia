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
import type {Dirent} from 'node:fs';
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

  for (let row = 1; row <= a.length; row += 1) {
    current[0] = row;

    for (let col = 1; col <= b.length; col += 1) {
      const cost = a.charAt(row - 1) === b.charAt(col - 1) ? 0 : 1;
      current[col] = Math.min(
        (current[col - 1] ?? 0) + 1,
        (previous[col] ?? 0) + 1,
        (previous[col - 1] ?? 0) + cost
      );
    }

    for (let col = 0; col <= b.length; col += 1) {
      previous[col] = current[col] ?? 0;
    }
  }

  return current[b.length] ?? 0;
};

type DomainSlugs = {
  domain: string;
  slugs: string[];
};

const isCollectibleSlugFile = (entry: Dirent): boolean =>
  entry.isFile() &&
  entry.name.endsWith('.md') &&
  !SKIPPED_FILES.has(entry.name) &&
  !entry.name.startsWith('_');

const collectDomainSlugs = (wikiRoot: string): DomainSlugs[] =>
  DOMAIN_DIRS.flatMap((domain) => {
    const domainDir = path.join(wikiRoot, domain);

    if (!existsSync(domainDir) || !statSync(domainDir).isDirectory()) {
      return [];
    }

    const entries = readdirSync(domainDir, {withFileTypes: true});
    // Ordinal comparator (not `localeCompare`): this order determines which
    // slug in a pair reports as `slugA` vs `slugB`, and `localeCompare`
    // treats `-`/`_` differently than the default sort's code-unit order,
    // flipping that tie-break for near-identical slugs like `a-b`/`a_b`.
    const slugs = entries
      .filter((entry) => isCollectibleSlugFile(entry))
      .map((entry) => entry.name.replace(/\.md$/u, ''))
      .toSorted((left, right) =>
        left < right ? -1
        : left > right ? 1
        : 0
      );

    return slugs.length >= 2 ? [{domain, slugs}] : [];
  });

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

      for (
        let otherIndex = index + 1;
        otherIndex < slugs.length;
        otherIndex += 1
      ) {
        const slugB = slugs[otherIndex];
        const normB = normalizeSlug(slugB);

        // Skip true duplicates (identical raw slug); that case can't
        // happen on a real filesystem and is meaningless to flag.
        if (slugA !== slugB) {
          const distance = levenshtein(normA, normB);

          if (distance <= maxDistance) {
            results.push({distance, domain, slugA, slugB});
          }
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
  // `noUncheckedIndexedAccess` is off, so TS types `argv[index]` as
  // `string`, not `string | undefined`; check the bound explicitly instead
  // of comparing the indexed value to `undefined`.
  if (index >= argv.length) {
    return {message: `${flag} requires a value`, ok: false};
  }

  return {ok: true, value: argv[index]};
};

const parseFlags = (
  argv: readonly string[]
): FlagParseFailure | FlagParseSuccess => {
  let maxDistance = DEFAULT_MAX_DISTANCE;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token !== '--max-distance') {
      return {message: `unknown flag: ${token}`, ok: false};
    }

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
