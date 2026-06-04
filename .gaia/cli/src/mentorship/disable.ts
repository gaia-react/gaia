/**
 * `gaia mentorship disable`.
 *
 * No `AskUserQuestion`. Existing files are NOT touched (data preserved); the
 * compute-profile guard short-circuits while disabled.
 *
 * `analyticsEnabled` is carried forward from the prior config state; disable
 * does not flip the analytics preference. Disable only addresses the
 * mentorship flag and JSONL writes.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {resolveStorageRoots} from '../storage/paths.js';
import type {StorageRoots} from '../storage/paths.js';
import {readMentorshipConfig, writeMentorshipConfig} from './config.js';
import {removeDisplayRule} from './display-rule-memory.js';

type RunOptions = {
  roots?: StorageRoots;
};

export const run = (
  _argv: readonly string[],
  options: RunOptions = {}
): number => {
  const roots = options.roots ?? resolveStorageRoots();

  let current;

  try {
    current = readMentorshipConfig(roots);
  } catch (error) {
    structuredError({
      code: 'config_invalid',
      message: error instanceof Error ? error.message : String(error),
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  if (current.enabled === false) {
    process.stdout.write(
      `${JSON.stringify({
        at: new Date().toISOString(),
        code: 'mentorship_already_disabled',
      })}\n`
    );

    return EXIT_CODES.OK;
  }

  try {
    writeMentorshipConfig({
      analyticsEnabled: current.analytics.enabled,
      decidedVia: 'mentorship-disable',
      enabled: false,
      roots,
    });
  } catch (error) {
    structuredError({
      code: 'config_invalid',
      message: error instanceof Error ? error.message : String(error),
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  // Remove the mentorship-display rule from per-machine memory. Idempotent;
  // a no-op when the rule was never installed (e.g. the user is disabling
  // an enable that was set via the legacy `.claude/rules/` path).
  removeDisplayRule(roots);

  process.stdout.write(
    `${JSON.stringify({
      at: new Date().toISOString(),
      code: 'mentorship_disabled',
    })}\n`
  );

  return EXIT_CODES.OK;
};
