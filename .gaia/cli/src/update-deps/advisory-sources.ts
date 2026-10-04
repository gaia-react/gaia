/**
 * The two advisory sources: Dependabot alerts through `gh api`, and
 * `pnpm audit --json` as the fallback. Each returns raw parsed records or a
 * reason token; neither ever returns gh or pnpm stderr, which can carry a
 * token or attacker-controlled text. Field selection and validation happen in
 * `advisory-model.ts`.
 */
import {execFileSync, spawnSync} from 'node:child_process';
import {runGh} from '../setup-ci/util/gh.js';
import type {GhOptions, GhResult} from '../setup-ci/util/gh.js';
import {parseRemoteUrl} from '../setup-ci/util/parse-remote-url.js';
import type {AdvisoryReasonToken} from './advisory-reasons.js';
import type {PnpmRunner} from './run.js';

export type AlertsResult =
  | {dismissed: unknown[]; ok: true; open: unknown[]}
  | {ok: false; reason: AdvisoryReasonToken};

export type AuditResult = {ok: false} | {ok: true; report: unknown};

export type GhRunner = (options: GhOptions) => Promise<GhResult>;

export type OriginReader = (cwd: string) => null | string;

export type RepositoryResult =
  | {ok: false; reason: 'no-remote' | 'non-github-remote'}
  | {ok: true; owner: string; repo: string};

// Long enough for a paginated fetch on a slow network, short enough that a
// stalled request never holds `check-updates.sh`'s refresh lock indefinitely.
export const ADVISORY_SPAWN_TIMEOUT_MS = 60_000;

// `pnpm audit --json` on a large tree runs to several megabytes, past
// spawnSync's one-megabyte default, which would truncate it into a parse
// failure.
const PNPM_MAX_BUFFER_BYTES = 64 * 1024 * 1024;

const REPOSITORY_SEGMENT_PATTERN = /^[A-Za-z0-9._-]+$/u;

/** `pnpm` spawned with a timeout, for every advisory-side pnpm call. */
export const advisoryPnpmRunner: PnpmRunner = (args, options) => {
  const result = spawnSync('pnpm', args as string[], {
    cwd: options.cwd,
    encoding: 'utf8',
    maxBuffer: PNPM_MAX_BUFFER_BYTES,
    stdio: ['ignore', 'pipe', 'pipe'],
    timeout: ADVISORY_SPAWN_TIMEOUT_MS,
  });

  // A spawn error (pnpm missing, timeout) can leave the streams unset at
  // runtime even though the type declares strings.
  return {
    status: result.error === undefined ? result.status : null,
    stderr: '',
    stdout: typeof result.stdout === 'string' ? result.stdout : '',
  };
};

