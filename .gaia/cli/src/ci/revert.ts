/**
 * `gaia ci-revert {open|mark-failed|is-cap-reached}`
 *
 * Owner of the SPEC's hard-cap rule: one revert attempt per original PR
 * (UAT-009/UAT-010). The CLI is the single enforcement surface — the
 * Phase 2 composite action trusts the CLI's exit codes and never
 * inspects the ledger directly.
 *
 * State file: `.gaia/automation.state-revert-attempts.json`
 * (committed). Schema and atomic writer in `schemas/revert-ledger.ts`.
 */
import {EXIT_CODES} from '../exit.js';
import {
  emptyRevertLedger,
  readRevertLedger,
  withRevertLedgerLock,
  writeRevertLedger,
  type RevertLedger,
} from '../schemas/revert-ledger.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../wiki/util/git.js';
import {runGh, runGit, type ProcessResult} from './util/run-process.js';

const HELP_TEXT = `Usage: gaia ci-revert <subcommand> [args]

  open --pr <N> --label <name> [--reason <text>] [--json]
    Open a single revert PR for the merged PR <N>. Refuses with
    revert_already_opened if a ledger entry exists. Hard cap.

  mark-failed --pr <N> [--json]
    Flip attempts[<N>].status to "failed" (revert PR's CI also red).

  is-cap-reached --pr <N> [--json]
    Print {cap_reached, status} for the original PR.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type RunOptions = {
  cwd?: string;
  now?: () => Date;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  if (argv.length === 0 || HELP_TOKENS.has(argv[0] as string)) {
    process.stdout.write(HELP_TEXT);

    return argv.length === 0 ? EXIT_CODES.UNKNOWN_SUBCOMMAND : EXIT_CODES.OK;
  }

  const sub = argv[0] as string;
  const rest = argv.slice(1);

  if (sub === 'open') return handleOpen(rest, options);
  if (sub === 'mark-failed') return handleMarkFailed(rest, options);
  if (sub === 'is-cap-reached') return handleIsCapReached(rest, options);

  structuredError({
    code: 'unknown_subcommand',
    message: `unknown ci-revert subcommand: ${sub}`,
    subcommand: 'ci-revert',
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};

type CommonArgs = {
  json: boolean;
  pr: number | undefined;
};

const parsePrFlag = (value: string | undefined): number | undefined => {
  if (value === undefined) return undefined;
  const parsed = Number.parseInt(value, 10);

  if (!Number.isInteger(parsed) || parsed <= 0) return undefined;

  return parsed;
};

const resolveRoot = (
  options: RunOptions,
  subcommand: string
): string | null => {
  try {
    return resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: `gaia ci-revert ${subcommand} must run inside a git repository`,
      subcommand: `ci-revert ${subcommand}`,
    });

    return null;
  }
};

const ensureLedger = (
  repoRoot: string,
  subcommand: string,
  json: boolean
): RevertLedger | null => {
  const result = readRevertLedger(repoRoot);

  if (result.status === 'malformed') {
    const payload = {error: 'malformed_ledger', details: result.error};
    structuredError({
      code: 'malformed_ledger',
      message: result.error,
      subcommand: `ci-revert ${subcommand}`,
    });

    if (json) {
      process.stdout.write(`${JSON.stringify(payload)}\n`);
    }

    return null;
  }

  if (result.status === 'missing') return emptyRevertLedger();

  return result.ledger;
};

// --- open ----------------------------------------------------------------

type OpenArgs = CommonArgs & {
  label: string | undefined;
  reason: string | undefined;
};

const parseOpenArgs = (argv: readonly string[]): OpenArgs | string => {
  let pr: number | undefined;
  let label: string | undefined;
  let reason: string | undefined;
  let json = false;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string;

    if (token === '--json') {
      json = true;

      continue;
    }

    if (token === '--pr') {
      pr = parsePrFlag(argv[index + 1]);
      index += 1;

      continue;
    }

    if (token === '--label') {
      label = argv[index + 1];
      index += 1;

      continue;
    }

    if (token === '--reason') {
      reason = argv[index + 1];
      index += 1;

      continue;
    }

    return `unknown argument: ${token}`;
  }

  return {json, label, pr, reason};
};

const parsePrUrlNumber = (urlOrText: string): number | null => {
  // gh pr create stdout is the URL; sometimes a banner line precedes it.
  // We scan every whitespace-delimited token for the first one ending in
  // /pull/<digits> or /<digits>.
  const tokens = urlOrText.split(/\s+/u).filter((token) => token.length > 0);

  for (let i = tokens.length - 1; i >= 0; i -= 1) {
    const token = tokens[i] as string;
    const pullMatch = /\/pull\/(\d+)$/u.exec(token);

    if (pullMatch !== null) return Number.parseInt(pullMatch[1] as string, 10);

    const trailingMatch = /\/(\d+)$/u.exec(token);

    if (trailingMatch !== null)
      return Number.parseInt(trailingMatch[1] as string, 10);
  }

  return null;
};

const DEFAULT_REVERT_BODY = (originalPr: number): string =>
  `Auto-revert of #${originalPr} opened by GAIA CI after post-merge CI failure.\n\n` +
  `This PR will auto-merge on green CI. If its CI also fails, GAIA CI will\n` +
  `stop automated activity on this change and open a \`priority:critical\`\n` +
  `issue requesting human intervention.\n`;

