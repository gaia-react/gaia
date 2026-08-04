/**
 * Maintainer drift-guards for the three things the two workspaces must agree on,
 * each asserted against the file that actually states it: the `@gaia-react/lint`
 * pin on each manifest, the `typescript-eslint` version on each lockfile because
 * no manifest states it, and the supply-chain hardening settings on each
 * `pnpm-workspace.yaml`.
 *
 * They share one cause. `.gaia/cli` is its own pnpm workspace root, so it
 * inherits nothing from the repository root and every one of these values exists
 * twice with no mechanism holding the copies together.
 *
 * Nothing reported when the pin drifted. The gap reached two minors and a major
 * before anyone looked (#1051): both workspaces linted green against their own
 * pin, so CI said nothing while `.gaia/cli/src` was checked by a rule set the
 * rest of the repo had left behind.
 *
 * Repair, when the parity test below goes red: set
 * `.gaia/cli/package.json`'s `@gaia-react/lint` to the root `package.json`
 * version, then `pnpm -C .gaia/cli install` and `pnpm -C .gaia/cli lint`, and
 * fix what the newly-arrived rules surface.
 *
 * The pin fixes the preset's own DIRECT plugin set, which is why parity is
 * asserted on it alone and not on the tool versions beside it (`eslint`,
 * `prettier`, `typescript`, `vitest`, `@types/node`). Those move without
 * changing what either workspace considers an error.
 *
 * One rule-bearing package cannot be guarded on the manifest pin at all, so the
 * second describe block below asserts on the lockfile instead.
 * `typescript-eslint` is a direct dependency of neither workspace and is not
 * pinned by the preset; it arrives transitively through
 * `eslint-config-airbnb-extended`, whose own range for it is a caret, so each
 * workspace's lockfile freezes it independently at whatever that caret resolved
 * to on the day the lockfile was last written. The two can therefore sit on
 * different versions with every manifest assertion green, which matters because
 * every `@typescript-eslint/*` rule implementation and every `tseslint.configs.*`
 * preset comes from there.
 *
 * Guarded for this package alone, which is a deliberate narrowing rather than an
 * oversight. The preset reaches at least eight other rule-bearing packages by the
 * same caret mechanism, and two of them are live divergences today, so the general
 * form is real work with a real decision inside it: parity is worth enforcing for
 * a package whose rules both workspaces actually run, and worth nothing for one
 * whose rules neither enables. Widening this constant without settling that turns
 * a guard into noise. Tracked separately (#1205).
 *
 * Repair, when the lockfile parity test goes red: re-resolve the LAGGING
 * workspace, `pnpm update typescript-eslint` from its own root, and fix what the
 * newly-arrived rules surface. Do not reach for an exact pin to hold the two
 * together. A direct dependency outside `eslint-config-airbnb-extended`'s range
 * does not error, it installs a second copy while the rules keep coming from
 * airbnb-extended's, so the pin goes decorative and this guard reads it and
 * passes. Asserting on the resolved version is what keeps the failure loud.
 *
 * Fires on the pull request that causes the drift: root `package.json`,
 * `pnpm-lock.yaml` and `pnpm-workspace.yaml` are all three in the `code` paths
 * filter of `cli-tests.yml`, whose `Vitest (.gaia/cli)` job is a declared-required
 * context. Keep all three entries, one per subject above, because each guard has
 * a different root-side trigger: a manifest bump for the pin, a re-resolve for the
 * transitive version (which touches no manifest at all), and a settings edit for
 * the hardening. Without them a guard first fires on some later, unrelated
 * `.gaia/cli/**` change. Every `.gaia/cli` side is already covered by
 * `.gaia/cli/**`.
 *
 * Maintainer-only by construction: `.gaia/cli/src` and `.gaia/cli/package.json`
 * are both release-excluded, so adopters carry neither this test nor its
 * subject.
 */
import {load as parseYaml} from 'js-yaml';
import {describe, expect, test} from 'vitest';
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from './util/repo-root-fixture.js';

const LINT_PACKAGE = '@gaia-react/lint';

const RULE_PACKAGE = 'typescript-eslint';

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

// Narrow js-yaml's `unknown` before reading a key off it. Local rather than
// shared because `.gaia/cli/src` already keeps this idiom local at three sites
// (`release/region-registry.ts`, `update/regen-regions.ts`, `release/scrub.ts`);
// none is exported, and exporting one for a test is a wider change than this
// guard earns.
const isMapping = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null;

