/**
 * `gaia mentorship enable` (UAT-039, UAT-045).
 *
 * Interactive in a TTY context (stdin Y/N); `--yes` bypasses for CI / scripts.
 * The slash-command / skill layer (gaia-init) wraps the CLI invocation with
 * `AskUserQuestion` outside the CLI; this surface is the in-shell path.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {
  ensureMentorshipDirs as ensureMentorshipDirectories,
  resolveStorageRoots,
} from '../storage/index.js';
import type {StorageRoots} from '../storage/index.js';
import {askConfirm} from './ask.js';
import {readMentorshipConfig, writeMentorshipConfig} from './config.js';

type RunOptions = {
  roots?: StorageRoots;
};

const hasYesFlag = (argv: readonly string[]): boolean => argv.includes('--yes');

export const run = async (
  argv: readonly string[],
  options: RunOptions = {}
): Promise<number> => {
  const roots = options.roots ?? resolveStorageRoots();
  const yesFlag = hasYesFlag(argv);

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

  if (current.enabled === true) {
    process.stdout.write(
      `${JSON.stringify({
        at: new Date().toISOString(),
        code: 'mentorship_already_enabled',
      })}\n`
    );

    return EXIT_CODES.OK;
  }
  const confirmed = await askConfirm({
    cancelLabel: 'Cancel',
    confirmLabel: 'Yes, enable',
    question: 'Enable mentorship + anonymous analytics?',
    yesFlag,
  });

  if (!confirmed) {
    process.stdout.write(
      `${JSON.stringify({code: 'mentorship_enable_cancelled'})}\n`
    );

    return EXIT_CODES.OK;
  }

  try {
    writeMentorshipConfig({
      analyticsEnabled: true,
      decidedVia: 'mentorship-enable',
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

  try {
    await ensureMentorshipDirectories(roots);
  } catch (error) {
    structuredError({
      code: 'storage_inaccessible',
      message: error instanceof Error ? error.message : String(error),
      path: roots.mentorshipDir,
    });

    return EXIT_CODES.STORAGE_INACCESSIBLE;
  }
  process.stdout.write(
    `${JSON.stringify({
      at: new Date().toISOString(),
      code: 'mentorship_enabled',
    })}\n`
  );

  return EXIT_CODES.OK;
};
