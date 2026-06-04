/**
 * `gaia telemetry parse-stdin`: read the PostToolUse `Task` hook input JSON
 * from stdin, extract the structured-trailer YAML block, and dispatch one or
 * more `gaia telemetry emit` invocations against `handleEmit` directly (no
 * sub-process spawn).
 *
 * Always exits 0; telemetry must never block the user's flow. Emit-level
 * failures are logged best-effort to `/tmp/gaia-telemetry-hook.log` and
 * swallowed.
 *
 * Replaces the awk-based YAML parser that previously lived in
 * `.claude/hooks/telemetry-task-postuse.sh`. The shell hook is now a thin
 * pipe to this subcommand.
 */
import {appendFileSync} from 'node:fs';
import {EXIT_CODES} from '../exit.js';
import {handleEmit} from './emit.js';
import {parseTrailer} from './parse-trailer.js';

const LOG_PATH = '/tmp/gaia-telemetry-hook.log';

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
