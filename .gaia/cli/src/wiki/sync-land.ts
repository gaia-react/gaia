/**
 * `gaia wiki sync land [--branch-aware]` handler.
 *
 * Replaces the highest-stakes prose action in GAIA: `wiki/sync.md` Step 7,
 * the branch-aware landing flow that decides between (a) branch + push +
 * PR-merge dance on `main`, or (b) in-place commit on a feature branch.
 *
 * Determinism contract:
 *   - No prose narration on stdout; only a one-line summary.
 *   - All branch-state checks resolve to git/gh exit codes.
 *   - Exit codes:
 *       0  success
 *       1  user-correctable refusal (dirty tree, on main without --branch-aware, ...)
 *       2  unexpected (git/gh process failure passed through)
 *
 * Implementation notes:
 *   - `child_process.spawnSync` is the only shell-out primitive. Every git
 *     and gh invocation routes through `runner`, which tests replace with
 *     a fake.
 *   - Failure of any git/gh step inside the protected-branch landing
 *     sequence short-circuits with exit code 2; no narration, the
 *     command's own stderr is piped through.
 */
import {type SpawnSyncReturns} from 'node:child_process';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {
  currentBranch,
  defaultRunner,
  inspectWorkingTree,
  isProtectedBranch,
  type CommandRunner,
} from './util/branch.js';
import {resolveRepoRoot, shortSha} from './util/git.js';

const HELP_TEXT = `Usage: gaia wiki sync land [--branch-aware]

  Land staged wiki changes via the correct branch strategy:
    - on main/master: refuses unless --branch-aware (then branch + PR + auto-merge)
    - elsewhere:      in-place commit on the current branch

  Exit codes:
    0  success
    1  user-correctable refusal (dirty tree, missing flag, ...)
    2  unexpected (git/gh failure)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const UNEXPECTED_EXIT = 2;

type ParsedFlags = {
  branchAware: boolean;
};

type FlagParseSuccess = {
  flags: ParsedFlags;
  ok: true;
};

type FlagParseFailure = {
  message: string;
  ok: false;
};

type FlagParseResult = FlagParseFailure | FlagParseSuccess;

const parseFlags = (argv: readonly string[]): FlagParseResult => {
  let branchAware = false;

  for (const token of argv) {
    if (token === '--branch-aware') {
      branchAware = true;
      continue;
    }

    return {message: `unknown flag: ${token}`, ok: false};
  }

  return {flags: {branchAware}, ok: true};
};

const refuse = (message: string): number => {
  process.stderr.write(`${message}\n`);

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};

type RunStep = {
  args: readonly string[];
  command: string;
  /**
   * Marks the post-step state transition the rollback logic depends on.
   * Set explicitly on the step descriptor so reordering or inserting steps
   * cannot silently break flag derivation (vs. inspecting the first argv
   * token).
   */
  marks?: 'onSyncBranch' | 'staged';
};

const runStep = (
  runner: CommandRunner,
  step: RunStep,
  cwd: string
): SpawnSyncReturns<string> => runner(step.command, step.args, {cwd});

const passthroughFailure = (
  result: SpawnSyncReturns<string>,
  step: RunStep
): number => {
  // Surface the failing command + its stderr so the caller has enough
  // context to diagnose without re-running. The CLI itself adds nothing.
  const stderr = (result.stderr ?? '').trim();
  const errorPart =
    result.error !== undefined ? ` (${result.error.message})` : '';
  const status = result.status ?? -1;
  process.stderr.write(
    `sync-land: ${step.command} ${step.args.join(' ')} exited ${status}${errorPart}\n`
  );

  if (stderr.length > 0) {
    process.stderr.write(`${stderr}\n`);
  }

  return UNEXPECTED_EXIT;
};

const stepSucceeded = (result: SpawnSyncReturns<string>): boolean =>
  result.error === undefined && (result.status ?? -1) === 0;

type LandingContext = {
  cwd: string;
  originalBranch: string;
  runner: CommandRunner;
  shortHead: string;
};

const inPlaceLanding = (ctx: LandingContext): number => {
  const message = `wiki: sync through ${ctx.shortHead}`;
  const sequence: RunStep[] = [
    {args: ['add', 'wiki'], command: 'git', marks: 'staged'},
    {args: ['commit', '-m', message], command: 'git'},
  ];

  let staged = false;

  for (const step of sequence) {
    const result = runStep(ctx.runner, step, ctx.cwd);

    if (!stepSucceeded(result)) {
      if (staged) {
        // Unstage `wiki` so a failed commit leaves a clean index behind.
        runStep(
          ctx.runner,
          {args: ['reset', 'HEAD', '--', 'wiki'], command: 'git'},
          ctx.cwd
        );
      }

      return passthroughFailure(result, step);
    }

    if (step.marks === 'staged') staged = true;
  }

  process.stdout.write(
    `sync-land: landed via in-place commit ${ctx.shortHead}\n`
  );

  return EXIT_CODES.OK;
};

const todayUtc = (now: Date = new Date()): string => {
  const year = now.getUTCFullYear();
  const month = String(now.getUTCMonth() + 1).padStart(2, '0');
  const day = String(now.getUTCDate()).padStart(2, '0');

  return `${year}-${month}-${day}`;
};

/**
 * Best-effort rollback of the local-only landing steps: return to the
 * original branch and delete the half-created sync branch. Remote state is
 * never auto-reverted. The rollback git calls are themselves best-effort;
 * a failure here is not surfaced over the original step failure.
 */
const rollbackLocalLanding = (
  ctx: LandingContext,
  branchName: string,
  onSyncBranch: boolean
): void => {
  if (!onSyncBranch) return;

  // Unstage `wiki` before switching branches so a failed commit does not
  // carry a dirty index back to the original branch on checkout.
  runStep(
    ctx.runner,
    {args: ['reset', 'HEAD', '--', 'wiki'], command: 'git'},
    ctx.cwd
  );
  runStep(
    ctx.runner,
    {args: ['checkout', ctx.originalBranch], command: 'git'},
    ctx.cwd
  );
  runStep(
    ctx.runner,
    {args: ['branch', '-D', branchName], command: 'git'},
    ctx.cwd
  );
};

const protectedBranchLanding = (
  ctx: LandingContext,
  options: {today: string}
): number => {
  const branchName = `wiki-sync/${options.today}-${ctx.shortHead}`;
  const message = `wiki: sync through ${ctx.shortHead}`;
  const prTitle = message;
  const prBody = `Automated wiki sync landed via \`gaia wiki sync land --branch-aware\`. State advanced to ${ctx.shortHead}.`;

  // Steps through the local commit are reversible; once `push` succeeds the
  // branch (and possibly a PR) exists on the remote and is left for the
  // maintainer to resolve rather than force-reverted.
  const localSequence: RunStep[] = [
    {
      args: ['checkout', '-b', branchName],
      command: 'git',
      marks: 'onSyncBranch',
    },
    {args: ['add', 'wiki'], command: 'git'},
    {args: ['commit', '-m', message], command: 'git'},
  ];
  const remoteSequence: RunStep[] = [
    {args: ['push', '-u', 'origin', branchName], command: 'git'},
    {
      args: ['pr', 'create', '--title', prTitle, '--body', prBody],
      command: 'gh',
    },
    {args: ['pr', 'merge', '--squash', '--auto'], command: 'gh'},
  ];

  let onSyncBranch = false;

  for (const step of localSequence) {
    const result = runStep(ctx.runner, step, ctx.cwd);

    if (!stepSucceeded(result)) {
      rollbackLocalLanding(ctx, branchName, onSyncBranch);

      return passthroughFailure(result, step);
    }

    if (step.marks === 'onSyncBranch') onSyncBranch = true;
  }

  for (const step of remoteSequence) {
    const result = runStep(ctx.runner, step, ctx.cwd);

    if (!stepSucceeded(result)) return passthroughFailure(result, step);
  }

  process.stdout.write(
    `sync-land: landed via branch-and-PR commit ${ctx.shortHead}\n`
  );

  return EXIT_CODES.OK;
};

