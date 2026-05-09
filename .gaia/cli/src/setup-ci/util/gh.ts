/**
 * Thin wrapper around `gh` invocations used by `gaia setup-ci`.
 *
 * Spawns child processes via `child_process.spawn` (NOT `execSync`) so
 * stdin can be piped into `gh secret set`. Returns a discriminated
 * `{ ok: true, stdout }` / `{ ok: false, exitCode, stderr }` shape.
 *
 * Critical security contract for `set-secret`:
 *
 * - The wrapper NEVER appends `stdin` content to `args`.
 * - The wrapper NEVER logs or echoes `stdin` content.
 * - On wrapper-internal errors (e.g. `gh` not on PATH), the wrapper
 *   returns a structured failure WITHOUT including `stdin` content
 *   in any error field.
 *
 * Tests assert these guarantees by inspecting a sandbox `gh` shim's
 * recorded argv + stdin files.
 */
import {spawn} from 'node:child_process';

export type GhSuccess = {
  ok: true;
  stdout: string;
};

export type GhFailure = {
  exitCode: number;
  ok: false;
  stderr: string;
};

export type GhResult = GhFailure | GhSuccess;

export type GhOptions = {
  args: readonly string[];
  cwd?: string;
  env?: NodeJS.ProcessEnv;
  stdin?: Buffer | string;
};

export const runGh = (options: GhOptions): Promise<GhResult> => {
  return new Promise((resolve) => {
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
      // Wrapper-internal failure (gh not on PATH, ENOENT, etc). The
      // stdin payload is intentionally NOT included in the surfaced
      // stderr — secret callers depend on this guarantee.
      settle({
        exitCode: -1,
        ok: false,
        stderr: error.message,
      });
    });

    child.on('close', (code: null | number) => {
      const exitCode = code ?? 1;

      if (exitCode === 0) {
        settle({ok: true, stdout: stdoutBuf});

        return;
      }

      settle({exitCode, ok: false, stderr: stderrBuf});
    });

    if (options.stdin !== undefined) {
      child.stdin.write(options.stdin);
    }
    child.stdin.end();
  });
};
