/**
 * `gaia mentorship disable` (UAT-040).
 *
 * No `AskUserQuestion`. Existing files are NOT touched (data preserved); the
 * compute-profile guard short-circuits while disabled.
 *
 * `analyticsEnabled` is carried forward from the prior config state — disable
 * does not flip the analytics preference (UAT-040 only addresses the
 * mentorship flag and JSONL writes).
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {resolveStorageRoots} from '../storage/index.js';
import type {StorageRoots} from '../storage/index.js';
import {readMentorshipConfig, writeMentorshipConfig} from './config.js';

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
  process.stdout.write(
    `${JSON.stringify({
      at: new Date().toISOString(),
      code: 'mentorship_disabled',
    })}\n`
  );

  return EXIT_CODES.OK;
};
