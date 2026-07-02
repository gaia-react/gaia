/**
 * `gaia wiki chain <begin|commit|finish>` handler.
 *
 * Orchestrates the `/gaia-wiki` full chain (sync → consolidate → lint) so it
 * lands on ONE branch and ONE PR instead of each stage landing independently.
 * The router (`references/wiki.md`) calls:
 *   begin   once, before sync         → cut `wiki-sync/<date>-<sha>` on main
 *   commit  after consolidate & lint   → in-place commit of that stage's edits
 *   finish  once, after lint           → push + PR + auto-merge, then wait for
 *                                        the merge and clean up locally
 *
 * `begin` runs BEFORE sync on purpose: sync's own Step 7 (`gaia wiki sync land
 * --branch-aware`) then sees a feature branch and commits in place rather than
 * opening its own premature PR. On a feature branch every action degrades to a
 * no-op or a plain in-place commit, so a full chain run from a feature branch
 * leaves its commits there for the developer to land their own way.
 *
 * Determinism contract mirrors `sync-land.ts`: no prose narration on stdout
 * (one-line summaries only), every git/gh call routes through an injectable
 * `runner`, and exit codes are 0 (ok) / 1 (user-correctable refusal) /
 * 2 (unexpected git/gh process failure, stderr piped through).
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {
  currentBranch,
  defaultBranch,
  defaultRunner,
  inspectWorkingTree,
  isProtectedBranch,
  type CommandRunner,
} from './util/branch.js';
import {resolveRepoRoot, shortSha} from './util/git.js';
import {
  UNEXPECTED_EXIT,
  commandSucceeded,
  finalizeMerge,
  passthroughFailure as passthroughFailureWithPrefix,
  refuse,
  todayUtc,
} from './util/land.js';

const WIKI_CHAIN_BRANCH_PREFIX = 'wiki-sync/';

const passthroughFailure = (
  result: Parameters<typeof passthroughFailureWithPrefix>[1],
  command: string,
  args: readonly string[]
): number => passthroughFailureWithPrefix('chain', result, command, args);

const stepOk = commandSucceeded;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const HELP_TEXT = `Usage: gaia wiki chain <begin|commit|finish> [args]

  begin [--branch-aware]       On main/master: cut wiki-sync/<date>-<sha> so the
                               whole chain lands on one branch + PR. On a feature
                               branch: no-op (the chain commits in place).
  commit --label "<subject>"   In-place commit of this stage's wiki/ changes.
                               No-op when nothing changed; refuses non-wiki changes.
  finish [--branch-aware]      Push the chain branch, open one PR, enable
                               auto-merge, then wait for the PR to merge and
                               clean up locally (return to base, pull, delete the
                               branch, prune). If the merge does not land within
                               the wait, auto-merge stays queued and local
                               cleanup is deferred. Removes an empty chain branch;
                               no-op for in-place runs.

  Exit codes:
    0  success
    1  user-correctable refusal (on main without --branch-aware, missing --label, ...)
    2  unexpected (git/gh failure)
`;

type RunOptions = {
  cwd?: string;
  runner?: CommandRunner;
  /** Override "today" for deterministic tests. ISO-8601 date string. */
  today?: string;
  /** Override the merge-poll attempt count in `finish` (tests pass a small n). */
  mergePollAttempts?: number;
  /** Override the inter-poll sleep in `finish` (tests pass a no-op). */
  sleep?: (ms: number) => void;
};

const resolveRoot = (cwdOption: string, action: string): string | null => {
  try {
    return resolveRepoRoot(cwdOption);
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: 'gaia wiki chain must run inside a git repository',
      subcommand: `wiki chain ${action}`,
    });

    return null;
  }
};

const resolveShortHead = (runner: CommandRunner, cwd: string): string | null => {
  const result = runner('git', ['rev-parse', 'HEAD'], {cwd});

  if (!stepOk(result)) return null;

  return shortSha((result.stdout ?? '').trim(), cwd);
};

type BranchAwareParse =
  | {branchAware: boolean; ok: true}
  | {message: string; ok: false};

const parseBranchAware = (argv: readonly string[]): BranchAwareParse => {
  let branchAware = false;

  for (const token of argv) {
    if (token === '--branch-aware') {
      branchAware = true;
      continue;
    }

    return {message: `unknown flag: ${token}`, ok: false};
  }

  return {branchAware, ok: true};
};

