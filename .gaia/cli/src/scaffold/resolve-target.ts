import {structuredError} from '../stderr.js';
import {resolvePackageTarget} from '../util/package-target.js';
import type {PackageTarget} from '../util/package-target.js';

type ResolvedTarget = Extract<PackageTarget, {ok: true}>;

/**
 * The frontend package a scaffold writes into, or `undefined` after reporting
 * the registry or descriptor failure. Callers return `CONFIG_INVALID` on
 * `undefined` before creating any file.
 */
export const resolveScaffoldTarget = (
  cwd: string,
  subcommand: string
): ResolvedTarget | undefined => {
  const target = resolvePackageTarget(cwd);

  if (!target.ok) {
    structuredError({
      code: 'gaia_packages',
      message: target.message,
      subcommand,
    });

    return undefined;
  }

  return target;
};
