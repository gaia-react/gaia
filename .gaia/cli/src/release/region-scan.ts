/**
 * Builds the region declaration list `gaia-maintainer release manifest`
 * embeds in `.gaia/manifest.json`, by scanning the SHIPPED file set (never a
 * raw tracked scan) for each `region-registry.ts` entry's marker pair.
 *
 * The distribution boundary matters here: a scan over `git ls-files` would
 * declare a maintainer-only path (withheld by `.gaia/release-exclude`) that
 * no adopter tree contains. `shippedFiles` is always the post-exclude,
 * post-classify file map `buildManifest` has already produced.
 */
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {scanRegion} from '../update/region-markers.js';
import {REGION_REGISTRY} from './region-registry.js';
import type {RegionRegistryEntry} from './region-registry.js';

export type RegionDeclaration = {
  endMarker: string;
  id: string;
  paths: string[];
  regenerate: {args: string[]; interpreter: string; operand: string};
  startMarker: string;
};

/**
 * The self-repairing message UAT-020's loud failure requires. The reachable
 * non-defect route into this branch is a maintainer removing a roster
 * member from `.gaia/audit-ci.yml` without stripping that member's region
 * from its agent definition, which would otherwise block every PR and
 * tag-time release with no way out. Names the path, the region id, and both
 * literal remedies.
 */
const unrewrittenMessage = (filePath: string, id: string): string =>
  `${filePath} carries the '${id}' region's marker pair, but that region's regeneration command does not rewrite it. Declaring a region nothing regenerates is worse than not declaring it. Fix by either: re-adding the corresponding member to .gaia/audit-ci.yml, or deleting the marker pair and its body from ${filePath}.`;

const malformedMessage = (
  filePath: string,
  id: string,
  reason: string
): string =>
  `${filePath} carries a malformed '${id}' region marker pair (${reason}). Fix the markers by hand and re-run.`;

const scanEntry = (
  repoRoot: string,
  shippedFiles: Readonly<Record<string, unknown>>,
  entry: RegionRegistryEntry
): RegionDeclaration => {
  const rewrites = entry.rewrites(repoRoot);
  const sortedKeys = Object.keys(shippedFiles).toSorted((a, b) =>
    a.localeCompare(b)
  );
  const paths: string[] = [];

  for (const key of sortedKeys) {
    const absPath = path.join(repoRoot, key);

    if (existsSync(absPath)) {
      const scan = scanRegion(
        readFileSync(absPath, 'utf8'),
        entry.startMarker,
        entry.endMarker
      );

      if (scan.kind === 'malformed') {
        throw new Error(malformedMessage(key, entry.id, scan.reason));
      }

      if (scan.kind === 'region') {
        if (!rewrites.has(key)) {
          throw new Error(unrewrittenMessage(key, entry.id));
        }

        paths.push(key);
      }
    }
  }

  return {
    endMarker: entry.endMarker,
    id: entry.id,
    paths,
    regenerate: {
      args: [...entry.args],
      interpreter: entry.interpreter,
      operand: entry.operand,
    },
    startMarker: entry.startMarker,
  };
};

/**
 * Builds the declaration list from the SHIPPED file map, never a raw tracked
 * scan. Throws when a shipped path carries a region's marker pair but is not
 * a path that region's regeneration command rewrites, or carries a
 * malformed marker pair.
 */
export const scanRegionDeclarations = (
  repoRoot: string,
  shippedFiles: Readonly<Record<string, unknown>>,
  registry: readonly RegionRegistryEntry[] = REGION_REGISTRY
): RegionDeclaration[] =>
  registry.map((entry) => scanEntry(repoRoot, shippedFiles, entry));