// Read the `packages` map rather than `snapshots`: both list the package, but
// `snapshots` keys carry a peer-resolution suffix, so a version would have to be
// cut back out of `typescript-eslint@8.65.0(eslint@…)(typescript@…)`. `packages`
// keys are a plain `name@version`.
//
// Throwing on a missing or non-object `packages` map is the point rather than
// defensiveness: this reader exists to make a drift LOUD, and a lockfile format
// change that silently yielded `[]` on both sides would satisfy the parity test
// below while checking nothing. A thrown error fails the suite and names the file.
const readResolvedRuleVersions = (lockfilePath: string): string[] => {
  const lockfile: unknown = parseYaml(readFileSync(lockfilePath, 'utf8'));
  const packages = isMapping(lockfile) ? lockfile.packages : undefined;

  if (!isMapping(packages)) {
    throw new Error(
      `${lockfilePath}: no \`packages\` map; the pnpm lockfile format has changed and this guard needs updating`
    );
  }

  const prefix = `${RULE_PACKAGE}@`;

  // Deliberately unsorted. The count assertions below pin each side at exactly
  // one entry, so there is no order for a second element to be in; a sort here
  // would only tidy an array whose own test has already gone red.
  return Object.keys(packages)
    .filter((key) => key.startsWith(prefix))
    .map((key) => key.slice(prefix.length));
};

// The two scalars only. The exclusion lists beside them are deliberately NOT
// asserted: each is scoped to its own workspace's closure and each file says so,
// so root carries `bippy` and `chokidar` entries for packages `.gaia/cli` does
// not install. Asserting those would demand a "shared subset" that neither file
// declares, and inventing one is a rule that drifts from both.
const readHardeningSettings = (
  workspacePath: string
): {minimumReleaseAge: unknown; trustPolicy: unknown} => {
  const workspace: unknown = parseYaml(readFileSync(workspacePath, 'utf8'));
  const settings = isMapping(workspace) ? workspace : {};

  return {
    minimumReleaseAge: settings.minimumReleaseAge,
    trustPolicy: settings.trustPolicy,
  };
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

describe('typescript-eslint resolution parity', () => {
  const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);
  const rootVersions = readResolvedRuleVersions(
    path.join(repoRoot, 'pnpm-lock.yaml')
  );
  const cliVersions = readResolvedRuleVersions(
    path.join(repoRoot, '.gaia', 'cli', 'pnpm-lock.yaml')
  );

  // Exactly one, on both sides, before the versions are compared at all. Two
  // entries means the workspace installs two copies of the rule set, which the
  // parity test cannot express: it would have to pick one, and picking either
  // asserts something untrue about the other. Zero means the transitive path
  // through `eslint-config-airbnb-extended` has gone, and comparing [] to []
  // would pass while the guard's whole subject was absent.
  test('pnpm-lock.yaml resolves exactly one typescript-eslint', () => {
    expect(rootVersions).toHaveLength(1);
  });

  test('.gaia/cli/pnpm-lock.yaml resolves exactly one typescript-eslint', () => {
    expect(cliVersions).toHaveLength(1);
  });

  test('both workspaces resolve the same typescript-eslint version', () => {
    expect(cliVersions).toStrictEqual(rootVersions);
  });
});

describe('supply-chain hardening parity', () => {
  const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);
  const rootSettings = readHardeningSettings(
    path.join(repoRoot, 'pnpm-workspace.yaml')
  );
  const cliSettings = readHardeningSettings(
    path.join(repoRoot, '.gaia', 'cli', 'pnpm-workspace.yaml')
  );

  // `.gaia/cli` is a separate pnpm root, so it inherits nothing from the root
  // workspace and both settings exist twice, by hand, with no mechanism holding
  // them together. That is the same shape as the `@gaia-react/lint` pin above,
  // whose two copies drifted two minors and a major before anyone looked (#1051),
  // so it gets a guard on arrival rather than after the fact.
  //
  // Asserted defined before asserted equal, for the reason the pin tests give:
  // a renamed or dropped key would otherwise leave this comparing `undefined` to
  // `undefined`, passing on a workspace that had stopped hardening entirely,
  // which is precisely the unhardened state #1152 removed.
  test('package.json workspace defines both hardening settings', () => {
    expect(rootSettings.minimumReleaseAge).toBeDefined();
    expect(rootSettings.trustPolicy).toBeDefined();
  });

  test('.gaia/cli workspace defines both hardening settings', () => {
    expect(cliSettings.minimumReleaseAge).toBeDefined();
    expect(cliSettings.trustPolicy).toBeDefined();
  });

  test('.gaia/cli hardens on the same terms as the root workspace', () => {
    expect(cliSettings).toStrictEqual(rootSettings);
  });
});
