/**
 * `gaia setup-ci verify-run <workflow-file> [--timeout-seconds N] [--json]` handler.
 *
 * Triggers a `workflow_dispatch` run via `gh workflow run <file> --ref
 * <default-branch>`, discovers its run id, and polls `gh run view <id>`
 * until the run completes or the timeout fires. The dispatch ref is
 * resolved from `gh repo view` so the command works in repositories
 * whose default branch is not `main`.
 *
 * Output JSON:
 *
 *   {
 *     "verified": boolean,
 *     "run_id": string | null,
 *     "conclusion": string | null,
 *     "url": string | null
 *   }
 *
 * `verified: true` iff `conclusion == "success"`. On polling timeout,
 * `conclusion: "polling_timeout"` and `verified: false`. Run discovery:
 * `Date.now()` captured immediately before the dispatch is the lower
 * bound (minus a small clock-skew allowance) a listed run's `createdAt`
 * must meet to be treated as the one just dispatched; the handler polls
 * `gh run list` for a bounded number of attempts until such a run
 * appears, never falling back to the newest listed run, which could
 * belong to someone else's dispatch of the same workflow. Exhausting
 * the attempts without a qualifying run is a `run_not_found` error.
 *
 * The handler exits 0 regardless of `verified`; the slash command
 * branches on the JSON. Exits non-zero only on hard `gh` errors (e.g.
 * `gh workflow run` failed entirely) or on `run_not_found`.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {runGh} from './util/gh.js';

const HELP_TEXT = `Usage: gaia setup-ci verify-run <workflow-file> [--timeout-seconds N] [--json]

  Trigger a workflow_dispatch run and watch the run to completion.
  Default timeout: 600s. Default poll interval: 10s (override with
  --poll-interval-ms <ms>; intended for tests).
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const DEFAULT_TIMEOUT_SECONDS = 600;
const DEFAULT_POLL_INTERVAL_MS = 10_000;
// A listed run's `createdAt` and our local `Date.now()` come from two
// different clocks (GitHub's API server and this process); allow a small
// gap so a run dispatched a moment ago isn't rejected as predating the
// trigger.
const CLOCK_SKEW_ALLOWANCE_MS = 5000;
// `gh run list`'s default page is small; widen it so a busy workflow
// history doesn't push the just-dispatched run off the first page.
const RUN_LIST_LIMIT = 20;
// Bounds how long discovery waits for the dispatched run to appear in
// `gh run list` before giving up as `run_not_found`.
const RUN_DISCOVERY_MAX_ATTEMPTS = 15;
// Independent of `pollIntervalMs` (which paces `gh run view` once the run
// id is known): discovery uses the smaller of the two so a long
// `--poll-interval-ms` doesn't stall run discovery.
const RUN_DISCOVERY_INTERVAL_MS = 2000;

type RunListEntry = {createdAt?: string; databaseId: number | string};

type RunOptions = {
  cwd?: string;
};

type RunViewPayload = {
  conclusion?: null | string;
  status?: string;
  url?: string;
};

type VerifyOutput = {
  conclusion: null | string;
  run_id: null | string;
  url: null | string;
  verified: boolean;
};

/**
 * Parse a strictly-decimal positive integer. Unlike `Number.parseInt`,
 * this rejects trailing garbage (`"30abc"`), leading signs, and empty
 * strings; returns `null` for anything that is not all digits.
 */
const parsePositiveInteger = (value: string): null | number => {
  if (!/^\d+$/u.test(value)) return null;
  const parsed = Number.parseInt(value, 10);

  return parsed > 0 ? parsed : null;
};

/**
 * Extract `defaultBranchRef.name` from `gh repo view --json
 * defaultBranchRef` stdout. Returns `null` if the payload is malformed
 * or the field is absent.
 */
