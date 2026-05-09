/**
 * Source-change detection for the smart-cron decision tree.
 *
 * `appChangedSince(repoRoot, sha)` runs
 * `git log <sha>..HEAD --name-only --pretty=format: -- app/` and returns
 * `true` if any line is non-blank.
 *
 * If `<sha>` is unreachable (e.g. force-push rewrote history), git
 * exits non-zero and this helper returns `false`. The workflow handles
 * the unreachable-state branch separately in a future slice; slice 1
 * documents the limitation here and treats unreachable as "no change".
 */
import {execFileSync} from 'node:child_process';

export const appChangedSince = (repoRoot: string, sha: string): boolean => {
  try {
    const stdout = execFileSync(
      'git',
      [
        'log',
        `${sha}..HEAD`,
        '--name-only',
        '--pretty=format:',
        '--',
        'app/',
      ],
      {
        cwd: repoRoot,
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'ignore'],
      }
    );

    return stdout
      .split('\n')
      .some((line) => line.trim().length > 0);
  } catch {
    return false;
  }
};