/** `git remote get-url origin`, or null when there is no origin. */
export const readOriginUrl: OriginReader = (cwd) => {
  try {
    return execFileSync('git', ['remote', 'get-url', 'origin'], {
      cwd,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
  } catch {
    return null;
  }
};

/** Owner and repo from the origin remote, which must be on github.com. */
export const resolveGithubRepository = (
  cwd: string,
  originReader: OriginReader = readOriginUrl
): RepositoryResult => {
  const url = originReader(cwd);

  if (url === null || url.length === 0) return {ok: false, reason: 'no-remote'};

  const parsed = parseRemoteUrl(url);

  if (
    parsed?.host.toLowerCase() !== 'github.com' ||
    !REPOSITORY_SEGMENT_PATTERN.test(parsed.owner) ||
    !REPOSITORY_SEGMENT_PATTERN.test(parsed.repo)
  ) {
    return {ok: false, reason: 'non-github-remote'};
  }

  return {ok: true, owner: parsed.owner, repo: parsed.repo};
};

type ScanState = {depth: number; escaped: boolean; inString: boolean};

const advanceScan = (state: ScanState, character: string): void => {
  if (state.inString) {
    if (state.escaped) state.escaped = false;
    else if (character === '\\') state.escaped = true;
    else if (character === '"') state.inString = false;

    return;
  }

  if (character === '"') state.inString = true;
  else if (character === '[' || character === '{') state.depth += 1;
  else if (character === ']' || character === '}') state.depth -= 1;
};

/**
 * The records of every page in `gh api --paginate` output, which is a stream
 * of concatenated JSON arrays with no separator. Throws on anything else.
 */
export const parseAlertPages = (stdout: string): unknown[] => {
  const records: unknown[] = [];
  const state: ScanState = {depth: 0, escaped: false, inString: false};
  let start = -1;
  let pageCount = 0;

  for (let index = 0; index < stdout.length; index += 1) {
    const character = stdout.charAt(index);

    if (state.depth === 0 && start === -1) {
      if (character === '[') start = index;
      else if (character.trim() !== '') {
        throw new Error('alerts output is not a stream of JSON arrays');
      }
    }

    advanceScan(state, character);

    if (state.depth === 0 && start !== -1) {
      const page: unknown = JSON.parse(stdout.slice(start, index + 1));

      if (!Array.isArray(page)) throw new Error('alerts page is not an array');
      records.push(...(page as unknown[]));
      pageCount += 1;
      start = -1;
    }
  }

  if (start !== -1 || pageCount === 0) {
    throw new Error('alerts output is truncated or empty');
  }

  return records;
};

const HTTP_STATUS_PATTERN = /HTTP (\d{3})/u;

/** The reason token for a failed gh call, read from its exit and HTTP status. */
export const ghFailureReason = (
  result: Extract<GhResult, {ok: false}>
): AdvisoryReasonToken => {
  const {exitCode, stderr, timedOut} = result;

  if (timedOut === true) return 'alerts-request-failed';

  if (exitCode === -1 && stderr.includes('ENOENT')) return 'gh-missing';

  if (exitCode === 4 || /not logged in|gh auth login/iu.test(stderr)) {
    return 'gh-unauthenticated';
  }

  const status = HTTP_STATUS_PATTERN.exec(stderr)?.[1];

  if ((status === '403' || status === '404') && /disabled/iu.test(stderr)) {
    return 'alerts-disabled';
  }

  if (status === '403') return 'forbidden';

  return 'alerts-request-failed';
};

type FetchPageOptions = {
  cwd: string;
  env: NodeJS.ProcessEnv;
  ghRunner: GhRunner;
  owner: string;
  repo: string;
  state: string;
};

const fetchAlertState = async (
  options: FetchPageOptions
): Promise<
  {ok: false; reason: AdvisoryReasonToken} | {ok: true; records: unknown[]}
> => {
  const endpoint = `repos/${options.owner}/${options.repo}/dependabot/alerts?state=${options.state}&ecosystem=npm&per_page=100`;
  const result = await options.ghRunner({
    args: ['api', '--paginate', endpoint],
    cwd: options.cwd,
    env: options.env,
    timeoutMs: ADVISORY_SPAWN_TIMEOUT_MS,
  });

  if (!result.ok) return {ok: false, reason: ghFailureReason(result)};

  try {
    return {ok: true, records: parseAlertPages(result.stdout)};
  } catch {
    return {ok: false, reason: 'alerts-invalid-response'};
  }
};

export type FetchAlertsOptions = {
  cwd: string;
  env: NodeJS.ProcessEnv;
  ghRunner?: GhRunner;
  includeDismissed: boolean;
  owner: string;
  repo: string;
};

/**
 * Open npm alerts, plus dismissed ones when `includeDismissed` is set. A
 * failure of either call fails the whole fetch, so a caller never pairs an
 * answered open set with an unread dismissed set.
 */
export const fetchDependabotAlerts = async (
  options: FetchAlertsOptions
): Promise<AlertsResult> => {
  const common = {
    cwd: options.cwd,
    env: options.env,
    ghRunner: options.ghRunner ?? runGh,
    owner: options.owner,
    repo: options.repo,
  };
  const open = await fetchAlertState({...common, state: 'open'});

  if (!open.ok) return open;

  if (!options.includeDismissed) {
    return {dismissed: [], ok: true, open: open.records};
  }

  const dismissed = await fetchAlertState({
    ...common,
    state: 'dismissed,auto_dismissed',
  });

  if (!dismissed.ok) return dismissed;

  return {dismissed: dismissed.records, ok: true, open: open.records};
};

export type AuditOptions = {cwd: string; pnpmRunner?: PnpmRunner};

/**
 * `pnpm audit --json` at `cwd`. pnpm exits non-zero whenever an advisory is
 * open, so success is an `advisories` object in the output, not the exit
 * status; a spawn that never finished (status null) is a failure.
 */
export const runPnpmAudit = (options: AuditOptions): AuditResult => {
  const result = (options.pnpmRunner ?? advisoryPnpmRunner)(
    ['audit', '--json'],
    {cwd: options.cwd}
  );

  if (result.status === null) return {ok: false};

  let report: unknown;

  try {
    report = JSON.parse(result.stdout);
  } catch {
    return {ok: false};
  }

  if (
    report === null ||
    typeof report !== 'object' ||
    !('advisories' in report) ||
    report.advisories === null ||
    typeof report.advisories !== 'object' ||
    Array.isArray(report.advisories)
  ) {
    return {ok: false};
  }

  return {ok: true, report};
};