type CommitParse = {label: string; ok: true} | {message: string; ok: false};

const parseCommitFlags = (argv: readonly string[]): CommitParse => {
  let label: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--label') {
      const value = argv[index + 1];

      if (value === undefined) return {message: '--label requires a value', ok: false};
      label = value;
      index += 1;
      continue;
    }

    return {message: `unknown flag: ${token}`, ok: false};
  }

  if (label === undefined || label.length === 0)
    return {message: '--label is required', ok: false};

  return {label, ok: true};
};

const begin = (argv: readonly string[], options: RunOptions): number => {
  const parsed = parseBranchAware(argv);

  if (!parsed.ok) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.message,
      subcommand: 'wiki chain begin',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const runner = options.runner ?? defaultRunner;
  const repoRoot = resolveRoot(cwd, 'begin');

  if (repoRoot === null) return EXIT_CODES.UNKNOWN_SUBCOMMAND;

  let branch: string;

  try {
    branch = currentBranch(repoRoot, runner);
  } catch (error) {
    process.stderr.write(
      `chain: ${error instanceof Error ? error.message : String(error)}\n`
    );

    return UNEXPECTED_EXIT;
  }

  if (!isProtectedBranch(branch)) {
    process.stdout.write(`chain begin: in-place on ${branch}\n`);

    return EXIT_CODES.OK;
  }

  if (!parsed.branchAware) {
    return refuse(
      'chain begin: refusing to start a wiki chain on main; pass --branch-aware or check out a feature branch'
    );
  }

  const shortHead = resolveShortHead(runner, repoRoot);

  if (shortHead === null) {
    process.stderr.write('chain: could not resolve HEAD\n');

    return UNEXPECTED_EXIT;
  }

  const branchName = `${WIKI_CHAIN_BRANCH_PREFIX}${options.today ?? todayUtc()}-${shortHead}`;
  const args = ['checkout', '-b', branchName];
  const result = runner('git', args, {cwd: repoRoot});

  if (!stepOk(result)) return passthroughFailure(result, 'git', args);

  process.stdout.write(`chain begin: started ${branchName}\n`);

  return EXIT_CODES.OK;
};

const commit = (argv: readonly string[], options: RunOptions): number => {
  const parsed = parseCommitFlags(argv);

  if (!parsed.ok) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.message,
      subcommand: 'wiki chain commit',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const runner = options.runner ?? defaultRunner;
  const repoRoot = resolveRoot(cwd, 'commit');

  if (repoRoot === null) return EXIT_CODES.UNKNOWN_SUBCOMMAND;

  let workingTree: ReturnType<typeof inspectWorkingTree>;

  try {
    workingTree = inspectWorkingTree(repoRoot, runner);
  } catch (error) {
    process.stderr.write(
      `chain: ${error instanceof Error ? error.message : String(error)}\n`
    );

    return UNEXPECTED_EXIT;
  }

  if (workingTree.hasNonWikiChanges) {
    return refuse('chain commit: working tree has non-wiki changes; aborting');
  }

  if (!workingTree.hasWikiChanges) {
    // A skipped stage (e.g. consolidate gated off) leaves nothing to commit.
    // Graceful no-op so the chain does not abort.
    process.stdout.write('chain commit: nothing to commit\n');

    return EXIT_CODES.OK;
  }

  const addArgs = ['add', 'wiki'];
  const addResult = runner('git', addArgs, {cwd: repoRoot});

  if (!stepOk(addResult)) return passthroughFailure(addResult, 'git', addArgs);

  const commitArgs = ['commit', '-m', parsed.label];
  const commitResult = runner('git', commitArgs, {cwd: repoRoot});

  if (!stepOk(commitResult)) {
    // Unstage `wiki` so a failed commit leaves a clean index behind.
    runner('git', ['reset', 'HEAD', '--', 'wiki'], {cwd: repoRoot});

    return passthroughFailure(commitResult, 'git', commitArgs);
  }

  process.stdout.write(`chain commit: ${parsed.label}\n`);

  return EXIT_CODES.OK;
};

