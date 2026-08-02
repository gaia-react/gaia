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
import {load as parseYaml} from 'js-yaml';
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
   *
   * An implementation **throws** when the source it derives that set from
   * exists but cannot be read or parsed: the build cannot know what the region
   * rewrites, and the only caller can do nothing but abort. The empty set is
   * reserved for a source that is legitimately absent, or present and
   * recognized as declaring nothing. Returning it for a broken source instead
   * makes those two indistinguishable, and the caller then blames whichever
   * marker-bearing file it reaches first.
   */
  rewrites: (repoRoot: string) => ReadonlySet<string>;
  startMarker: string;
};

const ROSTER_RELATIVE_PATH = '.gaia/audit-ci.yml';

/**
 * A roster that exists but cannot be turned into a path set at all.
 *
 * Deliberately offers neither of `region-scan.ts`'s `unrewrittenMessage`
 * remedies. Re-adding a member to the roster, or deleting a region's marker
 * pair, fixes neither a syntax error nor an IO failure, and being handed one
 * of those two confident-but-wrong instructions is the misdirection this
 * message exists to prevent. `cause` goes last because js-yaml's text ends in
 * a multi-line source excerpt.
 */
const brokenRosterMessage = (problem: string, cause: string): string =>
  `${ROSTER_RELATIVE_PATH} ${problem}. The Code Audit Team agent definitions are read from that roster, so the release manifest cannot be built until the file itself is fixed; this is not a roster-membership or marker problem. ${cause}`;

const causeOf = (error: unknown): string =>
  error instanceof Error ? error.message : String(error);

/**
 * The exact path set `.gaia/scripts/write-audit-remits.sh` rewrites: one
 * agent definition per Code Audit Team roster member. Reads
 * `.gaia/audit-ci.yml` directly (only `auditors[].name` is needed) rather
 * than going through the bash `--emit-roster` reader.
 *
 * An **absent** roster returns an empty set: declaring no auditors is a
 * legitimate state, and `region-scan.ts`'s declare-or-throw check turns the
 * empty set into a loud failure for any shipped path that carries the region
 * markers. A roster that **exists and cannot be read** is a different state
 * and throws instead. Collapsing the two into one empty set makes them
 * indistinguishable, and an unparseable roster then reaches the maintainer as
 * `unrewrittenMessage`, whose remedies are to edit roster membership or delete
 * a marker pair, for a YAML syntax error a few lines up in that same file.
 * Loud is not the same as correctly directed.
 *
 * A roster that parses into a shape this reader does not recognize (no
 * `auditors` key, or one that is not a list) still returns an empty set. That
 * is the nearest YAML spelling of "lists no auditors", and making it fatal is
 * a separate decision from this one.
 */
export const rosterAgentPaths = (repoRoot: string): ReadonlySet<string> => {
  const rosterPath = path.join(repoRoot, ROSTER_RELATIVE_PATH);

  if (!existsSync(rosterPath)) return new Set();

  let contents: string;

  try {
    contents = readFileSync(rosterPath, 'utf8');
  } catch (error) {
    // Read and parse are caught separately because their messages are not
    // interchangeable: calling an EISDIR or EACCES a syntax error would be a
    // smaller copy of the misdirection above. EISDIR in particular names no
    // path of its own, so the prefix has to carry it.
    throw new Error(brokenRosterMessage('could not be read', causeOf(error)));
  }

  let parsed: unknown;

  try {
    parsed = parseYaml(contents);
  } catch (error) {
    throw new Error(brokenRosterMessage('is not valid YAML', causeOf(error)));
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
