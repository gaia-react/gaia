/**
 * The path vocabulary `commit-classify`'s rules 6/7 discriminate on, declared
 * as a repo-configurable input instead of `app/**` literals.
 *
 * The classifier ships to adopters, whose product source lives in the frontend
 * package's `app/**`, so the defaults come from that package's descriptor.
 * What the literals could not express is a repo whose source lives
 * anywhere else: GAIA's own clone keeps its product in `.gaia/` and `.claude/`
 * and touches `app/` in zero commits, so every one of rules 6/7's
 * discriminating branches was unreachable and every source commit fell
 * through to the fail-open default.
 *
 * Configured under `gaia.wikiClassify` in the repo's `package.json`, matching
 * the existing `gaia.updateDepsHold` convention. `package.json` is
 * adopter-owned and never rewritten by `/update-gaia`, so an adopter's tuning
 * survives an update; a `.gaia/` file would not.
 *
 * Every `gaia.wikiClassify` failure mode falls back to the defaults; a registry
 * or descriptor that cannot load throws instead, because the defaults
 * themselves come from it. This is a cheap
 * heuristic pre-filter ahead of an expensive per-commit read, so a malformed
 * config must degrade to the shipped behavior rather than fail a sync.
 */
import {z} from 'zod';
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {summarizeZodError} from '../schemas/zod-error.js';
import {loadPackages} from '../util/packages.js';

export type ClassifyPaths = {
  /** Paths whose change alters a flow (routing, middleware, sessions, i18n). */
  flowPaths: readonly string[];
  /**
   * Paths whose contents are mechanically discoverable (Serena indexes them),
   * so a commit touching only these needs no wiki narration.
   *
   * GAIA's own clone deliberately leaves this at the default while overriding
   * the other two: it has no directory of that shape. The key exists because
   * the branch is load-bearing for the React template it ships, not on the
   * chance someone might want it.
   */
  inventoryPaths: readonly string[];
  /** Paths that hold product source, as opposed to tooling or plumbing. */
  sourcePaths: readonly string[];
  /**
   * Paths that hold tests but whose filenames do not carry `.test.`, such as
   * a bats suite directory. Additive to the `.test.` filename check.
   */
  testPaths: readonly string[];
};

/**
 * The defaults, from the frontend package's descriptor `wiki` block joined with
 * its registry path, so the vocabulary follows wherever the app lives. Throws
 * the `gaia-packages:` message when the registry or descriptor cannot be
 * loaded: classifying against a guessed layout is a silent miss.
 */
const defaultClassifyPaths = (repoRoot: string): ClassifyPaths => {
  const loaded = loadPackages(repoRoot);

  if (!loaded.ok) {
    throw new Error(loaded.message);
  }
  const frontend = loaded.packages.find((entry) => entry.name === 'frontend');

  if (frontend === undefined) {
    throw new Error(
      'gaia-packages: no package named "frontend" is registered. Next step: add it to .gaia/packages.json.'
    );
  }
  const prefixed = (paths: readonly string[]): string[] =>
    paths.map((entry) =>
      frontend.path === '.' ? entry : `${frontend.path}/${entry}`
    );

  return {
    flowPaths: prefixed(frontend.descriptor.wiki.flowPaths),
    inventoryPaths: prefixed(frontend.descriptor.wiki.inventoryPaths),
    sourcePaths: prefixed(frontend.descriptor.wiki.sourcePaths),
    testPaths: [],
  };
};

const PathListSchema = z.array(z.string().min(1));

// `sourcePaths` alone must be non-empty. Omitting the key falls back to the
// default, but setting it to `[]` would match no file at all, so every source
// commit would land on rule 7's fail-open tail: the exact inertness this
// module exists to prevent, reachable through the config surface and silent
// below the health signal's minimum sample. Rejecting it here falls back to
// the defaults and says so on stderr.
//
// Deliberately not applied to the other two: `testPaths: []` is the shipped
// default, and `inventoryPaths: []` is a legitimate way to turn the inventory
// skip off.
const SourcePathListSchema = PathListSchema.min(1);

const WikiClassifySchema = z.object({
  inventoryPaths: PathListSchema.optional(),
  sourcePaths: SourcePathListSchema.optional(),
  testPaths: PathListSchema.optional(),
});

const PackageJsonSchema = z.object({
  gaia: z.object({wikiClassify: WikiClassifySchema.optional()}).optional(),
});

/**
 * Read `gaia.wikiClassify` from the repo root's `package.json`, falling back
 * to `defaults` for the whole object on any read or parse
 * failure and per key for anything the config omits.
 */
export const readClassifyPaths = (repoRoot: string): ClassifyPaths => {
  const defaults = defaultClassifyPaths(repoRoot);
  const target = path.join(repoRoot, 'package.json');

  if (!existsSync(target)) return defaults;

  let parsed: unknown;

  try {
    parsed = JSON.parse(readFileSync(target, 'utf8'));
  } catch {
    return defaults;
  }

  const result = PackageJsonSchema.safeParse(parsed);

  if (!result.success) {
    // Still fail open, but say so. A typo under `gaia.wikiClassify` would
    // otherwise degrade to the defaults in complete silence, which reads as
    // "my config does nothing" with no way to find out why.
    process.stderr.write(
      `commit-classify: ignoring malformed gaia.wikiClassify config. ${summarizeZodError(target, result.error)}\n`
    );

    return defaults;
  }

  const configured = result.data.gaia?.wikiClassify;

  if (configured === undefined) return defaults;

  return {
    flowPaths: defaults.flowPaths,
    inventoryPaths: configured.inventoryPaths ?? defaults.inventoryPaths,
    sourcePaths: configured.sourcePaths ?? defaults.sourcePaths,
    testPaths: configured.testPaths ?? defaults.testPaths,
  };
};
