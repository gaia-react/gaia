/**
 * `gaia setup-ci verify-run <workflow-file> [--timeout-seconds N] [--json]` handler.
 *
 * Triggers a `workflow_dispatch` run via `gh workflow run <file> --ref
 * <default-branch>`, captures the run id, and polls `gh run view <id>`
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
 * `conclusion: "polling_timeout"` and `verified: false`. Race-window
 * note: step 3 picks the most recent run for the workflow file. If
 * the user triggered a manual run between step 2 and step 3, the
 * latest one could be theirs. As a soft guard, the handler captures
 * `Date.now()` immediately before step 1 and compares it against the
 * picked run's `createdAt`; a `createdAt` more than 5s before that
 * timestamp emits a stderr warning but proceeds without failing.
 *
 * The handler exits 0 regardless of `verified` — the slash command
 * branches on the JSON. Exits non-zero only on hard `gh` errors (e.g.
 * `gh workflow run` failed entirely).
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
const RACE_WINDOW_GUARD_MS = 5_000;

type RunOptions = {
  cwd?: string;
};

type VerifyOutput = {
  conclusion: null | string;
  run_id: null | string;
  url: null | string;
  verified: boolean;
};

type RunListEntry = {createdAt?: string; databaseId: number | string};

type RunViewPayload = {conclusion?: null | string; status?: string; url?: string};

/**
 * Parse a strictly-decimal positive integer. Unlike `Number.parseInt`,
 * this rejects trailing garbage (`"30abc"`), leading signs, and empty
 * strings — returns `null` for anything that is not all digits.
 */
const parsePositiveInt = (value: string): number | null => {
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
      defaultBranchRef?: {name?: unknown} | null;
    };
    const name = parsed.defaultBranchRef?.name;

    return typeof name === 'string' && name.length > 0 ? name : null;
  } catch {
    return null;
  }
};

const sleep = (ms: number): Promise<void> =>
  new Promise((resolve) => {
    setTimeout(resolve, ms);
  });

const printHuman = (output: VerifyOutput): void => {
  process.stdout.write(
    `verified: ${String(output.verified)}\n`
      + `run_id: ${output.run_id ?? '(none)'}\n`
      + `conclusion: ${output.conclusion ?? '(none)'}\n`
      + `url: ${output.url ?? '(none)'}\n`
  );
};

