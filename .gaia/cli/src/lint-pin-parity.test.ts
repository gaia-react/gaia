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

// An ABSENT exclusion list reads as an empty one, which is the truth: exempting
// nothing is what "no list" means. Anything present but not a sequence throws, on
// the same reasoning `readResolvedRuleVersions` throws below, and it is not
// hypothetical tidiness. pnpm iterates this value with `for..of`, so a scalar
// string iterates CHARACTER BY CHARACTER: `minimumReleaseAgeExclude: '*'` written
// without the leading dash yields the single pattern `*`, exempting every package.
// Collapsing that to `[]` would leave all four list assertions below passing
// vacuously at once, over a workspace with its hardening switched off.
const asList = (
  value: unknown,
  workspacePath: string,
  key: string
): unknown[] => {
  // `== null` catches BOTH absent and YAML-null, deliberately. js-yaml parses a
  // present-but-empty key (`minimumReleaseAgeExclude:` with its items deleted, or
  // an explicit `~`) to `null`, and pnpm reads that exactly as it reads absent:
  // the length check is falsy, so it builds no exclude policy at all. That
  // workspace exempts nothing, which is the MOST hardened state there is, so
  // throwing on it would red a required context over the safest possible config.
  // The trigger is live rather than theoretical: `.gaia/cli`'s release-age list
  // carries a single entry, so deleting that exemption and leaving the key behind
  // is the natural edit.
  if (value == null) return [];

  if (!Array.isArray(value)) {
    throw new TypeError(
      `${workspacePath}: \`${key}\` is present but is not a list; pnpm iterates a scalar character by character, so this may be exempting far more than it names`
    );
  }

  return value;
};

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

  // `Array.isArray` is not redundant beside `isMapping`: `typeof [] === 'object'`,
  // so a `packages:` emitted as a YAML sequence would pass the mapping test,
  // yield array indices from `Object.keys`, and fail two lines down as a bare
  // length mismatch naming no file. That is the diagnostic this throw promises.
  if (!isMapping(packages) || Array.isArray(packages)) {
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

// The two scalars are asserted for equality; the two exclusion lists are asserted
// for CONTAINMENT, not equality, because the files state a containment relation
// rather than a shared one. Equality would be wrong: root legitimately carries
// `bippy` and `chokidar` entries for packages `.gaia/cli` does not install. But
// omitting the lists entirely leaves the escape hatch for the very setting beside
// them unguarded, so exempting a package in `.gaia/cli` alone would be invisible,
// which is the likeliest real drift (a maintainer trips the window on a fresh
// publish and exempts it locally). `.gaia/cli/pnpm-workspace.yaml` states the
// direction outright: each entry earns its place against that workspace's closure,
// "which root's is a superset of". So: every `.gaia/cli` entry must appear in root's.
const readHardeningSettings = (
  workspacePath: string
): {
  minimumReleaseAge: unknown;
  minimumReleaseAgeExclude: unknown[];
  trustPolicy: unknown;
  trustPolicyExclude: unknown[];
} => {
  const workspace: unknown = parseYaml(readFileSync(workspacePath, 'utf8'));
  const settings = isMapping(workspace) ? workspace : {};

  return {
    minimumReleaseAge: settings.minimumReleaseAge,
    minimumReleaseAgeExclude: asList(
      settings.minimumReleaseAgeExclude,
      workspacePath,
      'minimumReleaseAgeExclude'
    ),
    trustPolicy: settings.trustPolicy,
    trustPolicyExclude: asList(
      settings.trustPolicyExclude,
      workspacePath,
      'trustPolicyExclude'
    ),
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
  // so it gets a guard on arrival rather than after the fact. Root's own copy is
  // guarded here too, since a relaxation there is the same defect one file over.
  //
  // Each side is asserted against the FLOOR, not merely asserted present, and the
  // difference is the whole guard. `toBeDefined()` is only `!== undefined`, so it
  // admits `minimumReleaseAge: 0`, `trustPolicy: none`, and a YAML `null` from
  // deleting a number and leaving its key, every one of which is the unhardened
  // state #1152 removed, reached by a one-character edit. Parity cannot catch them
  // either, because a symmetric weakening keeps both sides equal.
  //
  // The literals are duplicated from the two workspace files on purpose. It means
  // relaxing the window or the policy takes a deliberate test edit that a reviewer
  // sees, which is the correct friction for a supply-chain floor; tuning it upward
  // needs no edit, because the assertion is a floor rather than an equality.
  const FLOOR_MINUTES = 10_080;
  const TRUST_POLICY = 'no-downgrade';

  test('the root workspace enforces the hardening floor', () => {
    expect(rootSettings.minimumReleaseAge).toBeGreaterThanOrEqual(
      FLOOR_MINUTES
    );
    expect(rootSettings.trustPolicy).toBe(TRUST_POLICY);
  });

  test('.gaia/cli enforces the hardening floor', () => {
    expect(cliSettings.minimumReleaseAge).toBeGreaterThanOrEqual(FLOOR_MINUTES);
    expect(cliSettings.trustPolicy).toBe(TRUST_POLICY);
  });

  test('.gaia/cli hardens on the same terms as the root workspace', () => {
    expect({
      minimumReleaseAge: cliSettings.minimumReleaseAge,
      trustPolicy: cliSettings.trustPolicy,
    }).toStrictEqual({
      minimumReleaseAge: rootSettings.minimumReleaseAge,
      trustPolicy: rootSettings.trustPolicy,
    });
  });

  // Containment, not equality. Root's lists are supersets by design, so equality
  // would fail on `bippy` and `chokidar`; but an entry present ONLY in `.gaia/cli`
  // exempts a package from the setting above it in one workspace and not the other,
  // which is the asymmetric hardening this describe block exists to catch.
  // Compared as ATOMS rather than as literal strings, because pnpm does not
  // store one exemption per entry. When a package needs more than one exempted
  // version it merges them into a single union entry, `name@1.0.0 || 2.0.0`, and
  // writes that back into `pnpm-workspace.yaml` itself. Root's dependency closure
  // is a superset of `.gaia/cli`'s, so the two workspaces can legitimately need
  // different version counts of one shared package, at which point root carries
  // the union and `.gaia/cli` carries the single version. That is exactly the
  // containment these tests exist to permit, and literal membership cannot see
  // it: `arrayContaining` looks for `semver@6.3.1`, finds only the union, and
  // reds a required check over a valid configuration.
  //
  // The shape is pnpm's own (`expandPackageVersionSpecs`, the inverse of the
  // `mergePackageVersionSpecs` that writes the union), mirrored here rather than
  // imported: pnpm is this repo's `packageManager`, not a dependency of either
  // workspace, so there is nothing to import from. Its parse is followed exactly,
  // including the scope-aware `@` split that keeps `@scope/name` from splitting
  // on its own leading `@`.
  //
  // One deliberate divergence, stated because a wrong normalization here is the
  // same false-positive class this fixes: pnpm runs each version through
  // `semver.valid`, which also folds spellings like `=1.2.3` and `v1.2.3` onto
  // `1.2.3`. Trimming is all that pnpm's OWN output needs (its union separator
  // leaves a leading space), and `semver` is a dependency of neither workspace.
  // A hand-written `v1.2.3` on one side and `1.2.3` on the other would therefore
  // still red. Add the dependency and use `semver.valid` if that ever happens;
  // do not grow a second normalizer by hand, which is how the sibling predicate
  // below accumulated four rounds of shape-by-shape repair.
  //
  // A name-only entry stays one atom, so exempting EVERY version of a package in
  // `.gaia/cli` is not contained by exempting one version of it at root. That is
  // asymmetric hardening and stays red, which is pnpm's reading too.
  const exemptionAtoms = (list: unknown[]): unknown[] => {
    const atoms = new Set<unknown>();

    for (const entry of list) {
      // A non-string is the exactness tests' finding, not this one's. Passed
      // through unexpanded so it still compares, rather than being dropped into
      // a silently smaller list on the containing side.
      if (typeof entry !== 'string') {
        atoms.add(entry);
        continue;
      }

      const atIndex = entry.startsWith('@')
        ? entry.indexOf('@', 1)
        : entry.indexOf('@');

      if (atIndex === -1) {
        atoms.add(entry);
        continue;
      }

      const packageName = entry.slice(0, atIndex);

      for (const version of entry.slice(atIndex + 1).split('||')) {
        atoms.add(`${packageName}@${version.trim()}`);
      }
    }

    return [...atoms];
  };

  test('.gaia/cli exempts nothing from the release-age window that root does not', () => {
    expect(exemptionAtoms(rootSettings.minimumReleaseAgeExclude)).toEqual(
      expect.arrayContaining(exemptionAtoms(cliSettings.minimumReleaseAgeExclude))
    );
  });

  test('a merged union contains the single version it was merged from', () => {
    expect(exemptionAtoms(['semver@6.3.1 || 6.3.2'])).toEqual(
      expect.arrayContaining(exemptionAtoms(['semver@6.3.1']))
    );
  });

  test('a version only .gaia/cli exempts is still drift after expansion', () => {
    expect(exemptionAtoms(['semver@6.3.1 || 6.3.2'])).not.toEqual(
      expect.arrayContaining(exemptionAtoms(['semver@6.3.3']))
    );
  });

  test('exempting every version of a package is not contained by exempting one', () => {
    expect(exemptionAtoms(['semver@6.3.1'])).not.toEqual(
      expect.arrayContaining(exemptionAtoms(['semver']))
    );
  });

  // The floor above establishes what each setting IS; this establishes that it
  // still applies to anything. pnpm honours glob patterns in these lists, so a
  // single `'*'` entry exempts every package while leaving both scalars at their
  // floor, both lists in containment, and all of the above green: the hardening
  // is fully disabled with nothing red. Measured rather than reasoned — with `'*'`
  // present, widening the window to 20160 installs clean, where the same widening
  // without it fails naming 19 entries.
  //
  // Both workspace files already state the rule this encodes, "Scope each
  // exception to the exact version; no-downgrade stays enforced for everything
  // else", which is the same warrant the containment tests above rest on.
  //
  // Stated POSITIVELY, as what a legal entry looks like, rather than as a list of
  // characters to reject. That distinction is the whole point, and it was reached
  // the hard way: a blacklist can only enumerate the ways in, so each audit round
  // found one more. `*` was the first. Then `!`, which pnpm's single-pattern
  // matcher treats as INVERSION, so `'!zzz-not-a-real-package'` matches every
  // package and exempts everything while reading like a narrow exclusion, which
  // makes it strictly more dangerous than the wildcard it hides beside. Adding
  // that second character to a blacklist would only have invited a third.
  //
  // An npm specifier is `[@scope/]name[@version-union]`, and npm names are
  // URL-safe, so neither broadening construct can appear in a legitimate name.
  //
  // The version half is deliberately permissive, and that is not a hole: pnpm
  // runs every version through `semver.valid` and fails the install on anything
  // that is not exact, so `react@*` and `react@^1.0.0` are accepted here and
  // rejected loudly there. A permissive version half can only admit an entry pnpm
  // itself refuses; it can never admit a broad match.
  //
  // The `||` union form is accepted WITH surrounding spaces because that is the
  // spelling **pnpm writes itself**: it merges multiple exemptions for one package
  // into `name@1.0.0 || 2.0.0` and saves that back into `pnpm-workspace.yaml` on
  // an ordinary install. Rejecting it would red a required context over a list
  // pnpm authored, every entry of which is the exact-version exemption this
  // predicate exists to permit.
  //
  // Both character classes allow uppercase. npm has required lowercase only for
  // names registered since about 2014, and legacy names like `JSONStream` remain
  // installable and still arrive transitively; exempting one must not fail here.
  // Breadth is unaffected, since neither broadening construct is a letter.
  // Each version atom excludes `|` as well as whitespace, so it cannot overlap the
  // `||` separator beside it. Written the obvious way, with `[^\s]+`, the atom can
  // swallow the separator, the two alternatives become ambiguous, and the pattern
  // backtracks exponentially on a long entry.
  const LEGAL_SPECIFIER =
    /^(?:@[A-Za-z0-9][A-Za-z0-9._-]*\/)?[A-Za-z0-9][A-Za-z0-9._-]*(?:@[^\s|]+(?: *\|\| *[^\s|]+)*)?$/;

  const inexactEntries = (list: unknown[]): unknown[] =>
    list.filter(
      (entry) => typeof entry !== 'string' || !LEGAL_SPECIFIER.test(entry)
    );

  test('every release-age exemption names an exact package, not a pattern', () => {
    expect(inexactEntries(rootSettings.minimumReleaseAgeExclude)).toEqual([]);
    expect(inexactEntries(cliSettings.minimumReleaseAgeExclude)).toEqual([]);
  });

  test('every trust-policy exemption names an exact package, not a pattern', () => {
    expect(inexactEntries(rootSettings.trustPolicyExclude)).toEqual([]);
    expect(inexactEntries(cliSettings.trustPolicyExclude)).toEqual([]);
  });

  test('.gaia/cli exempts nothing from the trust policy that root does not', () => {
    expect(exemptionAtoms(rootSettings.trustPolicyExclude)).toEqual(
      expect.arrayContaining(exemptionAtoms(cliSettings.trustPolicyExclude))
    );
  });
});