export const parseDefaultBranch = (stdout: string): null | string => {
  try {
    const parsed = JSON.parse(stdout) as {
      defaultBranchRef?: null | {name?: unknown};
    };
    const name = parsed.defaultBranchRef?.name;

    return typeof name === 'string' && name.length > 0 ? name : null;
  } catch {
    return null;
  }
};

const sleep = async (ms: number): Promise<void> =>
  new Promise((resolve) => {
    setTimeout(resolve, ms);
  });

const printHuman = (output: VerifyOutput): void => {
  process.stdout.write(
    `verified: ${String(output.verified)}\n` +
      `run_id: ${output.run_id ?? '(none)'}\n` +
      `conclusion: ${output.conclusion ?? '(none)'}\n` +
      `url: ${output.url ?? '(none)'}\n`
  );
};

type NumericFlagResult = {error: string} | {value: null | number};

type ParsedVerifyArgs = {
  json: boolean;
  pollIntervalMs: number;
  timeoutSeconds: number;
  workflowFile: string;
};

// Shared by the --timeout-seconds / --poll-interval-ms branches below (kept
// `applyVerifyRunToken`'s cognitive complexity under the frozen limit).
const parseNumericFlag = (
  argv: readonly string[],
  index: number,
  flag: string
): NumericFlagResult => {
  const raw = argv.at(index + 1);

  if (raw === undefined) return {error: `${flag} requires a value`};

  return {value: parsePositiveInteger(raw)};
};

type ApplyVerifyTokenResult = {consumed: number} | {exitCode: number};

type VerifyRunState = {
  json: boolean;
  pollIntervalMs: null | number;
  timeoutSeconds: null | number;
  workflowFile: string | undefined;
};

// One token's worth of dispatch, extracted so `parseVerifyRunArgs`'s own
// loop stays a flat dispatch table (kept its cognitive complexity under the
// frozen limit). Every branch here returns, so this reads as a flat guard-
// clause sequence rather than an if/else-if chain nested inside a loop.
const applyVerifyRunToken = (
  argv: readonly string[],
  index: number,
  state: VerifyRunState
): ApplyVerifyTokenResult => {
  const token = argv[index];

  if (token === undefined) return {consumed: 0};

  if (HELP_TOKENS.has(token)) {
    process.stdout.write(HELP_TEXT);

    return {exitCode: EXIT_CODES.OK};
  }

  if (token === '--json') {
    state.json = true;

    return {consumed: 0};
  }

  if (token === '--timeout-seconds' || token === '--poll-interval-ms') {
    const result = parseNumericFlag(argv, index, token);

    if ('error' in result) {
      structuredError({
        code: 'invalid_arguments',
        message: result.error,
        subcommand: 'setup-ci verify-run',
      });

      return {exitCode: EXIT_CODES.UNKNOWN_SUBCOMMAND};
    }

    if (token === '--timeout-seconds') {
      state.timeoutSeconds = result.value;
    } else {
      state.pollIntervalMs = result.value;
    }

    return {consumed: 1};
  }

  if (token.startsWith('--')) {
    structuredError({
      code: 'invalid_arguments',
      message: `unknown flag: ${token}`,
      subcommand: 'setup-ci verify-run',
    });

    return {exitCode: EXIT_CODES.UNKNOWN_SUBCOMMAND};
  }

  if (state.workflowFile === undefined) {
    state.workflowFile = token;

    return {consumed: 0};
  }

  structuredError({
    code: 'invalid_arguments',
    message: `unexpected argument: ${token}`,
    subcommand: 'setup-ci verify-run',
  });

  return {exitCode: EXIT_CODES.UNKNOWN_SUBCOMMAND};
};

