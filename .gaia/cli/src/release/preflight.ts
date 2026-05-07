/**
 * `gaia release preflight` handler.
 *
 * Step 1 + Step 2 of the maintainer release runbook codified as exit codes:
 *
 *   1. Branch state check — must be on `main` (or maintainer-designated
 *      release branch) with a clean working tree.
 *   2. Wiki state check — `gaia wiki state --json`'s `commits_ahead === 0`.
 *
 * Stdout: nothing on success.
 * Stderr: clear refusal on each failure.
 * Exit: 0 / 1 / 2.
 */
import {type SpawnSyncReturns, spawnSync} from 'node:child_process';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {run as runWikiState} from '../wiki/state.js';

const HELP_TEXT = `Usage: gaia release preflight [--branch <name>]

  Verify branch state, working tree, and wiki sync before cutting a release.

  Flags:
    --branch <name>  Allowed release branch (default: main).

  Exit codes:
    0  preflight passed
    1  user-correctable refusal (wrong branch, dirty tree, wiki drift)
    2  unexpected (git failure)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const UNEXPECTED_EXIT = 2;
const DEFAULT_BRANCH = 'main';

export type CommandRunner = (
  command: string,
  args: readonly string[],
  options: {cwd: string}
) => SpawnSyncReturns<string>;

export const defaultRunner: CommandRunner = (command, args, options) =>
  spawnSync(command, args as string[], {
    cwd: options.cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });

type Flags = {
  allowedBranch: string;
};

type FlagParseSuccess = {
  flags: Flags;
  ok: true;
};

type FlagParseFailure = {
  message: string;
  ok: false;
};

type FlagParseResult = FlagParseFailure | FlagParseSuccess;

const takeValue = (
  argv: readonly string[],
  index: number,
  flag: string
): {message: string; ok: false} | {ok: true; value: string} => {
  const value = argv[index];

  if (value === undefined) return {message: `${flag} requires a value`, ok: false};

  return {ok: true, value};
};

const parseFlags = (argv: readonly string[]): FlagParseResult => {
  let allowedBranch = DEFAULT_BRANCH;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string;

    if (token === '--branch') {
      const taken = takeValue(argv, index + 1, '--branch');

      if (!taken.ok) return taken;
      allowedBranch = taken.value;
      index += 1;
      continue;
    }

    return {message: `unknown flag: ${token}`, ok: false};
  }

  return {flags: {allowedBranch}, ok: true};
};

const expectSuccess = (
  result: SpawnSyncReturns<string>,
  command: string,
  args: readonly string[]
): string => {
  if (result.error !== undefined) {
    throw new Error(`${command} ${args.join(' ')} failed: ${result.error.message}`);
  }

  if ((result.status ?? -1) !== 0) {
    const stderr = (result.stderr ?? '').trim();
    throw new Error(
      `${command} ${args.join(' ')} exited ${result.status ?? -1}: ${stderr}`
    );
  }

  return result.stdout ?? '';
};

const refuse = (message: string): number => {
  process.stderr.write(`${message}\n`);

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};

type WikiStateProbe = (cwd: string) => {commits_ahead: number} | null;

const runWikiStateJson: WikiStateProbe = (cwd) => {
  // Capture stdout from the wiki state subcommand by replacing
  // process.stdout.write for the duration of the call, then parse JSON.
  const chunks: string[] = [];
  const originalWrite = process.stdout.write.bind(process.stdout);
  // The handler is synchronous; restoration is bounded.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- runtime patch
  (process.stdout as any).write = (chunk: unknown): boolean => {
    chunks.push(typeof chunk === 'string' ? chunk : String(chunk));

    return true;
  };

  let exit: number;

  try {
    exit = runWikiState(['--json'], {cwd});
  } finally {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any -- runtime patch
    (process.stdout as any).write = originalWrite;
  }

  if (exit !== EXIT_CODES.OK) return null;
  const raw = chunks.join('').trim();

  try {
    const parsed = JSON.parse(raw) as Record<string, unknown>;
    const commitsAhead = parsed.commits_ahead;

    if (typeof commitsAhead !== 'number') return null;

    return {commits_ahead: commitsAhead};
  } catch {
    return null;
  }
};

type RunOptions = {
  cwd?: string;
  runner?: CommandRunner;
  /** Override the wiki-state probe for tests. */
  wikiStateProbe?: WikiStateProbe;
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
      subcommand: 'release preflight',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const runner = options.runner ?? defaultRunner;
  const wikiStateProbe = options.wikiStateProbe ?? runWikiStateJson;

  let branch: string;
  let status: string;

  try {
    branch = expectSuccess(
      runner('git', ['rev-parse', '--abbrev-ref', 'HEAD'], {cwd}),
      'git',
      ['rev-parse', '--abbrev-ref', 'HEAD']
    ).trim();
    status = expectSuccess(
      runner('git', ['status', '--porcelain=v1', '-uall'], {cwd}),
      'git',
      ['status', '--porcelain=v1', '-uall']
    );
  } catch (error) {
    process.stderr.write(
      `preflight: ${error instanceof Error ? error.message : String(error)}\n`
    );

    return UNEXPECTED_EXIT;
  }

  if (branch !== parsed.flags.allowedBranch) {
    return refuse(
      `preflight: must be on ${parsed.flags.allowedBranch} (current: ${branch})`
    );
  }

  if (status.trim().length > 0) {
    return refuse('preflight: working tree is dirty; commit or stash first');
  }

  const wikiState = wikiStateProbe(cwd);

  if (wikiState === null) {
    return refuse('preflight: failed to read wiki state via `gaia wiki state --json`');
  }

  if (wikiState.commits_ahead !== 0) {
    return refuse(
      `preflight: wiki is ${wikiState.commits_ahead} commits behind HEAD; run /wiki-sync first`
    );
  }

  return EXIT_CODES.OK;
};
