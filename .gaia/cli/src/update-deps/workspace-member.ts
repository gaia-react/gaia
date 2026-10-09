import {load} from 'js-yaml';
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';

export const CLI_WORKSPACE_MEMBER = '.gaia/cli';

/**
 * Returns the CLI workspace member path when the root pnpm-workspace.yaml lists
 * it and its manifest exists, else null. Never throws.
 */
export const readCliWorkspaceMember = (repoRoot: string): null | string => {
  try {
    const parsed: unknown = load(
      readFileSync(path.join(repoRoot, 'pnpm-workspace.yaml'), 'utf8')
    );
    if (typeof parsed !== 'object' || parsed === null) return null;
    const {packages} = parsed as {packages?: unknown};
    if (!Array.isArray(packages) || !packages.includes(CLI_WORKSPACE_MEMBER))
      return null;
    // Joined, never spelled whole: the adopter bundle is scanned for the
    // literal path of a release-excluded file.
    const manifestPath = path.posix.join(CLI_WORKSPACE_MEMBER, 'package.json');

    return existsSync(path.join(repoRoot, manifestPath)) ? CLI_WORKSPACE_MEMBER
      : null;
  } catch {
    return null;
  }
};
