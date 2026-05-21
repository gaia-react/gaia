/**
 * `gaia mentorship analytics enable`.
 *
 * Surgical: requires `mentorship.enabled === true`. Flips analytics on
 * without touching the mentorship-enabled flag.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {resolveStorageRoots} from '../storage/paths.js';
import type {StorageRoots} from '../storage/paths.js';
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

  if (current.enabled !== true) {
    structuredError({
      code: 'mentorship_not_enabled',
      issue: 'enable mentorship first (gaia mentorship enable)',
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  if (current.analytics.enabled) {
    process.stdout.write(
      `${JSON.stringify({
        at: new Date().toISOString(),
        code: 'analytics_already_enabled',
      })}\n`
    );

    return EXIT_CODES.OK;
  }

  try {
    writeMentorshipConfig({
      analyticsEnabled: true,
      decidedVia: 'mentorship-analytics-enable',
      enabled: true,
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
      code: 'analytics_enabled',
    })}\n`
  );

  return EXIT_CODES.OK;
};