// Extracted out of `run` (kept its cognitive complexity under the frozen
// limit): argv parsing only, independent of the gh orchestration below.
const parseVerifyRunArgs = (
  argv: readonly string[]
): ParsedVerifyArgs | {exitCode: number} => {
  const state: VerifyRunState = {
    json: false,
    pollIntervalMs: DEFAULT_POLL_INTERVAL_MS,
    timeoutSeconds: DEFAULT_TIMEOUT_SECONDS,
    workflowFile: undefined,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const result = applyVerifyRunToken(argv, index, state);

    if ('exitCode' in result) return result;
    index += result.consumed;
  }

  const {json, pollIntervalMs, timeoutSeconds, workflowFile} = state;

  if (workflowFile === undefined) {
    structuredError({
      code: 'missing_required_arg',
      message: 'verify-run requires <workflow-file>',
      subcommand: 'setup-ci verify-run',
    });

    return {exitCode: EXIT_CODES.UNKNOWN_SUBCOMMAND};
  }

  if (timeoutSeconds === null) {
    structuredError({
      code: 'invalid_arguments',
      message: '--timeout-seconds must be a positive integer',
      subcommand: 'setup-ci verify-run',
    });

    return {exitCode: EXIT_CODES.UNKNOWN_SUBCOMMAND};
  }

  if (pollIntervalMs === null) {
    structuredError({
      code: 'invalid_arguments',
      message: '--poll-interval-ms must be a positive integer',
      subcommand: 'setup-ci verify-run',
    });

    return {exitCode: EXIT_CODES.UNKNOWN_SUBCOMMAND};
  }

  return {json, pollIntervalMs, timeoutSeconds, workflowFile};
};

// Step 0: resolve the repository's default branch. Hardcoding `main`
// breaks repos whose default branch differs (e.g. `master`, `trunk`).
const resolveDefaultBranch = async (
  cwd: string
): Promise<{branch: string} | {exitCode: number}> => {
  const repoViewResult = await runGh({
    args: ['repo', 'view', '--json', 'defaultBranchRef'],
    cwd,
  });

  if (!repoViewResult.ok) {
    structuredError({
      code: 'default_branch_lookup_failed',
      message: repoViewResult.stderr.trim(),
      subcommand: 'setup-ci verify-run',
    });

    return {exitCode: EXIT_CODES.UNKNOWN_SUBCOMMAND};
  }

  const defaultBranch = parseDefaultBranch(repoViewResult.stdout);

  if (defaultBranch === null) {
    structuredError({
      code: 'default_branch_lookup_failed',
      message: 'could not resolve defaultBranchRef from gh repo view output',
      subcommand: 'setup-ci verify-run',
    });

    return {exitCode: EXIT_CODES.UNKNOWN_SUBCOMMAND};
  }

  return {branch: defaultBranch};
};

/**
 * Pick the oldest `gh run list` entry whose `createdAt` is at or after
 * `notBeforeMs`, so discovery never falls back to a run that predates
 * the dispatch it is trying to find. Entries with a missing or
 * unparseable `createdAt` are skipped rather than treated as a match.
 */
export const pickDispatchedRun = (
  entries: RunListEntry[],
  notBeforeMs: number
): null | string => {
  const qualifying = entries
    .map((entry) => ({
      createdAtMs:
        entry.createdAt === undefined ?
          Number.NaN
        : new Date(entry.createdAt).getTime(),
      runId: String(entry.databaseId),
    }))
    .filter(
      (entry) =>
        !Number.isNaN(entry.createdAtMs) && entry.createdAtMs >= notBeforeMs
    );

  const [first, ...rest] = qualifying;

  if (first === undefined) return null;

  return rest.reduce(
    (oldest, entry) =>
      entry.createdAtMs < oldest.createdAtMs ? entry : oldest,
    first
  ).runId;
};

type TriggerWorkflowArgs = {
  cwd: string;
  defaultBranch: string;
  workflowFile: string;
};

// Step 1: dispatch the workflow_dispatch run.
const triggerWorkflowRun = async (
  args: TriggerWorkflowArgs
): Promise<{exitCode: number} | {triggered: true}> => {
  const {cwd, defaultBranch, workflowFile} = args;

  const triggerResult = await runGh({
    args: ['workflow', 'run', workflowFile, '--ref', defaultBranch],
    cwd,
  });

  if (!triggerResult.ok) {
    structuredError({
      code: 'workflow_run_failed',
      message: triggerResult.stderr.trim(),
      subcommand: 'setup-ci verify-run',
      workflow: workflowFile,
    });

    return {exitCode: EXIT_CODES.UNKNOWN_SUBCOMMAND};
  }

  return {triggered: true};
};

