import {load as parseYaml} from 'js-yaml';
/**
 * Hand-authored registry of GAIA's generated regions: which shipped files
 * carry a machine-generated, marker-delimited region, and the command that
 * regenerates it. `region-scan.ts` reads this list and cross-references it
 * against the shipped file set at build time; nothing else in the build
 * infers a region's existence.
 *
 * The marker pair and the regeneration command are hand-authored here,
 * because scraping an executable command out of a file would be fragile and
 * a needless execution surface. Each entry's `rewrites` path SET, by
 * contrast, is computed from the same source of truth the regeneration
 * command itself reads, so a hand-maintained path list (the second list that
 * drifts from reality) never exists.
 */
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';

export type RegionRegistryEntry = {
  /** Extra argv elements after the operand. Empty today. */
  args: readonly string[];
  endMarker: string;
  /** Stable declaration id. A region needing different markers is a NEW id. */
  id: string;
  /** Fixed interpreter the runner supplies, so no shipped script's executable bit is load-bearing. */
  interpreter: string;
  /** Repo-relative path to the shipped program that regenerates this region. */
  operand: string;
  /**
   * Every repo-relative path this region's regeneration command rewrites, for
   * the given repo root. The build refuses to declare a shipped marker-bearing
   * path this set does not contain.
   */
  rewrites: (repoRoot: string) => ReadonlySet<string>;
  startMarker: string;
};

/**
 * The exact path set `.gaia/scripts/write-audit-remits.sh` rewrites: one
 * agent definition per Code Audit Team roster member. Reads
 * `.gaia/audit-ci.yml` directly (only `auditors[].name` is needed) rather
 * than going through the bash `--emit-roster` reader.
 *
 * Returns an empty set when the roster is absent, unparseable, or shaped
 * unexpectedly. The caller (`region-scan.ts`'s declare-or-throw check) turns
 * an empty set into a loud build failure for any shipped path that carries
 * the region markers, so a silently-empty set here can never produce a
 * silently-empty declaration.
 */
export const rosterAgentPaths = (repoRoot: string): ReadonlySet<string> => {
  const rosterPath = path.join(repoRoot, '.gaia/audit-ci.yml');

  if (!existsSync(rosterPath)) return new Set();

  let parsed: unknown;

  try {
    parsed = parseYaml(readFileSync(rosterPath, 'utf8'));
  } catch {
    return new Set();
  }

  const auditors =
    typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed) ?
      (parsed as {auditors?: unknown}).auditors
    : undefined;

  if (!Array.isArray(auditors)) return new Set();

  const names = auditors
    .map((entry) =>
      typeof entry === 'object' && entry !== null && !Array.isArray(entry) ?
        (entry as {name?: unknown}).name
      : undefined
    )
    .filter((name): name is string => typeof name === 'string');

  return new Set(names.map((name) => `.claude/agents/${name}.md`));
};

export const REGION_REGISTRY: readonly RegionRegistryEntry[] = [
  {
    args: [],
    endMarker: '<!-- gaia:audit-remit:end -->',
    id: 'audit-remit',
    interpreter: 'bash',
    operand: '.gaia/scripts/write-audit-remits.sh',
    rewrites: rosterAgentPaths,
    startMarker: '<!-- gaia:audit-remit:start -->',
  },
];
