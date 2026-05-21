/**
 * `gaia mentorship analytics disable`.
 *
 * Surgical: keeps `mentorship.enabled === true`, flips analytics off.
 * Mentorship JSONL writes continue; report generation halts.
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

  if (!current.analytics.enabled) {
    process.stdout.write(
      `${JSON.stringify({
        at: new Date().toISOString(),
        code: 'analytics_already_disabled',
      })}\n`
    );

    return EXIT_CODES.OK;
  }

  try {
    writeMentorshipConfig({
      analyticsEnabled: false,
      decidedVia: 'mentorship-analytics-disable',
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
      code: 'analytics_disabled',
    })}\n`
  );

  return EXIT_CODES.OK;
};