type RunOptions = {
  cwd?: string;
  runner?: CommandRunner;
  /** Override "today" for deterministic tests. ISO-8601 date string. */
  today?: string;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  if (argv.length > 0 && HELP_TOKENS.has(argv[0] as string)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const parsed = parseFlags(argv);

  if (!parsed.ok) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.message,
      subcommand: 'wiki sync land',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwdOption = options.cwd ?? process.cwd();
  const runner = options.runner ?? defaultRunner;

  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(cwdOption);
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: 'gaia wiki sync land must run inside a git repository',
      subcommand: 'wiki sync land',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let branch: string;
  let workingTree: ReturnType<typeof inspectWorkingTree>;

  try {
    branch = currentBranch(repoRoot, runner);
    workingTree = inspectWorkingTree(repoRoot, runner);
  } catch (error) {
    process.stderr.write(
      `sync-land: ${error instanceof Error ? error.message : String(error)}\n`
    );

    return UNEXPECTED_EXIT;
  }

  if (workingTree.hasNonWikiChanges) {
    return refuse('sync-land: working tree has non-wiki changes; aborting');
  }

  if (!workingTree.hasWikiChanges) {
    return refuse('sync-land: nothing to land');
  }

  if (isProtectedBranch(branch) && !parsed.flags.branchAware) {
    return refuse(
      'sync-land: refusing to land directly on main; pass --branch-aware or check out a feature branch'
    );
  }

  let shortHead: string;

  try {
    const head = spawnHead(runner, repoRoot);
    shortHead = shortSha(head, repoRoot);
  } catch (error) {
    process.stderr.write(
      `sync-land: ${error instanceof Error ? error.message : String(error)}\n`
    );

    return UNEXPECTED_EXIT;
  }

  const ctx: LandingContext = {
    cwd: repoRoot,
    originalBranch: branch,
    runner,
    shortHead,
  };

  if (isProtectedBranch(branch)) {
    return protectedBranchLanding(ctx, {today: options.today ?? todayUtc()});
  }

  return inPlaceLanding(ctx);
};

/**
 * Resolve HEAD via the injected runner so tests can stub it. Mirrors
 * the argv of the shared `headSha` helper in `util/git.ts`, but routes
 * through the runner indirection so a mocked runner sees the call.
 */
const spawnHead = (runner: CommandRunner, cwd: string): string => {
  const result = runner('git', ['rev-parse', 'HEAD'], {cwd});

  if (result.error !== undefined) {
    throw new Error(`git rev-parse HEAD failed: ${result.error.message}`);
  }

  if ((result.status ?? -1) !== 0) {
    const stderr = (result.stderr ?? '').trim();
    throw new Error(
      `git rev-parse HEAD exited ${result.status ?? -1}: ${stderr}`
    );
  }

  return (result.stdout ?? '').trim();
};
