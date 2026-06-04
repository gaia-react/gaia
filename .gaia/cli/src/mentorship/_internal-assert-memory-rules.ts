/**
 * Internal subcommand: re-assert per-machine memory rules consumed by
 * the session-start hook.
 *
 *   gaia mentorship _internal-assert-memory-rules
 *
 * Reads the current mentorship config and idempotently aligns the
 * projected memory contracts with the configured state. Exits 0 on
 * every path so the hook never blocks session start. Emits a single
 * JSON line on stdout describing the outcome; hooks ignore stdout by
 * default.
 */
import {EXIT_CODES} from '../exit.js';
import {resolveStorageRoots} from '../storage/paths.js';
import type {StorageRoots} from '../storage/paths.js';
import {readMentorshipConfig} from './config.js';
import {assertDisplayRule, removeDisplayRule} from './display-rule-memory.js';

type RunOptions = {
  roots?: StorageRoots;
};

export const run = (
  _argv: readonly string[],
  options: RunOptions = {}
): number => {
  const roots = options.roots ?? resolveStorageRoots();

  let enabled: boolean;

  try {
    const config = readMentorshipConfig(roots);
    enabled = config.enabled === true;
  } catch {
    // Config unreadable or missing; treat as disabled and remove any
    // stale rule projection. Never fail session start over this.
    try {
      removeDisplayRule(roots);
    } catch {
      // Best-effort.
    }

    process.stdout.write(
      `${JSON.stringify({
        code: 'mentorship_assert_skipped',
        reason: 'config_unreadable',
      })}\n`
    );

    return EXIT_CODES.OK;
  }

  if (!enabled) {
    try {
      removeDisplayRule(roots);
    } catch {
      // Best-effort.
    }

    process.stdout.write(
      `${JSON.stringify({
        code: 'mentorship_assert_disabled',
        mentorship_enabled: false,
      })}\n`
    );

    return EXIT_CODES.OK;
  }

  try {
    const outcome = assertDisplayRule(roots);

    process.stdout.write(
      `${JSON.stringify({
        body_written: outcome.body_written,
        code: 'mentorship_assert_ok',
        index_line_added: outcome.index_line_added,
        mentorship_enabled: true,
      })}\n`
    );
  } catch (error) {
    process.stdout.write(
      `${JSON.stringify({
        code: 'mentorship_assert_error',
        error: error instanceof Error ? error.message : String(error),
      })}\n`
    );
  }

  return EXIT_CODES.OK;
};
