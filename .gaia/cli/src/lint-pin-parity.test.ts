/**
 * Maintainer drift-guards for the three things the two workspaces must agree on,
 * each asserted against the file that actually states it: the `@gaia-react/lint`
 * pin on each manifest, the resolved version of every shared rule-bearing package
 * on each lockfile because no manifest states those, and the supply-chain
 * hardening settings on each `pnpm-workspace.yaml`.
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
 * A whole class of rule-bearing package cannot be guarded on the manifest pin at
 * all, so the second describe block below asserts on the lockfiles instead.
 * `typescript-eslint` is the clearest case: a direct dependency of neither
 * workspace and pinned by neither the preset nor a manifest, it arrives
 * transitively through `eslint-config-airbnb-extended`, whose own range for it is
 * a caret, so each workspace's lockfile freezes it independently at whatever that
 * caret resolved to on the day the lockfile was last written. The two can
 * therefore sit on different versions with every manifest assertion green, which
 * matters because every `@typescript-eslint/*` rule implementation and every
 * `tseslint.configs.*` preset comes from there.
 *
 * The mechanism is the arrival path rather than the package, so the guard covers
 * the packages that arrive that way AND announce themselves as rule providers by
 * name: 30 of them resolve in both lockfiles today and any can float apart the
 * same way. Which ones earn parity is decided by the naming convention at
 * `RULE_PACKAGE_PATTERN` below, not by a list, so a plugin that arrives later is
 * guarded on arrival; a package that should NOT be compared by version is named
 * in `PARITY_EXEMPT` with its reason, and that is the only way out.
 *
 * The convention is the selector, so a package arriving by the same caret under a
 * different naming family is outside this guard. That is a boundary rather than a
 * clean bill of health, and it is not hypothetical: the import resolvers
 * (`eslint-import-resolver-typescript`) and `eslint-module-utils` decide whether
 * `import/no-unresolved` can resolve a specifier at all, they arrive exactly the
 * same way, and they are divergent today. Widening the convention to a fourth
 * family is a decision about the criterion rather than a missing entry, so it is
 * tracked (#1269) rather than taken here.
 *
 * The criterion behind both, worth stating once: parity is worth enforcing for a
 * package whose rules a workspace actually runs, and worth nothing for one whose
 * rules neither enables. That question is answered per package by reading the
 * resolved configs (`eslint --print-config`) and recording the answer as an
 * exemption, rather than by computing it here. Computing it would need the ROOT
 * workspace installed, and the job that runs this file installs `.gaia/cli` alone
 * (`cli-tests.yml`), so the check would have to add a full root install to a
 * required context to compare version strings.
 *
 * Repair, when the lockfile parity test goes red: re-resolve the LAGGING
 * workspace for the package the failure names, `pnpm update <package>` from its
 * own root, and fix what the newly-arrived rules surface. Do not reach for an
 * exact pin to hold the two together. A direct dependency outside
 * `eslint-config-airbnb-extended`'s range does not error, it installs a second
 * copy while the rules keep coming from airbnb-extended's, so the pin goes
 * decorative and this guard reads it and passes. Asserting on the resolved
 * version is what keeps the failure loud.
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

// Which packages earn resolution parity, expressed as the npm naming convention
// for an ESLint rule provider rather than as a list of names. A list is the
// failure mode: it makes the DEFAULT silence, so a plugin that arrives later
// through the same caret is unguarded until someone remembers it, which is how
// the audit roster lost four files to #813 and three more to #1243. A pattern
// makes the default coverage, closes the family permanently, and over-matches
// only in the safe direction, since a package it catches that neither workspace
// enables costs an exemption below rather than a missed drift.
//
// Three arms, each matching something today (asserted, so a broken arm cannot
// pass vacuously): a scoped provider (`@stylistic/eslint-plugin`,
// `@typescript-eslint/eslint-plugin`), an unscoped one (`eslint-plugin-unicorn`,
// `eslint-config-prettier`), and the bare `typescript-eslint` meta-package, which
// follows no convention because it is the flat-config entry point rather than a
// plugin. `eslint-config-*` is in deliberately: a shared config decides which
// rules exist at all (`eslint-config-airbnb-extended`) or turns them off
// wholesale (`eslint-config-prettier`), so it changes the effective rule set as
// surely as a plugin does.
//
// `@typescript-eslint/parser` is absent by name and covered anyway: the
// `typescript-eslint` meta-package depends on the parser and the plugin at its
// own exact version, so the parser cannot float away from a guarded meta-package.
const RULE_PACKAGE_PATTERN =
  /^(?:@[^/]+\/eslint-(?:plugin|config)|eslint-(?:plugin|config)-|typescript-eslint$)/;

// The escape hatch, and the ONLY one: a package named here is not compared **by
// version**, and its entry must say why. Absent from this map means guarded,
// which is the inverse of a hand-written inclusion list and the reason the
// pattern above is safe to leave broad.
//
// Presence parity still applies to an exempt package, deliberately: the
// population test below compares the two lockfiles' whole name sets with no
// exemption filter, so an exempt package leaving one workspace still reds. An
// exemption says "these two versions need not agree", never "this package may
// vanish from one side unnoticed", and the second is the drift that hides.
//
// The rationale is data rather than a comment so a stale entry can explain
// itself in the failure message, and the hygiene test below reds when an
// exemption stops naming a package both workspaces install, so this map cannot
// quietly outlive its subject.
const PARITY_EXEMPT: Record<string, string> = {
  // Neither workspace is a Next.js app and neither loads this plugin: it appears
  // in NEITHER resolved config, verified with `eslint --print-config` against
  // `app/root.tsx` and `.gaia/cli/src/exit.ts` rather than inferred from the
  // absence of a preset. So its two lockfiles can differ without changing a
  // single rule in either workspace.
  //
  // Exempted rather than converged because converging does not hold. It arrives
  // transitively through `eslint-config-airbnb-extended`'s caret, so the next
  // re-resolve floats it apart again, and each recurrence would red a required
  // check over a package whose rules nobody runs. That is how a guard becomes
  // noise a maintainer learns to re-resolve past, which costs more than the
  // drift it reports.
  '@next/eslint-plugin-next':
    'loaded by neither workspace, so a version difference changes no rule; converging it is churn that re-diverges on the next re-resolve',
};

// Anti-vacuity floor for the shared population, not a pin on its size. 30
// packages match today, so this cannot churn on ordinary preset movement; what
// it catches is the pattern or the reader silently matching (almost) nothing,
// which would leave every comparison below passing over an empty set.
const SHARED_FLOOR = 20;

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
// the same reasoning `readRulePackageVersions` throws below, and it is not
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
const readRulePackageVersions = (
  lockfilePath: string
): Map<string, string[]> => {
  const lockfile: unknown = parseYaml(readFileSync(lockfilePath, 'utf8'));
  const packages = isMapping(lockfile) ? lockfile.packages : undefined;

  // `Array.isArray` is not redundant beside `isMapping`: `typeof [] === 'object'`,
  // so a `packages:` emitted as a YAML sequence would pass the mapping test,
  // yield array indices from `Object.keys`, and produce a bare empty population
  // naming no file. That is the diagnostic this throw promises.
  if (!isMapping(packages) || Array.isArray(packages)) {
    throw new Error(
      `${lockfilePath}: no \`packages\` map; the pnpm lockfile format has changed and this guard needs updating`
    );
  }

  const resolved = new Map<string, string[]>();

  // A key is `name@version`, and a SCOPED name carries its own leading `@`, so
  // the version splits on the LAST `@` rather than the first. Splitting on the
  // first would name every scoped package the empty string and collapse five of
  // them into one entry, which compares nothing while looking green. Index 0 is
  // that leading scope `@`, so the filter demands `> 0` rather than `!== -1`.
  const ruleEntries = Object.keys(packages)
    .map((key) => {
      const separator = key.lastIndexOf('@');

      return {
        name: key.slice(0, separator),
        separator,
        version: key.slice(separator + 1),
      };
    })
    .filter(
      ({name, separator}) => separator > 0 && RULE_PACKAGE_PATTERN.test(name)
    );

  for (const {name, version} of ruleEntries) {
    // Accumulated rather than overwritten: pnpm can resolve two copies of one
    // package, and the single-copy test below exists to say so. Overwriting here
    // would hide the second copy from the test written to find it.
    const versions = resolved.get(name) ?? [];

    versions.push(version);
    resolved.set(name, versions);
  }

  return resolved;
};

// Sorted so both the population comparison and the version record report a
// stable diff rather than one that reorders with pnpm's own key order.
const sortedNames = (packages: Map<string, string[]>): string[] => {
  const names = [...packages.keys()];

  return names.toSorted((left, right) => left.localeCompare(right));
};

// The two scalars are asserted for equality; the two exclusion lists are asserted
// for CONTAINMENT, not equality, because the files state a containment relation
// rather than a shared one. Equality would be wrong: root legitimately carries
// entries for packages `.gaia/cli` does not install, such as its `chokidar`
// trust-policy exemption. But omitting the lists entirely leaves the escape hatch
// for the very setting beside them unguarded, so exempting a package in
// `.gaia/cli` alone would be invisible,
// which is the likeliest real drift (a maintainer trips the window on a fresh
// publish and exempts it locally). `.gaia/cli/pnpm-workspace.yaml` states the
// direction outright: each entry earns its place against that workspace's closure,
// "which root's is a superset of". So: every `.gaia/cli` entry must appear in root's.
const readHardeningSettings = (
  workspacePath: string
): {
  minimumReleaseAge: unknown;
  minimumReleaseAgeExclude: unknown[];
  minimumReleaseAgeStrict: unknown;
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
    minimumReleaseAgeStrict: settings.minimumReleaseAgeStrict,
    trustPolicy: settings.trustPolicy,
    trustPolicyExclude: asList(
      settings.trustPolicyExclude,
      workspacePath,
      'trustPolicyExclude'
    ),
  };
};

// Exemption entries compared as ATOMS rather than as literal strings, because
// pnpm does not store one exemption per entry. When a package needs more than
// one exempted version it merges them into a single union entry,
// `name@1.0.0 || 2.0.0`, and writes that back into `pnpm-workspace.yaml`
// itself. Root's dependency closure is a superset of `.gaia/cli`'s, so the two
// workspaces can legitimately need different version counts of one shared
// package, at which point root carries the union and `.gaia/cli` carries the
// single version. That is exactly the containment the two tests below permit,
// and literal membership cannot see it: `arrayContaining` looks for
// `semver@6.3.1`, finds only the union, and reds a required check over a valid
// configuration.
//
// The shape is pnpm's own (`expandPackageVersionSpecs`, the inverse of the
// `mergePackageVersionSpecs` that writes the union), mirrored here rather than
// imported: pnpm is this repo's `packageManager`, not a dependency of either
// workspace, so there is nothing to import from. Its parse is followed exactly,
// including the scope-aware `@` split that keeps `@scope/name` from splitting on
// its own leading `@`.
//
// One deliberate divergence, stated because a wrong normalization here is the
// same false-positive class this exists to fix: pnpm runs each version through
// `semver.valid`, which also folds spellings like `=1.2.3` and `v1.2.3` onto
// `1.2.3`. Trimming is all that pnpm's OWN output needs (its union separator
// leaves a leading space), and `semver` is a dependency of neither workspace. A
// hand-written `v1.2.3` on one side and `1.2.3` on the other would therefore
// still red. Add the dependency and use `semver.valid` if that ever happens; do
// not grow a second normalizer by hand, which is how the sibling exactness
// predicate accumulated four rounds of shape-by-shape repair.
//
// A name-only entry stays one atom, so exempting EVERY version of a package in
// `.gaia/cli` is not contained by exempting one version of it at root. That is
// asymmetric hardening and stays red, which is pnpm's reading too.
//
// A non-string entry is the exactness tests' finding, not this one's. It passes
// through unexpanded so it still compares, rather than being dropped into a
// silently smaller list on the containing side.
const exemptionAtoms = (list: unknown[]): unknown[] => {
  const atoms = new Set<unknown>();

  for (const entry of list) {
    if (typeof entry === 'string') {
      const atIndex =
        entry.startsWith('@') ? entry.indexOf('@', 1) : entry.indexOf('@');

      if (atIndex === -1) {
        atoms.add(entry);
      } else {
        const packageName = entry.slice(0, atIndex);

        for (const version of entry.slice(atIndex + 1).split('||')) {
          atoms.add(`${packageName}@${version.trim()}`);
        }
      }
    } else {
      atoms.add(entry);
    }
  }

  return [...atoms];
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

describe('rule-package resolution parity', () => {
  const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);
  const rootPackages = readRulePackageVersions(
    path.join(repoRoot, 'pnpm-lock.yaml')
  );
  const cliPackages = readRulePackageVersions(
    path.join(repoRoot, '.gaia', 'cli', 'pnpm-lock.yaml')
  );

  // Compared over the INTERSECTION, because a version comparison is only defined
  // for a package both lockfiles carry. The two populations are identical today,
  // measured rather than assumed: `@gaia-react/lint` depends on every provider it
  // exposes, so both workspaces resolve all of them regardless of which presets
  // each spreads, and the CLI's lockfile carries the storybook, playwright and
  // better-tailwindcss plugins even though its config omits those presets.
  //
  // So the intersection is not there to absorb a legitimate difference; it is
  // there to keep the comparison well-defined while the population test below
  // reds. Enforcing the populations rather than allowing for a gap is what stops
  // a provider LEAVING one workspace from silently narrowing coverage: it would
  // drop out of the intersection, take the assertion with it, and lint one
  // workspace without those rules with nothing red.
  const shared = sortedNames(rootPackages).filter((name) =>
    cliPackages.has(name)
  );

  const guarded = shared.filter((name) => !(name in PARITY_EXEMPT));

  const versionsOf = (
    packages: Map<string, string[]>
  ): Record<string, string> =>
    Object.fromEntries(
      guarded.map((name) => [name, (packages.get(name) ?? []).join(', ')])
    );

  // Every guarded package resolved more than once in one lockfile, as a map, so
  // the failure names the package and both of its versions rather than a count.
  const duplicates = (
    packages: Map<string, string[]>
  ): Record<string, string[]> =>
    Object.fromEntries(
      guarded
        .map((name) => [name, packages.get(name) ?? []] as const)
        .filter(([, versions]) => versions.length > 1)
    );

  // The population is asserted before anything is compared over it. Each of the
  // pattern's three arms is pinned by a live match, so dropping an arm reds here
  // rather than silently narrowing every comparison below: without this, deleting
  // the scoped arm would leave 25 of 30 packages guarded and every test green.
  test('the shared rule-bearing population is non-vacuous and every pattern arm matches', () => {
    expect(shared.length).toBeGreaterThanOrEqual(SHARED_FLOOR);
    expect(shared.some((name) => name.startsWith('@'))).toBe(true);
    expect(shared.some((name) => name.startsWith('eslint-plugin-'))).toBe(true);
    expect(shared.some((name) => name.startsWith('eslint-config-'))).toBe(true);
  });

  // Kept from the single-package guard this widened, because it is the one
  // subject whose ABSENCE is the interesting event: `typescript-eslint` is a
  // direct dependency of neither workspace and is stated by no manifest, so if
  // the transitive path through `eslint-config-airbnb-extended` ever goes, it
  // simply leaves both lockfiles and drops out of the intersection above with
  // every comparison still green.
  test('both lockfiles still resolve typescript-eslint at all', () => {
    expect(rootPackages.has('typescript-eslint')).toBe(true);
    expect(cliPackages.has('typescript-eslint')).toBe(true);
  });

  // Presence parity, which the version comparison structurally cannot see: a
  // provider that leaves one lockfile leaves the intersection with it, so its
  // assertion disappears rather than failing, and that workspace lints without
  // those rules exactly as silently as a version drift would have. The floor
  // above does not catch it either, since one provider leaving takes the count
  // from 30 to 29 and the floor is 20.
  //
  // Asserted as equality rather than allowing a one-sided provider, because a
  // one-sided one is itself the drift this file exists to report: it means a
  // workspace took a direct rule-provider dependency the other does not have,
  // which is a difference in what each considers an error. Making that a
  // deliberate test edit a reviewer sees is the same friction the hardening
  // floor above already applies to the release-age window.
  test('both lockfiles resolve the same set of rule-bearing packages', () => {
    expect(sortedNames(cliPackages)).toStrictEqual(sortedNames(rootPackages));
  });

  // Two copies of one rule provider in a single workspace is drift the parity
  // test cannot express: it would have to pick a version to compare, and picking
  // either asserts something untrue about the other.
  test('no guarded package resolves more than once in either lockfile', () => {
    expect(duplicates(rootPackages)).toStrictEqual({});
    expect(duplicates(cliPackages)).toStrictEqual({});
  });

  // An exemption that no longer names a shared package is exempting nothing, and
  // left alone it becomes a licence sitting in the file for whatever takes that
  // name later. This is the property that makes the broad pattern above safe:
  // the escape hatch cannot outlive its subject silently.
  //
  // Asserted over ENTRIES rather than keys so the stale entry's own stated reason
  // lands in the failure output. Reading the key alone would print a bare package
  // name and leave the maintainer to go find out why it was ever exempt, which is
  // exactly what a comment would have delivered and the reason the rationale is
  // data in the first place.
  test('every parity exemption still names a package both workspaces install', () => {
    expect(
      Object.fromEntries(
        Object.entries(PARITY_EXEMPT).filter(([name]) => !shared.includes(name))
      )
    ).toStrictEqual({});
  });

  // The guard proper. Compared as one record rather than per package so a
  // multi-package drift reports every offender at once with both versions,
  // instead of reddening on the alphabetically-first and hiding the rest.
  //
  // Repair: re-resolve the LAGGING workspace for the named package, from its own
  // root, and fix what the newly-arrived rules surface.
  test('both workspaces resolve the same version of every guarded rule-bearing package', () => {
    expect(versionsOf(cliPackages)).toStrictEqual(versionsOf(rootPackages));
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

  // `minimumReleaseAgeStrict` decides what the window above DOES on a violation,
  // so asserting the window without it pins a number whose consequence is still
  // free to change. With it false, a resolution that breaches the cutoff does not
  // fail: pnpm merges the offending `name@version` entries into
  // `minimumReleaseAgeExclude` and writes them back on an ordinary `install`,
  // `add`, or `update`, leaving the window in the file, every assertion above
  // green, and the immature version installed. Measured, not inferred: a sandbox
  // workspace at this same floor installs a same-day version and gains eight
  // exemptions it never asked for.
  //
  // Asserted `true` rather than merely non-false, because pnpm infers the value
  // when the key is absent; root's `pnpm-workspace.yaml` entry states why both
  // files set it explicitly anyway, and is the one copy of that reasoning. What
  // matters here is that an inferred value would make this guard read pnpm's
  // default back to itself instead of asserting the repository's own intent.
  const RELEASE_AGE_STRICT = true;

  test('the root workspace enforces the hardening floor', () => {
    expect(rootSettings.minimumReleaseAge).toBeGreaterThanOrEqual(
      FLOOR_MINUTES
    );
    expect(rootSettings.minimumReleaseAgeStrict).toBe(RELEASE_AGE_STRICT);
    expect(rootSettings.trustPolicy).toBe(TRUST_POLICY);
  });

  test('.gaia/cli enforces the hardening floor', () => {
    expect(cliSettings.minimumReleaseAge).toBeGreaterThanOrEqual(FLOOR_MINUTES);
    expect(cliSettings.minimumReleaseAgeStrict).toBe(RELEASE_AGE_STRICT);
    expect(cliSettings.trustPolicy).toBe(TRUST_POLICY);
  });

  test('.gaia/cli hardens on the same terms as the root workspace', () => {
    expect({
      minimumReleaseAge: cliSettings.minimumReleaseAge,
      minimumReleaseAgeStrict: cliSettings.minimumReleaseAgeStrict,
      trustPolicy: cliSettings.trustPolicy,
    }).toStrictEqual({
      minimumReleaseAge: rootSettings.minimumReleaseAge,
      minimumReleaseAgeStrict: rootSettings.minimumReleaseAgeStrict,
      trustPolicy: rootSettings.trustPolicy,
    });
  });

  // Containment, not equality. Root's lists are supersets by design, so equality
  // would fail on entries like root's `chokidar`; but an entry present ONLY in
  // `.gaia/cli` exempts a package from the setting above it in one workspace and
  // not the other,
  // which is the asymmetric hardening this describe block exists to catch. The
  // two sides are compared as atoms; see `exemptionAtoms` above for why literal
  // membership cannot see a legitimate containment.
  test('.gaia/cli exempts nothing from the release-age window that root does not', () => {
    expect(exemptionAtoms(rootSettings.minimumReleaseAgeExclude)).toEqual(
      expect.arrayContaining(
        exemptionAtoms(cliSettings.minimumReleaseAgeExclude)
      )
    );
  });

  // The four below are unit tests of `exemptionAtoms` over constructed entries,
  // not assertions about either live `pnpm-workspace.yaml`. Named for the helper
  // so they cannot be read as live parity coverage: the two tests that do assert
  // on the real files are the containment pair, above and below this block.
  test('exemptionAtoms: a merged union contains the single version it merged', () => {
    expect(exemptionAtoms(['semver@6.3.1 || 6.3.2'])).toEqual(
      expect.arrayContaining(exemptionAtoms(['semver@6.3.1']))
    );
  });

  // The scope-aware `@` split is the one part of pnpm's parse a plain
  // `indexOf('@')` gets wrong, and a SCOPED UNION is the only input shape where
  // the two spellings diverge: naive splitting yields the name-less atom
  // `@2.0.0`, which reds containment on a valid pair, reintroducing exactly the
  // false red this helper exists to remove. Without this test the branch is
  // unpinned and collapsing it leaves every other test green, which is not
  // hypothetical: a quality-review pass proposed that collapse on this very diff.
  test('exemptionAtoms: a scoped union splits on the version @, not the scope @', () => {
    expect(exemptionAtoms(['@scope/n@1.0.0 || 2.0.0'])).toEqual(
      expect.arrayContaining(exemptionAtoms(['@scope/n@2.0.0']))
    );
  });

  test('exemptionAtoms: a version only one side exempts is still drift', () => {
    expect(exemptionAtoms(['semver@6.3.1 || 6.3.2'])).not.toEqual(
      expect.arrayContaining(exemptionAtoms(['semver@6.3.3']))
    );
  });

  test('exemptionAtoms: exempting every version is not contained by exempting one', () => {
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
