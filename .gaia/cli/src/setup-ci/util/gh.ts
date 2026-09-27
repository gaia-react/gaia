/**
 * Thin wrapper around `gh` invocations used by `gaia setup-ci`.
 *
 * Spawns child processes via `child_process.spawn` (NOT `execSync`).
 * Returns a discriminated `{ ok: true, stdout }` /
 * `{ ok: false, exitCode, stderr }` shape.
 */
import {spawn} from 'node:child_process';

export type GhFailure = {
  exitCode: number;
  ok: false;
  stderr: string;
};

export type GhOptions = {
  args: readonly string[];
  cwd?: string;
  env?: NodeJS.ProcessEnv;
};

export type GhResult = GhFailure | GhSuccess;

export type GhSuccess = {
  ok: true;
  stdout: string;
};

export const runGh = async (options: GhOptions): Promise<GhResult> =>
  new Promise((resolve) => {
    const child = spawn('gh', [...options.args], {
      cwd: options.cwd ?? process.cwd(),
      env: options.env ?? process.env,
      stdio: ['pipe', 'pipe', 'pipe'],
    });

    let stdoutBuf = '';
    let stderrBuf = '';
    let settled = false;

    const settle = (result: GhResult): void => {
      if (settled) return;
      settled = true;
      resolve(result);
    };

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
