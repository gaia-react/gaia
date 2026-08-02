import {describe, expect, test} from 'vitest';
/**
 * Maintainer drift-guard for the `@gaia-react/lint` pin.
 *
 * `.gaia/cli` is its own pnpm workspace root with its own lockfile, so nothing
 * forces its lint pin to agree with the root workspace's and nothing reported
 * when it did not. The gap reached two minors and a major before anyone looked
 * (#1051): both workspaces linted green against their own pin, so CI said
 * nothing while `.gaia/cli/src` was checked by a rule set the rest of the repo
 * had left behind.
 *
 * Repair, when the parity test below goes red: set
 * `.gaia/cli/package.json`'s `@gaia-react/lint` to the root `package.json`
 * version, then `pnpm -C .gaia/cli install` and `pnpm -C .gaia/cli lint`, and
 * fix what the newly-arrived rules surface.
 *
 * The pin names the RULE SET, which is why parity is asserted on it alone and
 * not on the tool versions beside it (`eslint`, `prettier`, `typescript`,
 * `vitest`, `@types/node`). Those drift on their own schedule without changing
 * what either workspace considers an error.
 *
 * Fires on the pull request that causes the drift: root `package.json` is in
 * the `code` paths filter of `cli-tests.yml`, whose `Vitest (.gaia/cli)` job is
 * a declared-required context. Keep that filter entry, without it this guard
 * first fires on some later, unrelated `.gaia/cli/**` change.
 *
 * Maintainer-only by construction: `.gaia/cli/src` and `.gaia/cli/package.json`
 * are both release-excluded, so adopters carry neither this test nor its
 * subject.
 */
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from './util/repo-root-fixture.js';

const LINT_PACKAGE = '@gaia-react/lint';

// Read from `devDependencies` alone rather than searching every section: a
// lint preset belongs nowhere else, so a pin that turns up in `dependencies`
// is itself the defect and should fail the declares-test rather than satisfy
// it quietly.
const readPin = (manifestPath: string): string | undefined => {
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as {
    devDependencies?: Record<string, string>;
  };

  return manifest.devDependencies?.[LINT_PACKAGE];
};

describe('@gaia-react/lint pin parity', () => {
  const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);
  const rootPin = readPin(path.join(repoRoot, 'package.json'));
  const cliPin = readPin(path.join(repoRoot, '.gaia', 'cli', 'package.json'));

  // Both sides must be present. Absent these two, a rename or a dropped entry
  // would leave the parity test comparing `undefined` to `undefined`, and it
  // would pass vacuously on a workspace that had stopped consuming the shared
  // config entirely.
  test('package.json declares @gaia-react/lint in devDependencies', () => {
    expect(rootPin).toBeDefined();
  });

  test('.gaia/cli/package.json declares @gaia-react/lint in devDependencies', () => {
    expect(cliPin).toBeDefined();
  });

  test('.gaia/cli/package.json pins the same @gaia-react/lint version as package.json', () => {
    expect(cliPin).toBe(rootPin);
  });
});
