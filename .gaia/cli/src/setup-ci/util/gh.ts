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
      // stderr; secret callers depend on this guarantee.
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

    // A child that exits before draining stdin leaves the pipe closed;
    // a subsequent write/end then emits EPIPE on the stream. Without an
    // `error` listener that EPIPE becomes an unhandled stream error and
    // crashes the process. The child's exit is already captured by the
    // `close` handler above, so a broken stdin pipe is benign here.
    child.stdin.on('error', () => {
      // Intentionally swallowed; `close` carries the real outcome.
    });

    if (options.stdin !== undefined) {
      // `end(payload)` writes then closes in one call; respecting
      // backpressure is unnecessary because we are done after this.
      child.stdin.end(options.stdin);
    } else {
      child.stdin.end();
    }
  });
};
