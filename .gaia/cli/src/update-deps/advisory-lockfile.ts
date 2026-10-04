/**
 * Installed versions of a package, read from the root `pnpm-lock.yaml`.
 *
 * The lockfile can hold several YAML documents. pnpm writes its own
 * self-lockfile first (its `importers['.']` carries `packageManagerDependencies`
 * and its `packages:` lists only pnpm's own executables), and the project graph
 * in a later document. Only the project document is read: taking the first
 * `packages:` block, or a union of documents, would let a same-named entry in
 * the self-lockfile count as installed and mark a vulnerable install resolved.
 */
import {loadAll} from 'js-yaml';
import semver from 'semver';

/** Thrown when the lockfile does not parse or holds no project document. */
export class LockfileReadError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'LockfileReadError';
  }
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === 'object' && !Array.isArray(value);

const isProjectDocument = (document: unknown): boolean => {
  if (!isRecord(document) || !isRecord(document.importers)) return false;

  const root = document.importers['.'];

  return isRecord(root) && !Object.hasOwn(root, 'packageManagerDependencies');
};

/**
 * The `packages:` keys of the lockfile's project document. Throws
 * `LockfileReadError` when the text does not parse or no document qualifies.
 */
export const projectPackageKeys = (lockfileText: string): string[] => {
  let documents: unknown[];

  try {
    documents = loadAll(lockfileText);
  } catch {
    throw new LockfileReadError('pnpm-lock.yaml does not parse as YAML');
  }

  const project = documents.find((document) => isProjectDocument(document));

  if (!isRecord(project)) {
    throw new LockfileReadError('pnpm-lock.yaml holds no project document');
  }

  return isRecord(project.packages) ? Object.keys(project.packages) : [];
};

const compareVersions = (a: string, b: string): number => {
  if (semver.valid(a) !== null && semver.valid(b) !== null) {
    return semver.compare(a, b);
  }

  return a.localeCompare(b);
};

/** The distinct versions of `packageName` among lockfile package keys, ascending. */
export const versionsFromKeys = (
  keys: readonly string[],
  packageName: string
): string[] => {
  const versions = new Set<string>();

  for (const key of keys) {
    // A key is `name@version`, optionally followed by a peer suffix in
    // parentheses; a scoped name's own leading `@` is not the separator.
    const peerStart = key.indexOf('(');
    const bare = peerStart === -1 ? key : key.slice(0, peerStart);
    const separator = bare.lastIndexOf('@');

    if (separator > 0 && bare.slice(0, separator) === packageName) {
      versions.add(bare.slice(separator + 1));
    }
  }

  const distinct = [...versions];

  return distinct.toSorted(compareVersions);
};

/**
 * Every installed version of `packageName` in the lockfile's project document.
 * Throws `LockfileReadError` when no project document exists.
 */
export const installedVersions = (
  lockfileText: string,
  packageName: string
): string[] => versionsFromKeys(projectPackageKeys(lockfileText), packageName);