const finish = (argv: readonly string[], options: RunOptions): number => {
  const parsed = parseBranchAware(argv);

  if (!parsed.ok) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.message,
      subcommand: 'wiki chain finish',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const runner = options.runner ?? defaultRunner;
  const repoRoot = resolveRoot(cwd, 'finish');

  if (repoRoot === null) return EXIT_CODES.UNKNOWN_SUBCOMMAND;

  let branch: string;

  try {
    branch = currentBranch(repoRoot, runner);
  } catch (error) {
    process.stderr.write(
      `chain: ${error instanceof Error ? error.message : String(error)}\n`
    );

    return UNEXPECTED_EXIT;
  }

  if (!branch.startsWith(WIKI_CHAIN_BRANCH_PREFIX)) {
    // In-place run (begin was a no-op on a feature branch). The stage commits
    // already live on the developer's branch; opening a PR is their call.
    process.stdout.write(
      `chain finish: in-place commits remain on ${branch}; no PR opened\n`
    );

    return EXIT_CODES.OK;
  }

  const base = defaultBranch(repoRoot, runner);
  const countArgs = ['rev-list', '--count', `${base}..HEAD`];
  const countResult = runner('git', countArgs, {cwd: repoRoot});

  if (!stepOk(countResult)) return passthroughFailure(countResult, 'git', countArgs);

  const ahead = Number.parseInt((countResult.stdout ?? '').trim(), 10);

  if (!Number.isNaN(ahead) && ahead === 0) {
    // No commits to land. A clean tree means every stage was a no-op: drop
    // the empty branch and return to base rather than open an empty PR. A
    // dirty tree means sync aborted mid-write (the Step 5b fabrication guard
    // leaves the tree untouched without committing); leave the branch and
    // changes in place for the maintainer to resolve.
    let dirty = true;

    try {
      const tree = inspectWorkingTree(repoRoot, runner);
      dirty = tree.hasWikiChanges || tree.hasNonWikiChanges;
    } catch {
      dirty = true;
    }

    if (dirty) {
      process.stdout.write(
        `chain finish: ${branch} has uncommitted changes and no commits; left in place for review\n`
      );

      return EXIT_CODES.OK;
    }

    const checkoutArgs = ['checkout', base];
    const checkoutResult = runner('git', checkoutArgs, {cwd: repoRoot});

    if (!stepOk(checkoutResult))
      return passthroughFailure(checkoutResult, 'git', checkoutArgs);

    runner('git', ['branch', '-D', branch], {cwd: repoRoot});
    process.stdout.write(
      `chain finish: nothing to land; removed empty branch ${branch}\n`
    );

    return EXIT_CODES.OK;
  }

  const shortHead = resolveShortHead(runner, repoRoot) ?? branch;
  const prTitle = `wiki: maintenance chain through ${shortHead}`;
  const prBody = `Automated /gaia-wiki full-chain landing (sync + consolidate + lint) via \`gaia wiki chain finish\`.`;

  // Remote steps run while still on the chain branch so `gh pr merge` targets
  // its PR. Once `push` succeeds the branch exists on the remote and is left
  // for the maintainer to resolve rather than force-reverted.
  const remoteSequence: Array<{args: string[]; command: string}> = [
    {args: ['push', '-u', 'origin', branch], command: 'git'},
    {
      args: ['pr', 'create', '--title', prTitle, '--body', prBody],
      command: 'gh',
    },
    {
      args: ['pr', 'merge', '--squash', '--auto', '--delete-branch'],
      command: 'gh',
    },
  ];

  for (const step of remoteSequence) {
    const result = runner(step.command, step.args, {cwd: repoRoot});

    if (!stepOk(result)) return passthroughFailure(result, step.command, step.args);
  }

  // Land like any other PR: `--auto` waits for the gate to go green server side,
  // then finalizeMerge polls for the merge and cleans up locally (or defers to
  // the session-start janitor on timeout).
  return finalizeMerge(runner, repoRoot, branch, base, 'chain finish', {
    attempts: options.mergePollAttempts,
    sleep: options.sleep,
  });
};

const ACTIONS: Readonly<
  Partial<Record<string, (argv: readonly string[], options: RunOptions) => number>>
> = {
  begin,
  commit,
  finish,
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  const action = argv[0] as string | undefined;
  const rest = argv.slice(1);

  if (action === undefined || HELP_TOKENS.has(action)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const handler = ACTIONS[action];

  if (handler !== undefined) return handler(rest, options);

  structuredError({
    code: 'unknown_subcommand',
    message: `unknown wiki chain action: ${action}`,
    subcommand: `wiki chain ${action}`,
  });

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};
