/**
 * The one place the CLI spawns `gh` and `git` child processes, shared by every
 * feature folder. Tests intercept by stubbing the exported symbols directly
 * (`vi.mock` or `vi.spyOn` on this module) to verify argv verbatim and supply
 * canned responses.
 *
 * Three shapes, one per caller need:
 * - `runGh` / `runGit`: synchronous, return `{exitCode, stdout, stderr}` and
 *   never throw for a non-zero exit; handlers branch on `exitCode` and emit
 *   structured errors themselves.
 * - `defaultRunner`: a synchronous `CommandRunner` returning the raw
 *   `SpawnSyncReturns`, for modules that inject a runner for tests.
 * - `runGhAsync`: asynchronous via `spawn` (NOT `execSync`), returns a
 *   discriminated `{ok: true, stdout}` / `{ok: false, exitCode, stderr}`
 *   result and supports a kill timeout.
 */
import type {SpawnSyncReturns} from 'node:child_process';
import {spawn, spawnSync} from 'node:child_process';
import {MAX_GIT_BUFFER_BYTES} from './git-buffer.js';

export type CommandRunner = (
  command: string,
  args: readonly string[],
  options: {cwd: string}
) => SpawnSyncReturns<string>;

export type GhFailure = {
  exitCode: number;
  ok: false;
  stderr: string;
  /** Set only when `timeoutMs` elapsed and the child was killed. */
  timedOut?: true;
};

export type GhOptions = {
  args: readonly string[];
  cwd?: string;
  env?: NodeJS.ProcessEnv;
  /** Kill the child and settle as a timed-out failure after this many ms. */
  timeoutMs?: number;
};

export type GhResult = GhFailure | GhSuccess;

export type GhSuccess = {
  ok: true;
  stdout: string;
};

export type ProcessResult = {
  exitCode: number;
  stderr: string;
  stdout: string;
};

type RunOptions = {
  cwd?: string;
  env?: NodeJS.ProcessEnv;
};

/**
 * Callers such as `collectCommits` ask git for every subject *and body* since
 * the last tag, so the output grows with the distance from that tag and passes
 * Node's 1 MiB `spawnSync` default well before a release is due, failing the
 * command closed with ENOBUFS. Bumping is runbook step 2 and the changelog is
 * step 5, so an unbounded runner here blocks the release three steps before
 * `release changelog` is ever reached.
 */
export const defaultRunner: CommandRunner = (command, args, options) =>
  spawnSync(command, args as string[], {
    cwd: options.cwd,
    encoding: 'utf8',
    maxBuffer: MAX_GIT_BUFFER_BYTES,
    stdio: ['ignore', 'pipe', 'pipe'],
  });

const run = (
  command: string,
  args: readonly string[],
  options: RunOptions = {}
): ProcessResult => {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? process.cwd(),
    encoding: 'utf8',
    env: options.env ?? process.env,
    // Node's 1 MiB default kills the child on overflow, which reads here as a
    // plain exit 1. `harden-tally`'s 90-day `gh pr list --json comments`
    // window runs past 1 MiB, so the default reads it as a gh failure.
    maxBuffer: MAX_GIT_BUFFER_BYTES,
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  // spawnSync sets `status: null` on signal-terminated children; treat
  // that as exit code 1 so callers don't accidentally see it as success.
  const exitCode = result.status ?? 1;

  // @types/node claims stdout/stderr are always `string` once an encoding
  // is given, but Node can still leave them `null` if the child never
  // spawned (e.g. ENOENT). Narrow at this read site rather than trusting
  // the (incomplete) declared type.
  const stdout = result.stdout as null | string;
  const stderr = result.stderr as null | string;

  return {
    exitCode,
    stderr: stderr ?? '',
    stdout: stdout ?? '',
  };
};

export const runGh = (
  args: readonly string[],
  options: RunOptions = {}
): ProcessResult => run('gh', args, options);

export const runGit = (
  args: readonly string[],
  options: RunOptions = {}
): ProcessResult => run('git', args, options);

export const runGhAsync = async (options: GhOptions): Promise<GhResult> =>
  new Promise((resolve) => {
    const child = spawn('gh', [...options.args], {
      cwd: options.cwd ?? process.cwd(),
      env: options.env ?? process.env,
      stdio: ['pipe', 'pipe', 'pipe'],
    });

    let stdoutBuf = '';
    let stderrBuf = '';
    let settled = false;
    let timer: NodeJS.Timeout | undefined;

    const settle = (result: GhResult): void => {
      if (settled) return;
      settled = true;
      if (timer !== undefined) clearTimeout(timer);
      resolve(result);
    };

    if (options.timeoutMs !== undefined) {
      timer = setTimeout(() => {
        child.kill('SIGKILL');
        settle({exitCode: -1, ok: false, stderr: '', timedOut: true});
      }, options.timeoutMs);
    }

    child.stdout.on('data', (chunk: Buffer | string) => {
      stdoutBuf += typeof chunk === 'string' ? chunk : chunk.toString('utf8');
    });

    child.stderr.on('data', (chunk: Buffer | string) => {
      stderrBuf += typeof chunk === 'string' ? chunk : chunk.toString('utf8');
    });

    child.on('error', (error: Error) => {
      // Wrapper-internal failure (gh not on PATH, ENOENT, etc).
      settle({
        exitCode: -1,
        ok: false,
        stderr: error.message,
      });
    });

    child.on('close', (code: null | number) => {
      // Not hoisted into a `const exitCode = code ?? 1` local: Node passes
      // `null` (a signal-terminated child), not `undefined`, so a default
      // parameter wouldn't substitute for it; the plain `??` reassignment
      // shape is what unicorn/prefer-default-parameters flags, so this
      // stays inline instead.
      if ((code ?? 1) === 0) {
        settle({ok: true, stdout: stdoutBuf});

        return;
      }

      settle({exitCode: code ?? 1, ok: false, stderr: stderrBuf});
    });

    child.stdin.end();
  });
