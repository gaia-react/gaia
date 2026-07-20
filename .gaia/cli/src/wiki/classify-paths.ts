import {z} from 'zod';
/**
 * The path vocabulary `commit-classify`'s rules 6/7 discriminate on, declared
 * as a repo-configurable input instead of `app/**` literals.
 *
 * The classifier ships to adopters, whose product source really does live in
 * `app/**`, so the defaults below reproduce the previous hardcoded behavior
 * exactly. What the literals could not express is a repo whose source lives
 * anywhere else: GAIA's own clone keeps its product in `.gaia/` and `.claude/`
 * and touches `app/` in zero commits, so all three of rules 6/7's
 * discriminating branches were unreachable and every source commit fell
 * through to the fail-open default.
 *
 * Configured under `gaia.wikiClassify` in the repo's `package.json`, matching
 * the existing `gaia.updateDepsHold` convention. `package.json` is
 * adopter-owned and never rewritten by `/update-gaia`, so an adopter's tuning
 * survives an update; a `.gaia/` file would not.
 *
 * Every failure mode here falls back to the defaults. This is a cheap
 * heuristic pre-filter ahead of an expensive per-commit read, so a malformed
 * config must degrade to the shipped behavior rather than fail a sync.
 */
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {summarizeZodError} from '../schemas/zod-error.js';

export type ClassifyPaths = {
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

const DEFAULT_CLASSIFY_PATHS: ClassifyPaths = {
  inventoryPaths: [
    'app/components/',
    'app/hooks/',
    'app/pages/',
    'app/services/',
  ],
  sourcePaths: ['app/'],
  testPaths: [],
};

const PathListSchema = z.array(z.string().min(1));

const WikiClassifySchema = z.object({
  inventoryPaths: PathListSchema.optional(),
  sourcePaths: PathListSchema.optional(),
  testPaths: PathListSchema.optional(),
});

const PackageJsonSchema = z.object({
  gaia: z.object({wikiClassify: WikiClassifySchema.optional()}).optional(),
});

/**
 * Read `gaia.wikiClassify` from the repo root's `package.json`, falling back
 * to `DEFAULT_CLASSIFY_PATHS` for the whole object on any read or parse
 * failure and per key for anything the config omits.
 */
export const readClassifyPaths = (repoRoot: string): ClassifyPaths => {
  const target = path.join(repoRoot, 'package.json');

  if (!existsSync(target)) return DEFAULT_CLASSIFY_PATHS;

  let parsed: unknown;

  try {
    parsed = JSON.parse(readFileSync(target, 'utf8'));
  } catch {
    return DEFAULT_CLASSIFY_PATHS;
  }

  const result = PackageJsonSchema.safeParse(parsed);

  if (!result.success) {
    // Still fail open, but say so. A typo under `gaia.wikiClassify` would
    // otherwise degrade to the defaults in complete silence, which reads as
    // "my config does nothing" with no way to find out why.
    process.stderr.write(
      `commit-classify: ignoring malformed gaia.wikiClassify config. ${summarizeZodError(target, result.error)}\n`
    );

    return DEFAULT_CLASSIFY_PATHS;
  }

  const configured = result.data.gaia?.wikiClassify;

  if (configured === undefined) return DEFAULT_CLASSIFY_PATHS;

  return {
    inventoryPaths:
      configured.inventoryPaths ?? DEFAULT_CLASSIFY_PATHS.inventoryPaths,
    sourcePaths: configured.sourcePaths ?? DEFAULT_CLASSIFY_PATHS.sourcePaths,
    testPaths: configured.testPaths ?? DEFAULT_CLASSIFY_PATHS.testPaths,
  };
};
