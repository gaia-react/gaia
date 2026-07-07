/**
 * `gaia telemetry parse-stdin`: read the PostToolUse `Task` hook input JSON
 * from stdin, extract the structured-trailer YAML block, and dispatch one or
 * more `gaia telemetry emit` invocations against `handleEmit` directly (no
 * sub-process spawn).
 *
 * Always exits 0; telemetry must never block the user's flow. Emit-level
 * failures are logged best-effort to `gaia-telemetry-hook.log` under the OS
 * temp directory and swallowed.
 *
 * Replaces the awk-based YAML parser that previously lived in
 * `.claude/hooks/telemetry-task-postuse.sh`. The shell hook is now a thin
 * pipe to this subcommand.
 */
import {appendFileSync} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {handleEmit} from './emit.js';
import {parseTrailer} from './parse-trailer.js';

// `os.tmpdir()` rather than a hardcoded `/tmp/...` literal: on macOS it
// resolves to a per-user directory under `/var/folders/...`, not the
// world-writable `/tmp`.
const LOG_PATH = path.join(os.tmpdir(), 'gaia-telemetry-hook.log');

const readStdin = async (): Promise<string> => {
  const chunks: Buffer[] = [];

  for await (const chunk of process.stdin) {
    chunks.push(typeof chunk === 'string' ? Buffer.from(chunk) : chunk);
  }

  return Buffer.concat(chunks).toString('utf8');
};

const logFailure = (message: string): void => {
  try {
    const isoNow = new Date().toISOString();
    appendFileSync(LOG_PATH, `[${isoNow}] ${message}\n`);
  } catch {
    // Logging is best-effort; never throw from the hook path.
  }
};

export const handleParseStdin = async (): Promise<number> => {
  let raw: string;

  try {
    raw = await readStdin();
  } catch {
    return EXIT_CODES.OK;
  }

  if (raw.trim().length === 0) return EXIT_CODES.OK;

  const result = parseTrailer(raw);

  for (const invocation of result.invocations) {
    try {
      // Sequential by necessity: multiple invocations can append to the
      // same day's JSONL file, and concurrent `appendFile` calls to one
      // path are not safely interleavable.
      // eslint-disable-next-line no-await-in-loop -- intentional sequential emit (see comment above)
      const exitCode = await handleEmit([
        invocation.eventType,
        ...invocation.args,
      ]);

      if (exitCode !== EXIT_CODES.OK) {
        logFailure(
          `${invocation.eventType} emit failed (exit ${String(exitCode)})`
        );
      }
    } catch (error) {
      logFailure(
        `${invocation.eventType} emit threw: ${
          error instanceof Error ? error.message : String(error)
        }`
      );
    }
  }

  return EXIT_CODES.OK;
};