type DiscoverRunIdArgs = {
  cwd: string;
  notBeforeMs: number;
  pollIntervalMs: number;
  workflowFile: string;
};

// Step 2: poll `gh run list` for the run this call dispatched, identified
// by `createdAt >= notBeforeMs` (see `pickDispatchedRun`). A page that
// lists no qualifying run, including an empty page, just means the run
// hasn't shown up yet, so the loop keeps polling rather than failing on
// an empty list.
const discoverRunId = async (
  args: DiscoverRunIdArgs
): Promise<{exitCode: number} | {runId: string}> => {
  const {cwd, notBeforeMs, pollIntervalMs, workflowFile} = args;

  for (let attempt = 1; attempt <= RUN_DISCOVERY_MAX_ATTEMPTS; attempt += 1) {
    // eslint-disable-next-line no-await-in-loop -- intentional sequential poll
    const listResult = await runGh({
      args: [
        'run',
        'list',
        `--workflow=${workflowFile}`,
        '--event',
        'workflow_dispatch',
        '--limit',
        String(RUN_LIST_LIMIT),
        '--json',
        'databaseId,createdAt',
      ],
      cwd,
    });

    if (!listResult.ok) {
      structuredError({
        code: 'run_list_failed',
        message: listResult.stderr.trim(),
        subcommand: 'setup-ci verify-run',
        workflow: workflowFile,
      });

      return {exitCode: EXIT_CODES.UNKNOWN_SUBCOMMAND};
    }

    let parsed: unknown;

    try {
      parsed = JSON.parse(listResult.stdout);
    } catch (error) {
      structuredError({
        code: 'run_list_malformed',
        message: error instanceof Error ? error.message : String(error),
        subcommand: 'setup-ci verify-run',
        workflow: workflowFile,
      });

      return {exitCode: EXIT_CODES.UNKNOWN_SUBCOMMAND};
    }

    if (!Array.isArray(parsed)) {
      structuredError({
        code: 'run_list_malformed',
        message: 'gh run list did not return a JSON array',
        subcommand: 'setup-ci verify-run',
        workflow: workflowFile,
      });

      return {exitCode: EXIT_CODES.UNKNOWN_SUBCOMMAND};
    }

    const runId = pickDispatchedRun(parsed as RunListEntry[], notBeforeMs);

    if (runId !== null) return {runId};

    if (attempt < RUN_DISCOVERY_MAX_ATTEMPTS) {
      // eslint-disable-next-line no-await-in-loop -- intentional sequential poll
      await sleep(Math.min(pollIntervalMs, RUN_DISCOVERY_INTERVAL_MS));
    }
  }

  structuredError({
    code: 'run_not_found',
    message:
      `no workflow_dispatch run for ${workflowFile} was created at or ` +
      'after the trigger within the discovery attempt bound',
    subcommand: 'setup-ci verify-run',
    workflow: workflowFile,
  });

  return {exitCode: EXIT_CODES.UNKNOWN_SUBCOMMAND};
};

type TriggerAndCaptureArgs = {
  cwd: string;
  defaultBranch: string;
  pollIntervalMs: number;
  triggerTime: number;
  workflowFile: string;
};

// Steps 1-2: trigger the workflow_dispatch run, then discover its run id.
const triggerAndCaptureRunId = async (
  args: TriggerAndCaptureArgs
): Promise<{exitCode: number} | {runId: string}> => {
  const {cwd, defaultBranch, pollIntervalMs, triggerTime, workflowFile} = args;

  const triggerResult = await triggerWorkflowRun({
    cwd,
    defaultBranch,
    workflowFile,
  });

  if ('exitCode' in triggerResult) return triggerResult;

  return discoverRunId({
    cwd,
    notBeforeMs: triggerTime - CLOCK_SKEW_ALLOWANCE_MS,
    pollIntervalMs,
    workflowFile,
  });
};

