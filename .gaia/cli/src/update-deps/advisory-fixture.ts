/**
 * Lockfile fixtures shaped like the real root `pnpm-lock.yaml`: a pnpm
 * self-lockfile document first, then the project graph. A decoy placed in the
 * self-lockfile document proves a reader never counts it as installed.
 */

const packageEntries = (keys: readonly string[]): string =>
  keys
    .map(
      (key) => `\n  '${key}':\n    resolution: {integrity: sha512-fixture}\n`
    )
    .join('');

/** The self-lockfile document alone, with optional decoy package keys. */
export const selfLockfileDocument = (decoys: readonly string[] = []): string =>
  `---
lockfileVersion: '9.0'

importers:

  .:
    configDependencies: {}
    packageManagerDependencies:
      pnpm:
        specifier: 12.7.0
        version: 12.7.0

packages:

  '@pnpm/exe.darwin-arm64@12.7.0':
    resolution: {integrity: sha512-fixture}
    cpu: [arm64]
    os: [darwin]
${packageEntries(decoys)}`;

/** A two-document lockfile: self-lockfile decoys, then project package keys. */
export const twoDocumentLockfile = (options: {
  decoys?: readonly string[];
  project?: readonly string[];
}): string => `${selfLockfileDocument(options.decoys)}
---
lockfileVersion: '9.0'

settings:
  autoInstallPeers: true

importers:

  .:
    devDependencies:
      left-pad:
        specifier: 1.3.0
        version: 1.3.0

packages:
${packageEntries(options.project ?? [])}`;