export const run = async (
  argv: readonly string[],
  options: RunOptions = {}
): Promise<number> => {
  let json = false;
  let workflowFile: string | undefined;
  let timeoutSeconds: number | null = DEFAULT_TIMEOUT_SECONDS;
  let pollIntervalMs: number | null = DEFAULT_POLL_INTERVAL_MS;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string;

    if (HELP_TOKENS.has(token)) {
      process.stdout.write(HELP_TEXT);

      return EXIT_CODES.OK;
    }

    if (token === '--json') {
      json = true;

      continue;
    }

    if (token === '--timeout-seconds') {
      const value = argv[index + 1];

      if (value === undefined) {
        structuredError({
          code: 'invalid_arguments',
          message: '--timeout-seconds requires a value',
          subcommand: 'setup-ci verify-run',
        });

        return EXIT_CODES.UNKNOWN_SUBCOMMAND;
      }
      timeoutSeconds = parsePositiveInt(value);
      index += 1;

      continue;
    }

    if (token === '--poll-interval-ms') {
      const value = argv[index + 1];

      if (value === undefined) {
        structuredError({
          code: 'invalid_arguments',
          message: '--poll-interval-ms requires a value',
          subcommand: 'setup-ci verify-run',
        });

        return EXIT_CODES.UNKNOWN_SUBCOMMAND;
      }
      pollIntervalMs = parsePositiveInt(value);
      index += 1;

      continue;
    }

    if (token.startsWith('--')) {
      structuredError({
        code: 'invalid_arguments',
        message: `unknown flag: ${token}`,
        subcommand: 'setup-ci verify-run',
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }

    if (workflowFile === undefined) {
      workflowFile = token;

      continue;
    }

    structuredError({
      code: 'invalid_arguments',
      message: `unexpected argument: ${token}`,
      subcommand: 'setup-ci verify-run',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (workflowFile === undefined) {
    structuredError({
      code: 'missing_required_arg',
      message: 'verify-run requires <workflow-file>',
      subcommand: 'setup-ci verify-run',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (timeoutSeconds === null) {
    structuredError({
      code: 'invalid_arguments',
      message: '--timeout-seconds must be a positive integer',
      subcommand: 'setup-ci verify-run',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (pollIntervalMs === null) {
    structuredError({
      code: 'invalid_arguments',
      message: '--poll-interval-ms must be a positive integer',
      subcommand: 'setup-ci verify-run',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();

  // Step 0: resolve the repository's default branch. Hardcoding `main`
  // breaks repos whose default branch differs (e.g. `master`, `trunk`).
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

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const defaultBranch = parseDefaultBranch(repoViewResult.stdout);

  if (defaultBranch === null) {
    structuredError({
      code: 'default_branch_lookup_failed',
      message: 'could not resolve defaultBranchRef from gh repo view output',
      subcommand: 'setup-ci verify-run',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  // Captured before step 1 so the race-window guard below can compare
  // the picked run's `createdAt` against the moment we asked GH to
  // start one. Any run created earlier than this minus a small fudge
  // is suspicious (someone else dispatched between our list call and
  // ours actually appearing).
  const triggerTime = Date.now();

  // Step 1: trigger the run.
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

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  // Step 2: capture the most recent run id for the workflow.
  const listResult = await runGh({
    args: [
      'run',
      'list',
      `--workflow=${workflowFile}`,
      '--limit',
      '1',
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

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let runId: string;

  try {
    const parsed = JSON.parse(listResult.stdout) as RunListEntry[];
    const first = parsed[0];

    if (first === undefined) {
      structuredError({
        code: 'run_list_empty',
        message: `gh run list returned no runs for ${workflowFile}`,
        subcommand: 'setup-ci verify-run',
        workflow: workflowFile,
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }
    runId = String(first.databaseId);

    if (first.createdAt !== undefined) {
      const createdAtMs = new Date(first.createdAt).getTime();

      if (
        !Number.isNaN(createdAtMs)
        && createdAtMs < triggerTime - RACE_WINDOW_GUARD_MS
      ) {
        process.stderr.write(
          `verify-run: warning — picked run ${runId} createdAt `
            + `${first.createdAt} predates trigger time by `
            + `${triggerTime - createdAtMs}ms; may be a concurrent dispatch\n`
        );
      }
    }
  } catch (error) {
    structuredError({
      code: 'run_list_malformed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'setup-ci verify-run',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  // Step 3: poll until completed or timeout.
  const deadline = Date.now() + timeoutSeconds * 1000;
  let conclusion: null | string = null;
  let url: null | string = null;
  let timedOut = false;

  // First call before any sleep so a fast-completing run resolves
  // immediately in tests.
  while (true) {
    const view = await runGh({
      args: [
        'run',
        'view',
        runId,
        '--json',
        'status,conclusion,url',
      ],
      cwd,
    });

    if (!view.ok) {
      // Surface the underlying gh error rather than retrying — gh
      // would have surfaced a transient retry on its own.
      structuredError({
        code: 'run_view_failed',
        message: view.stderr.trim(),
        run_id: runId,
        subcommand: 'setup-ci verify-run',
      });

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
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

      return EXIT_CODES.UNKNOWN_SUBCOMMAND;
    }

    url = payload.url ?? url;

    if (payload.status === 'completed') {
      conclusion = payload.conclusion ?? null;
      break;
    }

    if (Date.now() >= deadline) {
      timedOut = true;
      break;
    }

    await sleep(pollIntervalMs);
  }

  const output: VerifyOutput = {
    conclusion: timedOut ? 'polling_timeout' : conclusion,
    run_id: runId,
    url,
    verified: !timedOut && conclusion === 'success',
  };

  if (json) {
    process.stdout.write(`${JSON.stringify(output)}\n`);
  } else {
    printHuman(output);
  }

  return EXIT_CODES.OK;
};