type PollRunArgs = {
  cwd: string;
  pollIntervalMs: number;
  runId: string;
  timeoutSeconds: number;
};

type PollRunResult =
  | {conclusion: null | string; timedOut: boolean; url: null | string}
  | {exitCode: number};

// Step 3: poll until completed or timeout.
const pollRunUntilDone = async (args: PollRunArgs): Promise<PollRunResult> => {
  const {cwd, pollIntervalMs, runId, timeoutSeconds} = args;
  const deadline = Date.now() + timeoutSeconds * 1000;
  let url: null | string = null;

  // First call before any sleep so a fast-completing run resolves
  // immediately in tests.
  for (;;) {
    // eslint-disable-next-line no-await-in-loop -- intentional sequential poll
    const view = await runGh({
      args: ['run', 'view', runId, '--json', 'status,conclusion,url'],
      cwd,
    });

    if (!view.ok) {
      // Surface the underlying gh error rather than retrying; gh
      // would have surfaced a transient retry on its own.
      structuredError({
        code: 'run_view_failed',
        message: view.stderr.trim(),
        run_id: runId,
        subcommand: 'setup-ci verify-run',
      });

      return {exitCode: EXIT_CODES.UNKNOWN_SUBCOMMAND};
    }

    let payload: RunViewPayload;

    try {
      payload = JSON.parse(view.stdout) as RunViewPayload;
    } catch (error) {
      structuredError({
        code: 'run_view_malformed',
        message: error instanceof Error ? error.message : String(error),
        run_id: runId,
        subcommand: 'setup-ci verify-run',
      });

      return {exitCode: EXIT_CODES.UNKNOWN_SUBCOMMAND};
    }

    url = payload.url ?? url;

    if (payload.status === 'completed') {
      return {conclusion: payload.conclusion ?? null, timedOut: false, url};
    }

    if (Date.now() >= deadline) {
      return {conclusion: null, timedOut: true, url};
    }

    // eslint-disable-next-line no-await-in-loop -- intentional sequential poll
    await sleep(pollIntervalMs);
  }
};

export const run = async (
  argv: readonly string[],
  options: RunOptions = {}
): Promise<number> => {
  const parsed = parseVerifyRunArgs(argv);

  if ('exitCode' in parsed) return parsed.exitCode;

  const {json, pollIntervalMs, timeoutSeconds, workflowFile} = parsed;
  const cwd = options.cwd ?? process.cwd();

  const branchResult = await resolveDefaultBranch(cwd);

  if ('exitCode' in branchResult) return branchResult.exitCode;

  // Captured before step 1: the lower bound `discoverRunId` requires a
  // listed run's `createdAt` to meet (minus `CLOCK_SKEW_ALLOWANCE_MS`)
  // before treating it as the run just dispatched.
  const triggerTime = Date.now();

  const triggered = await triggerAndCaptureRunId({
    cwd,
    defaultBranch: branchResult.branch,
    pollIntervalMs,
    triggerTime,
    workflowFile,
  });

  if ('exitCode' in triggered) return triggered.exitCode;

  const polled = await pollRunUntilDone({
    cwd,
    pollIntervalMs,
    runId: triggered.runId,
    timeoutSeconds,
  });

  if ('exitCode' in polled) return polled.exitCode;

  const output: VerifyOutput = {
    conclusion: polled.timedOut ? 'polling_timeout' : polled.conclusion,
    run_id: triggered.runId,
    url: polled.url,
    verified: !polled.timedOut && polled.conclusion === 'success',
  };

  if (json) {
    process.stdout.write(`${JSON.stringify(output)}\n`);
  } else {
    printHuman(output);
  }

  return EXIT_CODES.OK;
};
