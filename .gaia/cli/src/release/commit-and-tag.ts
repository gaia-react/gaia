/**
 * `gaia-maintainer release commit-and-tag` handler.
 *
 * Codifies Step 11 and Step 13 of the maintainer release runbook:
 *
 *   --commit   Stage the release-related files, commit with the message
 *              `chore(release): vX.Y.Z`, then amend `wiki/.state.json`
 *              so its `last_evaluated_sha` matches the release commit's
 *              own SHA. Result: the release commit's tree contains a
 *              state file that says "wiki is in sync at this release."
 *
 *   --tag      Tag HEAD as `vX.Y.Z` (annotated, message `Release vX.Y.Z`)
 *              and push the tag to `origin`. Run after the release PR
 *              merges and `main` is fast-forwarded.
 *
 * One mode per invocation. The slash command runs `--commit` on the
 * release branch (Step 11) and `--tag` on `main` (Step 13).
 *
 * The version is read from `package.json`. Stdout is a one-line summary
 * per mode; stderr explains every refusal.
 */
import {type SpawnSyncReturns, spawnSync} from 'node:child_process';
import {existsSync, readFileSync} from 'node:fs';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';

const HELP_TEXT = `Usage: gaia-maintainer release commit-and-tag (--commit | --tag) [--no-push]

  --commit      Stage release-related files and commit, then amend
                wiki/.state.json with the new commit SHA.
  --tag         Tag HEAD as vX.Y.Z and push the tag to origin.
  --no-push     With --tag: skip the tag push step.

  Exit codes:
    0  success
    1  user-correctable error
    2  unexpected (git failure)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const UNEXPECTED_EXIT = 2;

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

type Mode = 'commit' | 'tag';

type Flags = {
  mode: Mode;
  noPush: boolean;
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

const parseFlags = (argv: readonly string[]): FlagParseResult => {
  let mode: Mode | undefined;
  let noPush = false;

  for (const token of argv) {
    if (token === '--commit') {
      if (mode !== undefined) {
        return {message: '--commit and --tag are mutually exclusive', ok: false};
      }
      mode = 'commit';
      continue;
    }

    if (token === '--tag') {
      if (mode !== undefined) {
        return {message: '--commit and --tag are mutually exclusive', ok: false};
      }
      mode = 'tag';
      continue;
    }

    if (token === '--no-push') {
      noPush = true;
      continue;
    }

    return {message: `unknown flag: ${token}`, ok: false};
  }

  if (mode === undefined) {
    return {message: 'one of --commit or --tag is required', ok: false};
  }

  return {flags: {mode, noPush}, ok: true};
};

type PackageJsonShape = {
  version?: unknown;
};

const readVersion = (cwd: string): string => {
  const target = path.join(cwd, 'package.json');

  if (!existsSync(target)) {
    throw new Error('package.json not found at repo root');
  }
  const parsed = JSON.parse(readFileSync(target, 'utf8')) as PackageJsonShape;

  if (typeof parsed.version !== 'string') {
    throw new Error('package.json has no string "version"');
  }

  return parsed.version;
};

type Step = {
  args: readonly string[];
  command: string;
  /** When `true`, a non-zero exit is acceptable (fall through). */
  allowFailure?: boolean;
};

const stepSucceeded = (result: SpawnSyncReturns<string>): boolean =>
  result.error === undefined && (result.status ?? -1) === 0;

const passthroughFailure = (
  result: SpawnSyncReturns<string>,
  step: Step
): number => {
  const stderr = (result.stderr ?? '').trim();
  const errorPart = result.error !== undefined ? ` (${result.error.message})` : '';
  const status = result.status ?? -1;
  process.stderr.write(
    `commit-and-tag: ${step.command} ${step.args.join(' ')} exited ${status}${errorPart}\n`
  );

  if (stderr.length > 0) {
    process.stderr.write(`${stderr}\n`);
  }

  return UNEXPECTED_EXIT;
};

const RELEASE_FILES = [
  'package.json',
  '.gaia/VERSION',
  '.gaia/manifest.json',
  'CHANGELOG.md',
  'wiki/hot.md',
  'wiki/log.md',
];

type CommitContext = {
  cwd: string;
  runner: CommandRunner;
  version: string;
};

/**
 * Update `wiki/.state.json` to point at `sha` (preserving any sibling
 * keys + key order, matching `gaia wiki state-bump`'s contract).
 */
const writeStateSha = (cwd: string, sha: string): void => {
  const target = path.join(cwd, 'wiki', '.state.json');

  if (!existsSync(target)) return;
  const raw = readFileSync(target, 'utf8');
  let parsed: Record<string, unknown>;

  try {
    parsed = JSON.parse(raw) as Record<string, unknown>;
  } catch {
    throw new Error('wiki/.state.json is not valid JSON');
  }

  const next: Record<string, unknown> = {};
  let saw = false;

  for (const key of Object.keys(parsed)) {
    if (key === 'last_evaluated_sha') {
      next[key] = sha;
      saw = true;
    } else if (key === 'last_evaluated_at') {
      next[key] = new Date().toISOString();
    } else {
      next[key] = parsed[key];
    }
  }

  if (!saw) next.last_evaluated_sha = sha;
  const trailingNewline = raw.endsWith('\n') ? '\n' : '';
  atomicWriteFileSync(target, `${JSON.stringify(next, null, 2)}${trailingNewline}`);
};

const runCommitMode = (ctx: CommitContext): number => {
  // 1. Stage the release-related files (only those that exist).
  const presentFiles = RELEASE_FILES.filter((file) =>
    existsSync(path.join(ctx.cwd, file))
  );

  if (presentFiles.length === 0) {
    process.stderr.write('commit-and-tag: no release files present to stage\n');

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const message = `chore(release): v${ctx.version}`;
  const sequence: Step[] = [
    {args: ['add', ...presentFiles], command: 'git'},
    {args: ['commit', '-m', message], command: 'git'},
  ];

  for (const step of sequence) {
    const result = ctx.runner(step.command, step.args, {cwd: ctx.cwd});

    if (!stepSucceeded(result)) return passthroughFailure(result, step);
  }

  // 2. Capture the new SHA, update wiki/.state.json, amend.
  const headResult = ctx.runner('git', ['rev-parse', 'HEAD'], {cwd: ctx.cwd});

  if (!stepSucceeded(headResult)) {
    return passthroughFailure(headResult, {
      args: ['rev-parse', 'HEAD'],
      command: 'git',
    });
  }
  const newSha = (headResult.stdout ?? '').trim();

  try {
    writeStateSha(ctx.cwd, newSha);
  } catch (error) {
    process.stderr.write(
      `commit-and-tag: ${error instanceof Error ? error.message : String(error)}\n`
    );

    return UNEXPECTED_EXIT;
  }

  // Stage the state file (if it exists) and amend.
  const statePath = path.join(ctx.cwd, 'wiki', '.state.json');

  if (existsSync(statePath)) {
    const amendSequence: Step[] = [
      {args: ['add', 'wiki/.state.json'], command: 'git'},
      {args: ['commit', '--amend', '--no-edit'], command: 'git'},
    ];

    for (const step of amendSequence) {
      const result = ctx.runner(step.command, step.args, {cwd: ctx.cwd});

      if (!stepSucceeded(result)) {
        // The release commit already landed but the state-SHA amend failed,
        // leaving a partial release commit. Undo it (`reset --soft` keeps
        // the staged files) so the maintainer can retry from a clean state
        // instead of carrying a half-finished commit forward.
        const rollback = ctx.runner('git', ['reset', '--soft', 'HEAD~1'], {
          cwd: ctx.cwd,
        });

        if (!stepSucceeded(rollback)) {
          process.stderr.write(
            'commit-and-tag: amend failed AND rollback (git reset --soft HEAD~1) failed; '
              + 'the release commit is left in place — undo it manually before retrying\n'
          );
        } else {
          process.stderr.write(
            'commit-and-tag: amend failed; rolled back the release commit '
              + '(git reset --soft HEAD~1) — fix the cause and retry\n'
          );
        }

        return passthroughFailure(result, step);
      }
    }
  }

  process.stdout.write(
    `commit-and-tag: committed v${ctx.version} (${newSha.slice(0, 7)})\n`
  );

  return EXIT_CODES.OK;
};

type TagContext = {
  cwd: string;
  noPush: boolean;
  runner: CommandRunner;
  version: string;
};

const runTagMode = (ctx: TagContext): number => {
  const tagName = `v${ctx.version}`;
  const message = `Release v${ctx.version}`;

  const tagStep: Step = {
    args: ['tag', '-a', tagName, '-m', message],
    command: 'git',
  };
  const tagResult = ctx.runner(tagStep.command, tagStep.args, {cwd: ctx.cwd});

  if (!stepSucceeded(tagResult)) return passthroughFailure(tagResult, tagStep);

  if (!ctx.noPush) {
    const pushStep: Step = {
      args: ['push', 'origin', tagName],
      command: 'git',
    };
    const pushResult = ctx.runner(pushStep.command, pushStep.args, {
      cwd: ctx.cwd,
    });

    if (!stepSucceeded(pushResult)) {
      // The tag was created locally but never reached origin. Delete the
      // local tag so a retry re-tags cleanly instead of failing on an
      // already-existing tag.
      const rollback = ctx.runner('git', ['tag', '-d', tagName], {
        cwd: ctx.cwd,
      });

      if (!stepSucceeded(rollback)) {
        process.stderr.write(
          `commit-and-tag: push failed AND rollback (git tag -d ${tagName}) failed; `
            + `the local tag ${tagName} is left in place — delete it manually before retrying\n`
        );
      } else {
        process.stderr.write(
          `commit-and-tag: push failed; deleted the local tag ${tagName} `
            + '— fix the cause and retry\n'
        );
      }

      return passthroughFailure(pushResult, pushStep);
    }
  }

  process.stdout.write(
    `commit-and-tag: tagged ${tagName}${ctx.noPush ? ' (push skipped)' : ' and pushed'}\n`
  );

  return EXIT_CODES.OK;
};

type RunOptions = {
  cwd?: string;
  runner?: CommandRunner;
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
      subcommand: 'release commit-and-tag',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const runner = options.runner ?? defaultRunner;

  let version: string;

  try {
    version = readVersion(cwd);
  } catch (error) {
    structuredError({
      code: 'package_json_invalid',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'release commit-and-tag',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (parsed.flags.mode === 'commit') {
    return runCommitMode({cwd, runner, version});
  }

  return runTagMode({cwd, noPush: parsed.flags.noPush, runner, version});
};
