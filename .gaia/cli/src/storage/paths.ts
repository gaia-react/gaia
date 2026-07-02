/* eslint-disable unicorn/prevent-abbreviations -- StorageRoots field names
   (cloudDir, analyticsDir, mentorshipDir) and function names (ensureCloudDirs,
   ensureMentorshipDirs) are frozen interface contracts. Renaming would break
   downstream callers that bind to them. Internal-only locals follow the rule. */
/* eslint-disable no-bitwise -- POSIX file modes are bitfields; 0o777 masking
   is the standard idiom for verifying modes via & 0o777. */
/* eslint-disable sonarjs/no-os-command-from-path -- `git` on PATH is the
   canonical repo-root resolution mechanism (matches husky, lint-staged, and
   the rest of the project's tooling). */
import {execSync} from 'node:child_process';
import {existsSync} from 'node:fs';
import {chmod, mkdir, stat} from 'node:fs/promises';
import {homedir} from 'node:os';
import path from 'node:path';
import {structuredError} from '../stderr.js';

export type StorageRoots = {
  analyticsDir: string;
  cloudDir: string;
  installIdPath: string;
  memoryDir: string;
  mentorshipDir: string;
  profilePath: string;
  projectIdPath: string;
};

type ResolveArgs = {
  homeDir?: string;
  repoRoot?: string;
};

let cachedRepoRoot: string | undefined;

const resolveRepoRoot = (): string => {
  if (cachedRepoRoot !== undefined) {
    return cachedRepoRoot;
  }

  try {
    // canonical PATH tool for repo-root resolution; matches the rest of the
    // project's tooling (husky, lint-staged) which also assumes git on PATH.
    const out = execSync('git rev-parse --show-toplevel', {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
    cachedRepoRoot = out.length > 0 ? out : process.cwd();
  } catch {
    cachedRepoRoot = process.cwd();
  }

  return cachedRepoRoot;
};

/**
 * Claude project-slug derivation.
 *
 * Convention: replace `/` with `-` (the leading `/` becomes a leading `-`).
 *   /Users/you/projects/my-app
 *     -> -Users-you-projects-my-app
 */
export const deriveClaudeSlug = (repoRoot: string): string =>
  repoRoot.replaceAll('/', '-');

export const resolveStorageRoots = (args?: ResolveArgs): StorageRoots => {
  const repoRoot = args?.repoRoot ?? resolveRepoRoot();
  const home = args?.homeDir ?? homedir();
  const slug = deriveClaudeSlug(repoRoot);

  const cloudDir = path.join(repoRoot, '.gaia', 'local', 'telemetry', 'cloud');
  const analyticsDir = path.join(
    repoRoot,
    '.gaia',
    'local',
    'telemetry',
    'analytics'
  );
  const claudeProjectDir = path.join(home, '.claude', 'projects', slug, 'gaia');
  const mentorshipDir = path.join(claudeProjectDir, 'telemetry', 'mentorship');
  const installIdPath = path.join(claudeProjectDir, 'install-id.txt');
  const projectIdPath = path.join(repoRoot, '.gaia', 'local', '.project-id');
  const profilePath = path.join(claudeProjectDir, 'profile.md');
  const memoryDir = path.join(home, '.claude', 'projects', slug, 'memory');

  return {
    analyticsDir,
    cloudDir,
    installIdPath,
    memoryDir,
    mentorshipDir,
    profilePath,
    projectIdPath,
  };
};

const ensureInProjectDirectory = async (directory: string): Promise<void> => {
  if (existsSync(directory)) {
    return;
  }
  await mkdir(directory, {mode: 0o755, recursive: true});
};

/**
 * Ensures cloud + analytics directories exist with mode 755.
 * Idempotent. Always called before a cloud emit.
 */
export const ensureCloudDirs = async (roots: StorageRoots): Promise<void> => {
  await ensureInProjectDirectory(roots.cloudDir);
  await ensureInProjectDirectory(roots.analyticsDir);
};

const ensureOffProjectDirectoryCreatedTight = async (
  directory: string
): Promise<boolean> => {
  // Returns true if THIS call created the directory (so caller can chmod safely).
  if (existsSync(directory)) {
    // Pre-existing: do not modify mode (per task brief; chmod-on-create only).
    try {
      const st = await stat(directory);
      const mode = st.mode & 0o777;

      if (mode !== 0o700) {
        structuredError({
          code: 'mentorship_dir_mode_unexpected',
          expected_octal: '700',
          mode_octal: mode.toString(8),
          note: 'pre-existing directory left untouched (chmod runs on create only)',
          path: directory,
        });
      }
    } catch {
      // stat failure is benign here; surface only if mkdir below fails.
    }

    return false;
  }
  await mkdir(directory, {mode: 0o700, recursive: true});
  // recursive: true respects mode for *new* dirs; explicit chmod for safety
  // (umask can mask mkdir mode bits on some platforms).
  await chmod(directory, 0o700);

  return true;
};

/**
 * Ensures the GAIA-owned mentorship subtree exists with mode 700.
 * Only called when mentorship.enabled === true.
 * Idempotent.
 */
export const ensureMentorshipDirs = async (
  roots: StorageRoots
): Promise<void> => {
  // Path shape: <home>/.claude/projects/<slug>/gaia/telemetry/mentorship
  const {mentorshipDir} = roots;
  const telemetryDirectory = path.dirname(mentorshipDir); // .../gaia/telemetry
  const gaiaDirectory = path.dirname(telemetryDirectory); //  .../gaia

  // Tighten only the GAIA-owned segments (`gaia/` and below). The parent
  // `<slug>` directory (`~/.claude/projects/<slug>`) is Claude Code's, created
  // at 0755; GAIA never re-modes it. Excluding it avoids a spurious
  // `mentorship_dir_mode_unexpected` warning on every enable, since 0755 never
  // matches GAIA's 0700 expectation. In practice `<slug>` always pre-exists
  // (Claude Code owns it), so GAIA never stats or re-modes it here; if it were
  // absent, `mkdir recursive` for `gaia/` would materialize it at 0700, like
  // the other intermediates.
  //
  // Sequential by design: each segment must exist (and be tightened) before
  // the next is created so chmod-on-create lands on each new directory.
  for (const directory of [gaiaDirectory, telemetryDirectory, mentorshipDir]) {
    // eslint-disable-next-line no-await-in-loop -- intentional sequential creation
    await ensureOffProjectDirectoryCreatedTight(directory);
  }
};
