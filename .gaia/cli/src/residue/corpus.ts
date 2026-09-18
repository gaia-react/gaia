/**
 * The residue tally's corpus injection seam (RD-008).
 *
 * Nearly every UAT for `/gaia-residue` is stated against live GitHub state
 * and is unfalsifiable in CI without a way to substitute a fixture corpus for
 * `gh` and `git`. `resolveProvider` is the one place a process variable
 * decides which implementation the rest of the tally sees; nothing below it
 * reads `GAIA_RESIDUE_FIXTURE_DIR` directly.
 */
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {readMergedPrWindow} from '../ci/util/merged-pr-window.js';
import {runGh} from '../ci/util/run-process.js';
import {execGaiaGit, execGaiaGitRaw} from '../util/git-env.js';

export type CorpusProvider = {
  /** The full text of `path` at object `sha`, or null when unresolvable. */
  blobAt: (sha: string, path: string, prNumber: number) => null | string;
  /** The full text of `path` at current HEAD, or null when unresolvable. */
  blobAtHead: (path: string) => null | string;
  /** Merged pull requests, newest first, or a read failure. */
  mergedPrs: (sinceIso: null | string) => MergedPrsResult;
  /** Open plus closed tech-debt issues, or a read failure. */
  techDebtIssues: () => TechDebtIssuesResult;
};

export type IssueRecord = {
  body: string;
  labels: {name: string}[];
  number: number;
  state: 'CLOSED' | 'OPEN';
  stateReason: null | string;
};

export type MergedPrsResult =
  {ok: false} | {ok: true; prs: PrRecord[]; truncated: boolean};

export type PrRecord = {
  body: string;
  headRefOid: string;
  mergedAt: string;
  number: number;
};

export type TechDebtIssuesResult =
  {issues: IssueRecord[]; ok: true} | {ok: false};

// --- fixture provider -------------------------------------------------------

const readJsonFile = (filePath: string): unknown => {
  try {
    return JSON.parse(readFileSync(filePath, 'utf8'));
  } catch {
    return null;
  }
};

export const fixtureProvider = (dir: string): CorpusProvider => {
  const blobs = (): Record<string, string> => {
    const parsed = readJsonFile(path.join(dir, 'blobs.json'));

    return (
        parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)
      ) ?
        (parsed as Record<string, string>)
      : {};
  };

  return {
    blobAt: (sha, filePath) => blobs()[`${sha}:${filePath}`] ?? null,
    blobAtHead: (filePath) => blobs()[`HEAD:${filePath}`] ?? null,
    mergedPrs: (sinceIso) => {
      const parsed = readJsonFile(path.join(dir, 'prs.json'));

      if (!Array.isArray(parsed)) return {ok: false};

      const prs = (parsed as PrRecord[]).filter(
        (pr) => sinceIso === null || pr.mergedAt >= sinceIso
      );

      return {ok: true, prs, truncated: false};
    },
    techDebtIssues: () => {
      const parsed = readJsonFile(path.join(dir, 'issues.json'));

      if (!Array.isArray(parsed)) return {ok: false};

      return {issues: parsed as IssueRecord[], ok: true};
    },
  };
};

// --- live provider ----------------------------------------------------------

const ISSUE_LIST_LIMIT = 1000;
const ISSUE_JSON_FIELDS = 'number,body,labels,state,stateReason';

const mergedPrsLive = (cwd: string, sinceIso: null | string): MergedPrsResult =>
  readMergedPrWindow<PrRecord & {createdAt: string}>({
    cwd,
    fields: ['body', 'headRefOid', 'mergedAt'],
    sinceIso,
  });

const techDebtIssuesLive = (cwd: string): TechDebtIssuesResult => {
  const openResult = runGh(
    [
      'issue',
      'list',
      '--state',
      'open',
      '--label',
      'tech-debt',
      '--limit',
      String(ISSUE_LIST_LIMIT),
      '--json',
      ISSUE_JSON_FIELDS,
    ],
    {cwd}
  );
  const closedResult = runGh(
    [
      'issue',
      'list',
      '--state',
      'closed',
      '--label',
      'tech-debt',
      '--limit',
      String(ISSUE_LIST_LIMIT),
      '--json',
      ISSUE_JSON_FIELDS,
    ],
    {cwd}
  );

  if (openResult.exitCode !== 0 || closedResult.exitCode !== 0)
    return {ok: false};

  let openParsed: unknown;
  let closedParsed: unknown;

  try {
    openParsed = JSON.parse(openResult.stdout);
    closedParsed = JSON.parse(closedResult.stdout);
  } catch {
    return {ok: false};
  }

  if (!Array.isArray(openParsed) || !Array.isArray(closedParsed))
    return {ok: false};

  const openIssues = openParsed as IssueRecord[];
  const closedIssues = closedParsed as IssueRecord[];

  return {issues: [...openIssues, ...closedIssues], ok: true};
};

// Every merged head SHA survives only as a dangling object once its branch is
// deleted, so `git show <sha>:<path>` works on a maintainer's own machine
// (where the fetch already happened at review time) but fails in CI or a
// fresh clone. Fetching the pull request's head ref first makes the object
// reachable before the read is attempted.
type BlobAtLiveArgs = {
  cwd: string;
  filePath: string;
  prNumber: number;
  sha: string;
};

const blobAtLive = ({
  cwd,
  filePath,
  prNumber,
  sha,
}: BlobAtLiveArgs): null | string => {
  try {
    execGaiaGit(
      ['fetch', '--no-tags', '--quiet', 'origin', `refs/pull/${prNumber}/head`],
      cwd
    );
  } catch {
    // Fetch failed (offline, PR ref pruned, unmerged fork): the following
    // `git show` is what actually determines whether the object is
    // unreachable, so no early return here.
  }

  try {
    // Raw, not trimmed: leading/trailing whitespace on a cited line is
    // exactly what resolution compares.
    return execGaiaGitRaw(['show', `${sha}:${filePath}`], cwd);
  } catch {
    // Object still unreachable locally; fall back to the GitHub API, which
    // reads the blob independently of the local object store.
  }

  const apiResult = runGh(
    [
      'api',
      `repos/{owner}/{repo}/contents/${filePath}`,
      '-f',
      `ref=${sha}`,
      '--jq',
      '.content',
    ],
    {cwd}
  );

  if (apiResult.exitCode !== 0) return null;

  try {
    return Buffer.from(apiResult.stdout.trim(), 'base64').toString('utf8');
  } catch {
    return null;
  }
};

const blobAtHeadLive = (cwd: string, filePath: string): null | string => {
  try {
    return execGaiaGitRaw(['show', `HEAD:${filePath}`], cwd);
  } catch {
    return null;
  }
};

export const liveProvider = (cwd: string): CorpusProvider => ({
  blobAt: (sha, filePath, prNumber) =>
    blobAtLive({cwd, filePath, prNumber, sha}),
  blobAtHead: (filePath) => blobAtHeadLive(cwd, filePath),
  mergedPrs: (sinceIso) => mergedPrsLive(cwd, sinceIso),
  techDebtIssues: () => techDebtIssuesLive(cwd),
});

export const resolveProvider = (
  cwd: string,
  environment: NodeJS.ProcessEnv
): CorpusProvider => {
  const fixtureDir = environment.GAIA_RESIDUE_FIXTURE_DIR;

  return fixtureDir !== undefined && fixtureDir !== '' ?
      fixtureProvider(fixtureDir)
    : liveProvider(cwd);
};
