/**
 * `gaia-maintainer release preflight` handler.
 *
 * Step 1 + Step 2 of the maintainer release runbook codified as exit codes:
 *
 *   1. Branch state check: must be on `main` (or maintainer-designated
 *      release branch) with a clean working tree.
 *   2. Wiki state check: `gaia wiki state --json`'s `commits_ahead === 0`.
 *
 * Stdout: nothing on success.
 * Stderr: clear refusal on each failure.
 * Exit: 0 / 1 / 2.
 */
import {spawnSync} from 'node:child_process';
import type {SpawnSyncReturns} from 'node:child_process';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {run as runWikiState} from '../wiki/state.js';

const HELP_TEXT = `Usage: gaia-maintainer release preflight [--branch <name>]

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

type FlagParseFailure = {
  message: string;
  ok: false;
};

type FlagParseResult = FlagParseFailure | FlagParseSuccess;

type FlagParseSuccess = {
  flags: Flags;
  ok: true;
};

type Flags = {
  allowedBranch: string;
};

const takeValue = (
  argv: readonly string[],
  index: number,
  flag: string
): {message: string; ok: false} | {ok: true; value: string} => {
  // `.at()` (unlike bracket indexing) types its result `string | undefined`,
  // which honestly reflects that `index` can run past the end of argv.
  const value = argv.at(index);

  if (value === undefined)
    return {message: `${flag} requires a value`, ok: false};

  return {ok: true, value};
};

const parseFlags = (argv: readonly string[]): FlagParseResult => {
  let allowedBranch = DEFAULT_BRANCH;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--branch') {
      const taken = takeValue(argv, index + 1, '--branch');

      if (!taken.ok) return taken;
      allowedBranch = taken.value;
      index += 1;
    } else {
      return {message: `unknown flag: ${token}`, ok: false};
    }
  }

  return {flags: {allowedBranch}, ok: true};
};

const expectSuccess = (
  result: SpawnSyncReturns<string>,
  command: string,
  args: readonly string[]
): string => {
  if (result.error !== undefined) {
    throw new Error(
      `${command} ${args.join(' ')} failed: ${result.error.message}`
    );
  }

  if ((result.status ?? -1) !== 0) {
    const stderr = result.stderr.trim();

    throw new Error(
      `${command} ${args.join(' ')} exited ${result.status ?? -1}: ${stderr}`
    );
  }

  return result.stdout;
};

const refuse = (message: string): number => {
  process.stderr.write(`${message}\n`);

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};

type WikiState = {
  commits_ahead: number;
  reachable: boolean;
  state_sha: string;
  suggested_base: string;
};
type WikiStateProbe = (cwd: string) => null | WikiState;

const runWikiStateJson: WikiStateProbe = (cwd) => {
  // Capture stdout from the wiki state subcommand via an injected sink;
  // `wiki/state.ts` writes through `options.write`, so the global
  // `process.stdout` is never mutated.
  const chunks: string[] = [];
  const exit = runWikiState(['--json'], {
    cwd,
    write: (chunk) => {
      chunks.push(chunk);
    },
  });

  if (exit !== EXIT_CODES.OK) return null;
  const raw = chunks.join('').trim();

  try {
    const parsed = JSON.parse(raw) as Record<string, unknown>;
    const {
      commits_ahead: commitsAhead,
      reachable,
      state_sha: stateSha,
      suggested_base: suggestedBase,
    } = parsed;

    if (typeof commitsAhead !== 'number') return null;

    return {
      commits_ahead: commitsAhead,
      // Default reachable to true on a malformed payload so the orphaned-state
      // recovery never fires off bad input; the gate falls back to today's
      // `commits_ahead` reading.
      reachable: typeof reachable === 'boolean' ? reachable : true,
      state_sha: typeof stateSha === 'string' ? stateSha : '',
      suggested_base: typeof suggestedBase === 'string' ? suggestedBase : '',
    };
  } catch {
    return null;
  }
};

/**
 * Resolve a (possibly abbreviated) SHA to a full commit SHA. `''` when `sha`
 * is empty or git can't verify it.
 *
 * `gaia wiki state --json` reports both `state_sha` and `suggested_base`
 * abbreviated; resolving to a full SHA before any range query keeps `git log` /
 * `git rev-list` from having to disambiguate a short prefix (which they can fail
 * to do in large repos).
 */
const resolveCommit = (
  runner: CommandRunner,
  cwd: string,
  sha: string
): string => {
  if (sha === '') return '';
  const resolved = runner('git', ['rev-parse', '--verify', `${sha}^{commit}`], {
    cwd,
  });

  if (resolved.error !== undefined || (resolved.status ?? -1) !== 0) return '';

  return resolved.stdout.trim();
};

/**
 * Subjects of the commits in `<base>..HEAD`, newest first. `null` if the range
 * can't be read (e.g. `base` is empty, ambiguous, or git fails); callers treat
 * `null` as "can't prove the drift is benign" and refuse.
 */
const readDriftSubjects = (
  runner: CommandRunner,
  cwd: string,
  base: string
): null | string[] => {
  const fullSha = resolveCommit(runner, cwd, base);

  if (fullSha === '') return null;
  const result = runner('git', ['log', '--format=%s', `${fullSha}..HEAD`], {
    cwd,
  });

  if (result.error !== undefined || (result.status ?? -1) !== 0) return null;

  return result.stdout.split('\n').flatMap((line) => {
    const trimmed = line.trim();

    return trimmed.length > 0 ? [trimmed] : [];
  });
};

/**
 * Count the commits in `<base>..HEAD`. `null` if `base` can't be resolved or
 * `git rev-list` fails. Used to recover the drift count on the orphaned-state
 * path, where `gaia wiki state` reports a hardcoded `commits_ahead:0`.
 */
const countDriftCommits = (
  runner: CommandRunner,
  cwd: string,
  base: string
): null | number => {
  const fullSha = resolveCommit(runner, cwd, base);

  if (fullSha === '') return null;
  const result = runner('git', ['rev-list', '--count', `${fullSha}..HEAD`], {
    cwd,
  });

  if (result.error !== undefined || (result.status ?? -1) !== 0) return null;
  const parsed = Number.parseInt(result.stdout.trim(), 10);

  return Number.isInteger(parsed) ? parsed : null;
};

type RunOptions = {
  cwd?: string;
  runner?: CommandRunner;
  /** Override the wiki-state probe for tests. */
  wikiStateProbe?: WikiStateProbe;
};

const tryReadBranchState = (
  runner: CommandRunner,
  cwd: string
): null | {branch: string; status: string} => {
  try {
    const branch = expectSuccess(
      runner('git', ['rev-parse', '--abbrev-ref', 'HEAD'], {cwd}),
      'git',
      ['rev-parse', '--abbrev-ref', 'HEAD']
    ).trim();
    const status = expectSuccess(
      runner('git', ['status', '--porcelain=v1', '-uall'], {cwd}),
      'git',
      ['status', '--porcelain=v1', '-uall']
    );

    return {branch, status};
  } catch (error) {
    process.stderr.write(
      `preflight: ${error instanceof Error ? error.message : String(error)}\n`
    );

    return null;
  }
};

type DriftWindow = {base: string; count: number};

/**
 * Resolve the effective drift window. On the reachable path the wiki-state
 * JSON's `commits_ahead`/`state_sha` are authoritative. On the orphaned path
 * (`reachable:false`, the normal post-squash-merge condition) the JSON
 * hardcodes `commits_ahead:0`, blind to any un-evaluated window; recover the
 * window from `suggested_base..HEAD`, the reachable baseline `gaia wiki state`
 * reports for exactly this case. `suggested_base` is `''` on the reachable
 * path, so the recovery branch is inert there and behavior is unchanged.
 * `null` when the recovery read fails: a git failure counting the recovered
 * window can't prove the wiki is current.
 */
const resolveDriftWindow = (
  runner: CommandRunner,
  cwd: string,
  wikiState: WikiState
): DriftWindow | null => {
  if (wikiState.reachable || wikiState.suggested_base === '') {
    return {base: wikiState.state_sha, count: wikiState.commits_ahead};
  }

  const recovered = countDriftCommits(runner, cwd, wikiState.suggested_base);

  if (recovered === null) return null;

  // Inspect `suggested_base..HEAD`, NOT the orphaned `state_sha`, whose
  // `..HEAD` range is topologically unreliable after a squash rewrites the SHA.
  return {base: wikiState.suggested_base, count: recovered};
};

/**
 * True when every commit in the drift window is a wiki-sync squash artifact.
 * Documented bypass (wiki/concepts/Release Workflow.md): a PR squash-merge
 * rewrites the commit SHA, so `/gaia-wiki sync` → merge leaves the state
 * pointer one commit behind even when the wiki content is current. The
 * `wiki:`-subject prefix is the same marker `gaia wiki commit-classify` uses
 * to flag self-referential sync commits. Substantive (non-`wiki:`) drift is
 * never benign; the wiki is genuinely stale.
 */
const isDriftBenign = (
  runner: CommandRunner,
  cwd: string,
  driftBase: string
): boolean => {
  const driftSubjects = readDriftSubjects(runner, cwd, driftBase);

  return (
    driftSubjects !== null &&
    // Guards the vacuous-truth case: zero subjects with a nonzero drift count
    // means the range count disagrees with `git log`, a broken state, not a
    // benign one.
    driftSubjects.length > 0 &&
    driftSubjects.every((subject) => subject.startsWith('wiki:'))
  );
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
      subcommand: 'release preflight',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const runner = options.runner ?? defaultRunner;
  const wikiStateProbe = options.wikiStateProbe ?? runWikiStateJson;

  const branchState = tryReadBranchState(runner, cwd);

  if (branchState === null) return UNEXPECTED_EXIT;

  if (branchState.branch !== parsed.flags.allowedBranch) {
    return refuse(
      `preflight: must be on ${parsed.flags.allowedBranch} (current: ${branchState.branch})`
    );
  }

  if (branchState.status.trim().length > 0) {
    return refuse('preflight: working tree is dirty; commit or stash first');
  }

  const wikiState = wikiStateProbe(cwd);

  if (wikiState === null) {
    return refuse(
      'preflight: failed to read wiki state via `gaia wiki state --json`'
    );
  }

  const driftWindow = resolveDriftWindow(runner, cwd, wikiState);

  if (driftWindow === null) {
    return refuse(
      `preflight: cannot determine wiki drift from recovery base ${wikiState.suggested_base}; run /gaia-wiki sync first`
    );
  }

  if (driftWindow.count !== 0) {
    if (!isDriftBenign(runner, cwd, driftWindow.base)) {
      return refuse(
        `preflight: wiki is ${driftWindow.count} commits behind HEAD; run /gaia-wiki sync first`
      );
    }

    process.stderr.write(
      `preflight: wiki drift is ${driftWindow.count} wiki-sync squash artifact(s); proceeding (content current)\n`
    );
  }

  return EXIT_CODES.OK;
};