const surfaceRevertFailure = (
  step: string,
  result: ProcessResult,
  json: boolean
): number => {
  const details =
    result.stderr.trim() ||
    result.stdout.trim() ||
    `exit code ${result.exitCode}`;
  const payload = {error: 'revert_failed', step, details};
  structuredError({
    code: 'revert_failed',
    details,
    message: `revert failed at step ${step}`,
    step,
    subcommand: 'ci-revert open',
  });

  if (json) {
    process.stdout.write(`${JSON.stringify(payload)}\n`);
  }

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};

const handleOpen = (argv: readonly string[], options: RunOptions): number => {
  const parsed = parseOpenArgs(argv);

  if (typeof parsed === 'string') {
    structuredError({
      code: 'invalid_arguments',
      message: parsed,
      subcommand: 'ci-revert open',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const {json, label, pr, reason} = parsed;

  if (pr === undefined) {
    structuredError({
      code: 'invalid_arguments',
      message: 'ci-revert open requires --pr <N> (positive integer)',
      subcommand: 'ci-revert open',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (label === undefined || label === '') {
    structuredError({
      code: 'invalid_arguments',
      message: 'ci-revert open requires --label <name>',
      subcommand: 'ci-revert open',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const repoRoot = resolveRoot(options, 'open');

  if (repoRoot === null) return EXIT_CODES.UNKNOWN_SUBCOMMAND;

  // Serialize the ledger read-check-write so the "one revert per PR"
  // hard cap is not defeated by two concurrent `ci-revert open` runs for
  // the same PR both passing the existence check before either writes.
  // The lock is scoped to `pr` — reverts of distinct PRs do not block.
  const locked = withRevertLedgerLock(repoRoot, pr, () =>
    handleOpenLocked({json, label, options, pr, reason, repoRoot})
  );

  if (!locked.locked) {
    const payload = {error: 'revert_lock_held'};
    structuredError({
      code: 'revert_lock_held',
      message: 'another ci-revert open is in progress for this repository',
      subcommand: 'ci-revert open',
    });

    if (json) {
      process.stdout.write(`${JSON.stringify(payload)}\n`);
    }

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  return locked.value;
};

type HandleOpenLockedArgs = {
  json: boolean;
  label: string;
  options: RunOptions;
  pr: number;
  reason: string | undefined;
  repoRoot: string;
};

const handleOpenLocked = (args: HandleOpenLockedArgs): number => {
  const {json, label, options, pr, reason, repoRoot} = args;

  const ledger = ensureLedger(repoRoot, 'open', json);

  if (ledger === null) return EXIT_CODES.UNKNOWN_SUBCOMMAND;

  const key = String(pr);
  const existing = ledger.attempts[key];

  if (existing !== undefined) {
    const payload = {
      error: 'revert_already_opened',
      existing_revert_pr: existing.revert_pr,
    };
    structuredError({
      code: 'revert_already_opened',
      existing_revert_pr: existing.revert_pr,
      message: `revert already opened for PR #${pr} (revert PR #${existing.revert_pr})`,
      subcommand: 'ci-revert open',
    });

    if (json) {
      process.stdout.write(`${JSON.stringify(payload)}\n`);
    }

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  // Step 4: gh pr view
  const viewResult = runGh(
    [
      'pr',
      'view',
      String(pr),
      '--json',
      'mergeCommit,headRefName,baseRefName,title',
    ],
    {cwd: repoRoot}
  );

  if (viewResult.exitCode !== 0) {
    return surfaceRevertFailure('gh_pr_view', viewResult, json);
  }

  let view: {
    baseRefName?: unknown;
    headRefName?: unknown;
    mergeCommit?: unknown;
    title?: unknown;
  };

  try {
    view = JSON.parse(viewResult.stdout) as Record<string, unknown>;
  } catch (error) {
    return surfaceRevertFailure(
      'gh_pr_view_parse',
      {
        exitCode: 1,
        stderr: error instanceof Error ? error.message : String(error),
        stdout: '',
      },
      json
    );
  }

  const mergeCommit = view.mergeCommit;
  const mergeSha =
    (
      typeof mergeCommit === 'object' &&
      mergeCommit !== null &&
      typeof (mergeCommit as Record<string, unknown>).oid === 'string'
    ) ?
      ((mergeCommit as Record<string, unknown>).oid as string)
    : null;

  if (mergeSha === null) {
    const payload = {error: 'pr_not_merged', pr};
    structuredError({
      code: 'pr_not_merged',
      message: `PR #${pr} has no merge commit; cannot revert`,
      pr,
      subcommand: 'ci-revert open',
    });

    if (json) {
      process.stdout.write(`${JSON.stringify(payload)}\n`);
    }

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const headRefName =
    typeof view.headRefName === 'string' ? view.headRefName : null;
  const baseRefName =
    typeof view.baseRefName === 'string' ? view.baseRefName : null;
  const title = typeof view.title === 'string' ? view.title : `PR #${pr}`;

  if (headRefName === null || baseRefName === null) {
    return surfaceRevertFailure(
      'gh_pr_view_parse',
      {exitCode: 1, stderr: 'missing headRefName / baseRefName', stdout: ''},
      json
    );
  }

  const shortSha = mergeSha.slice(0, 7);
  const revertBranch = `gaia-ci/revert/${headRefName}-${shortSha}`;

  // Step 6: git fetch / checkout / revert / push
  const fetchResult = runGit(['fetch', 'origin', baseRefName], {cwd: repoRoot});

  if (fetchResult.exitCode !== 0) {
    return surfaceRevertFailure('git_fetch', fetchResult, json);
  }

  // Capture the branch the repo was on before we create the revert
  // branch, so a later failure can restore it. An empty result (detached
  // HEAD) is fine — the rollback simply skips the checkout-back step.
  const priorBranchResult = runGit(
    ['symbolic-ref', '--quiet', '--short', 'HEAD'],
    {cwd: repoRoot}
  );
  const priorBranch =
    priorBranchResult.exitCode === 0 ? priorBranchResult.stdout.trim() : '';

  const checkoutResult = runGit(
    ['checkout', '-b', revertBranch, `origin/${baseRefName}`],
    {cwd: repoRoot}
  );

  if (checkoutResult.exitCode !== 0) {
    return surfaceRevertFailure('git_checkout', checkoutResult, json);
  }

  // Restore the repo to its pre-revert state: leave the revert branch
  // and delete it. Best-effort — every step is non-fatal because the
  // surfaced failure is the one that matters.
  const rollbackRevertBranch = (): void => {
    if (priorBranch !== '') {
      runGit(['checkout', '--force', priorBranch], {cwd: repoRoot});
    } else {
      runGit(['checkout', '--force', `origin/${baseRefName}`], {cwd: repoRoot});
    }
    runGit(['branch', '-D', revertBranch], {cwd: repoRoot});
  };

  const revertResult = runGit(['revert', '--no-edit', mergeSha], {
    cwd: repoRoot,
  });

  if (revertResult.exitCode !== 0) {
    // Abort the in-progress revert, then unwind the branch we created so
    // the repo is left exactly as we found it.
    runGit(['revert', '--abort'], {cwd: repoRoot});
    rollbackRevertBranch();

    return surfaceRevertFailure('git_revert', revertResult, json);
  }

  const pushResult = runGit(['push', '-u', 'origin', revertBranch], {
    cwd: repoRoot,
  });

  if (pushResult.exitCode !== 0) {
    // The local branch carries a committed revert; a failed push leaves
    // a non-atomic mutation behind. Roll the local repo back to its
    // prior state so a retry starts clean.
    rollbackRevertBranch();

    return surfaceRevertFailure('git_push', pushResult, json);
  }

  const body = reason ?? DEFAULT_REVERT_BODY(pr);

  const createResult = runGh(
    [
      'pr',
      'create',
      '--base',
      baseRefName,
      '--head',
      revertBranch,
      '--title',
      `Revert: ${title}`,
      '--body',
      body,
      '--label',
      label,
    ],
    {cwd: repoRoot}
  );

  if (createResult.exitCode !== 0) {
    return surfaceRevertFailure('gh_pr_create', createResult, json);
  }

  const newPr = parsePrUrlNumber(createResult.stdout);

  if (newPr === null) {
    return surfaceRevertFailure(
      'gh_pr_create_parse',
      {
        exitCode: 1,
        stderr: `unable to parse PR number from: ${createResult.stdout}`,
        stdout: '',
      },
      json
    );
  }

  const mergeAutoResult = runGh(
    ['pr', 'merge', String(newPr), '--auto', '--squash'],
    {cwd: repoRoot}
  );

  if (mergeAutoResult.exitCode !== 0) {
    return surfaceRevertFailure('gh_pr_merge_auto', mergeAutoResult, json);
  }

  // Update the ledger.
  const nowDate = (options.now ?? (() => new Date()))();
  ledger.attempts[key] = {
    opened_at: nowDate.toISOString(),
    original_pr: pr,
    revert_pr: newPr,
    status: 'open',
  };
  writeRevertLedger(repoRoot, ledger);

  const success = {
    original_pr: pr,
    revert_branch: revertBranch,
    revert_pr: newPr,
  };

  if (json) {
    process.stdout.write(`${JSON.stringify(success)}\n`);
  } else {
    process.stdout.write(
      `revert PR #${newPr} opened on branch ${revertBranch} for #${pr}\n`
    );
  }

  return EXIT_CODES.OK;
};

// --- mark-failed ---------------------------------------------------------

const parseSimplePrArgs = (argv: readonly string[]): CommonArgs | string => {
  let pr: number | undefined;
  let json = false;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string;

    if (token === '--json') {
      json = true;

      continue;
    }

    if (token === '--pr') {
      pr = parsePrFlag(argv[index + 1]);
      index += 1;

      continue;
    }

    return `unknown argument: ${token}`;
  }

  return {json, pr};
};

const handleMarkFailed = (
  argv: readonly string[],
  options: RunOptions
): number => {
  const parsed = parseSimplePrArgs(argv);

  if (typeof parsed === 'string') {
    structuredError({
      code: 'invalid_arguments',
      message: parsed,
      subcommand: 'ci-revert mark-failed',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const {json, pr} = parsed;

  if (pr === undefined) {
    structuredError({
      code: 'invalid_arguments',
      message: 'ci-revert mark-failed requires --pr <N>',
      subcommand: 'ci-revert mark-failed',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const repoRoot = resolveRoot(options, 'mark-failed');

  if (repoRoot === null) return EXIT_CODES.UNKNOWN_SUBCOMMAND;

  const ledger = ensureLedger(repoRoot, 'mark-failed', json);

  if (ledger === null) return EXIT_CODES.UNKNOWN_SUBCOMMAND;

  const key = String(pr);
  const entry = ledger.attempts[key];

  if (entry === undefined) {
    const payload = {error: 'no_revert_attempt', pr};
    structuredError({
      code: 'no_revert_attempt',
      message: `no revert attempt recorded for PR #${pr}`,
      pr,
      subcommand: 'ci-revert mark-failed',
    });

    if (json) {
      process.stdout.write(`${JSON.stringify(payload)}\n`);
    }

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  ledger.attempts[key] = {...entry, status: 'failed'};
  writeRevertLedger(repoRoot, ledger);

  const success = {
    original_pr: entry.original_pr,
    revert_pr: entry.revert_pr,
    status: 'failed',
  };

  if (json) {
    process.stdout.write(`${JSON.stringify(success)}\n`);
  } else {
    process.stdout.write(
      `marked revert attempt for PR #${pr} as failed (revert PR #${entry.revert_pr})\n`
    );
  }

  return EXIT_CODES.OK;
};

// --- is-cap-reached ------------------------------------------------------

const handleIsCapReached = (
  argv: readonly string[],
  options: RunOptions
): number => {
  const parsed = parseSimplePrArgs(argv);

  if (typeof parsed === 'string') {
    structuredError({
      code: 'invalid_arguments',
      message: parsed,
      subcommand: 'ci-revert is-cap-reached',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const {json, pr} = parsed;

  if (pr === undefined) {
    structuredError({
      code: 'invalid_arguments',
      message: 'ci-revert is-cap-reached requires --pr <N>',
      subcommand: 'ci-revert is-cap-reached',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const repoRoot = resolveRoot(options, 'is-cap-reached');

  if (repoRoot === null) return EXIT_CODES.UNKNOWN_SUBCOMMAND;

  const ledger = ensureLedger(repoRoot, 'is-cap-reached', json);

  if (ledger === null) return EXIT_CODES.UNKNOWN_SUBCOMMAND;

  const entry = ledger.attempts[String(pr)];
  const status = entry?.status ?? null;
  const capReached = status === 'open' || status === 'failed';

  const payload = {cap_reached: capReached, status};

  if (json) {
    process.stdout.write(`${JSON.stringify(payload)}\n`);
  } else {
    process.stdout.write(
      `cap_reached: ${String(capReached)}\nstatus: ${status ?? '(none)'}\n`
    );
  }

  return EXIT_CODES.OK;
};
