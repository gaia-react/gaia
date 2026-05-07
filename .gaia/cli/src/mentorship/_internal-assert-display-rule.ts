/**
 * Internal subcommand: re-assert the mentorship-display rule's projection
 * into per-machine user memory.
 *
 *   gaia mentorship _internal-assert-display-rule
 *
 * Reads the current mentorship config:
 *   - enabled === true  → call `assertDisplayRule(roots)` (idempotent install).
 *   - enabled === false → call `removeDisplayRule(roots)` (idempotent remove).
 *
 * Designed to run from a session-start hook every time Claude opens the
 * project, so the rule self-heals if the user accidentally edits or
 * deletes the memory file. Exits 0 on every path so the hook never
 * blocks session start.
 *
 * Emits a single JSON line on stdout describing the outcome:
 *
 *   { code, mentorship_enabled, body_written, index_line_added }
 *
 * Hooks ignore stdout by default; humans inspecting the hook trail can
 * see what changed.
 */
import {EXIT_CODES} from '../exit.js';
import {resolveStorageRoots} from '../storage/index.js';
import type {StorageRoots} from '../storage/index.js';
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
    // Config unreadable or missing — treat as disabled and remove any
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
