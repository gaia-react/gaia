/**
 * Shell-out helpers for `gh` and `git` invocations from the `gaia ci`
 * subcommand family.
 *
 * The two functions are the *only* points the rest of the `ci/` tree
 * spawns external processes through. Tests intercept by stubbing the
 * exported symbols (the fixture in `.gaia/cli/test-fixtures/ci-shape/`
 * mocks `runGh` and `runGit` to verify argv verbatim and supply
 * canned responses).
 *
 * Both helpers are synchronous (mirroring `wiki/util/git.ts`) and
 * return a small `{exitCode, stdout, stderr}` shape. We never throw
 * for non-zero exit codes; handlers branch on `exitCode` and emit
 * structured errors themselves.
 */
import {spawnSync} from 'node:child_process';

export type ProcessResult = {
  exitCode: number;
  stderr: string;
  stdout: string;
};

type RunOptions = {
  cwd?: string;
  env?: NodeJS.ProcessEnv;
};

const run = (
  command: string,
  args: readonly string[],
  options: RunOptions = {}
): ProcessResult => {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? process.cwd(),
    encoding: 'utf8',
    env: options.env ?? process.env,
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
