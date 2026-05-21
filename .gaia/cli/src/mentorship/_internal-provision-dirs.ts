/* eslint-disable unicorn/prevent-abbreviations -- the filename is a frozen
   subcommand-name contract: `gaia mentorship _internal-provision-dirs` is
   wired into gaia-init's slash-command flow. Renaming would break the
   dispatcher. */
/**
 * Internal subcommand consumed by gaia-init's slash-command flow.
 *
 * Locked subcommand name:
 *
 *   gaia mentorship _internal-provision-dirs
 *
 * Provisions the mentorship subtree under
 * `~/.claude/projects/<slug>/gaia/telemetry/mentorship/` with mode 700/600.
 * Idempotent.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {
  ensureMentorshipDirs as ensureMentorshipDirectories,
  resolveStorageRoots,
} from '../storage/paths.js';
import type {StorageRoots} from '../storage/paths.js';

type RunOptions = {
  roots?: StorageRoots;
};

export const run = async (
  _argv: readonly string[],
  options: RunOptions = {}
): Promise<number> => {
  const roots = options.roots ?? resolveStorageRoots();

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
      code: 'mentorship_dirs_provisioned',
      mentorship_dir: roots.mentorshipDir,
    })}\n`
  );

  return EXIT_CODES.OK;
};
