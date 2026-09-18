/**
 * Reads every merged pull request a search matches, however many there are.
 *
 * `gh pr list --search` runs on GitHub's search API, which returns at most
 * 1000 results and still exits 0, so `--limit` above that is ignored and one
 * query cannot tell a 1000-PR window from a larger one it cut short. `gh` has
 * no cursor or page flag, so a full page is never treated as complete: the
 * walk re-queries with an upper bound at that page's oldest `mergedAt` until
 * a page comes back short.
 */
import {runGh} from './run-process.js';

export const MERGED_PR_PAGE_CEILING = 1000;

export const MERGED_PR_WINDOW_MAX_PAGES = 20;

export type MergedPrWindow<T> =
  {ok: false} | {ok: true; prs: T[]; truncated: boolean};

type ReadOptions = {
  cwd: string;
  /** `--json` fields beyond the `number` and `mergedAt` the walk needs. */
  fields: readonly string[];
  /** The `merged:>=` lower bound, or null for every merged PR. */
  sinceIso: null | string;
};

type WindowRecord = {mergedAt: string; number: number};

const readPage = <T>(
  cwd: string,
  json: string,
  searchClauses: readonly string[]
): null | T[] => {
  const args = [
    'pr',
    'list',
    '--state',
    'merged',
    '--json',
    json,
    '--limit',
    String(MERGED_PR_PAGE_CEILING),
  ];

  if (searchClauses.length > 0) {
    args.push('--search', searchClauses.join(' '));
  }

  const result = runGh(args, {cwd});

  if (result.exitCode !== 0) return null;

  let parsed: unknown;

  try {
    parsed = JSON.parse(result.stdout);
  } catch {
    return null;
  }

  return Array.isArray(parsed) ? (parsed as T[]) : null;
};

// Deliberately an if-statement, not a `a < b ? a : b` reduce: `mergedAt` is
// an ISO date string, and `Math.min` would coerce it to NaN.
const oldestMergedAt = (page: readonly WindowRecord[]): string => {
  let oldest = page[0]?.mergedAt ?? '';

  for (const pr of page) {
    if (pr.mergedAt < oldest) oldest = pr.mergedAt;
  }

  return oldest;
};

/**
 * `truncated` is true when every page in the budget came back full, so the
 * window holds PRs older than any read.
 */
export const readMergedPrWindow = <T extends WindowRecord>({
  cwd,
  fields,
  sinceIso,
}: ReadOptions): MergedPrWindow<T> => {
  const json = [...new Set(['mergedAt', 'number', ...fields])].join(',');
  const lowerBound = sinceIso === null ? [] : [`merged:>=${sinceIso}`];
  const byNumber = new Map<number, T>();
  let upperBoundClause: null | string = null;

  for (let pages = 0; pages < MERGED_PR_WINDOW_MAX_PAGES; pages += 1) {
    const clauses: readonly string[] =
      upperBoundClause === null ? lowerBound : (
        [...lowerBound, upperBoundClause]
      );
    const page: null | T[] = readPage<T>(cwd, json, clauses);

    if (page === null) return {ok: false};

    for (const pr of page) byNumber.set(pr.number, pr);

    if (page.length < MERGED_PR_PAGE_CEILING) {
      return {ok: true, prs: [...byNumber.values()], truncated: false};
    }

    upperBoundClause = `merged:<=${oldestMergedAt(page)}`;
  }

  return {ok: true, prs: [...byNumber.values()], truncated: true};
};
