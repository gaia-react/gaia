/**
 * `gaia mentorship purge` (UAT-041, UAT-045).
 *
 * Deletes all mentorship data:
 *   - <home>/.claude/projects/<slug>/gaia/telemetry/mentorship/  (entire subtree)
 *   - <home>/.claude/projects/<slug>/gaia/profile.md
 *   - <repo>/.gaia/local/telemetry/analytics/*.json
 *
 * Does NOT touch the cloud stream files (UAT-041 explicit). Does NOT delete
 * mentorship.json — the user keeps their opt-in preference.
 *
 * Regenerates install-id.txt as a fresh ULID after deletion (privacy
 * contract: same machine, fresh ID, no continuity with prior data).
 */
import {
  existsSync,
  mkdirSync,
  readdirSync,
  rmSync,
  statSync,
  unlinkSync,
} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {readOrCreateInstallId, resolveStorageRoots} from '../storage/index.js';
import type {StorageRoots} from '../storage/index.js';
import {askConfirm} from './ask.js';

type RunOptions = {
  roots?: StorageRoots;
};

const hasYesFlag = (argv: readonly string[]): boolean => argv.includes('--yes');

const hasAnyMentorshipData = (roots: StorageRoots): boolean => {
  if (existsSync(roots.mentorshipDir)) return true;

  if (existsSync(roots.installIdPath)) return true;

  if (existsSync(roots.profilePath)) return true;

  if (existsSync(roots.analyticsDir)) {
    try {
      const entries = readdirSync(roots.analyticsDir);

      if (entries.some((entry) => entry.endsWith('.json'))) {
        return true;
      }
    } catch {
      // Unreadable analytics dir is benign for the "anything to purge" check.
    }
  }

  return false;
};

const deleteMentorshipSubtree = (roots: StorageRoots): void => {
  // Mentorship subtree under ~/.claude/projects/<slug>/gaia/telemetry/mentorship/
  if (existsSync(roots.mentorshipDir)) {
    rmSync(roots.mentorshipDir, {force: true, recursive: true});
  }

  // profile.md sibling under ~/.claude/projects/<slug>/gaia/
  if (existsSync(roots.profilePath)) {
    unlinkSync(roots.profilePath);
  }

  // install-id.txt — delete so readOrCreateInstallId regenerates a fresh ULID.
  if (existsSync(roots.installIdPath)) {
    unlinkSync(roots.installIdPath);
  }
};

const deleteAnalyticsReports = (roots: StorageRoots): void => {
  if (!existsSync(roots.analyticsDir)) return;
  let entries: string[];

  try {
    entries = readdirSync(roots.analyticsDir);
  } catch {
    return;
  }

  const jsonEntries = entries.filter((entry) => entry.endsWith('.json'));

  for (const entry of jsonEntries) {
    const fullPath = path.join(roots.analyticsDir, entry);

    try {
      const stats = statSync(fullPath);

      if (stats.isFile()) {
        unlinkSync(fullPath);
      }
    } catch {
      // Skip entries that vanish mid-iteration.
    }
  }
};

export const run = async (
  argv: readonly string[],
  options: RunOptions = {}
): Promise<number> => {
  const roots = options.roots ?? resolveStorageRoots();
  const yesFlag = hasYesFlag(argv);

  if (!hasAnyMentorshipData(roots)) {
    process.stdout.write(
      `${JSON.stringify({code: 'no_mentorship_data_to_purge'})}\n`
    );

    return EXIT_CODES.OK;
  }
  const confirmed = await askConfirm({
    cancelLabel: 'Cancel',
    confirmLabel: 'Yes, delete all mentorship data',
    question: 'Delete all mentorship data? This cannot be undone.',
    yesFlag,
  });

  if (!confirmed) {
    process.stdout.write(
      `${JSON.stringify({code: 'mentorship_purge_cancelled'})}\n`
    );

    return EXIT_CODES.OK;
  }

  try {
    deleteMentorshipSubtree(roots);
    deleteAnalyticsReports(roots);
  } catch (error) {
    structuredError({
      code: 'storage_inaccessible',
      message: error instanceof Error ? error.message : String(error),
    });

    return EXIT_CODES.STORAGE_INACCESSIBLE;
  }
  // Regenerate install-id.txt — readOrCreateInstallId recreates the file
  // (with mode 600) when absent. Caller must ensure the parent claude-project
  // directory exists, which the prior writes guarantee unless the user
  // purged a never-enabled tree.
  let freshInstallId: string;

  try {
    // The parent <slug>/gaia directory may have been wiped out by rmSync
    // above only if mentorshipDir was its only child. Re-create the install
    // file's parent before regenerating the install-id, mirroring the
    // mode-700 contract that ensureMentorshipDirs upholds.
    const installParent = path.dirname(roots.installIdPath);

    if (!existsSync(installParent)) {
      mkdirSync(installParent, {mode: 0o700, recursive: true});
    }
    freshInstallId = readOrCreateInstallId(roots);
  } catch (error) {
    structuredError({
      code: 'storage_inaccessible',
      message: error instanceof Error ? error.message : String(error),
      path: roots.installIdPath,
    });

    return EXIT_CODES.STORAGE_INACCESSIBLE;
  }
  process.stdout.write(
    `${JSON.stringify({
      at: new Date().toISOString(),
      code: 'mentorship_purged',
      fresh_install_id: freshInstallId,
    })}\n`
  );

  return EXIT_CODES.OK;
};
