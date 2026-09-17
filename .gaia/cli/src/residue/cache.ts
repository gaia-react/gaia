/**
 * The incremental attribution cache and the resumable triage cursor
 * (`.gaia/state-registry.json`, id `residual-triage-caches`):
 * `.gaia/local/cache/residual-attribution.json` and
 * `.gaia/local/cache/residual-cursor.json`.
 *
 * Both files are machine-local derived state under the gitignored
 * `.gaia/local/cache/` tree and degrade to empty on any read failure
 * (missing, unparseable, wrong shape): a cold cache reproduces the same
 * candidate list, more slowly, so neither is ever required for correctness.
 * A merged pull request's body stays editable after the gate ran, and editing
 * it is the natural repair for a key the tally reports in `malformed[]`. That
 * edit changes no SHA, so the head SHA cannot detect it: the attribution cache
 * keys each entry by pull-request number, head SHA, **and** a digest of the
 * body it attributed. A changed SHA or a changed body invalidates that entry
 * rather than trusting a stale attribution. An entry written before the digest
 * existed carries none, which compares unequal and re-attributes, so an older
 * cache degrades to a cold read rather than to a wrong answer.
 *
 * The digest only ever sees an edit on a pull request the incremental window
 * re-reads, since an entry nothing re-reads is never compared. `tally.ts`'s
 * `incrementalWindowStart` is what keeps the two in step, lowering the window
 * to cover every entry still carrying a malformed key. It does that on the
 * interactive run only: that widening is bounded by the age of the oldest
 * unrepaired malformed key rather than by how many exist, so `--count-only`,
 * which the statusline refresher calls on every tick, keeps the plain
 * high-water mark and lags a repair until the next interactive run.
 */
import {createHash} from 'node:crypto';
import {existsSync, mkdirSync, readFileSync, unlinkSync} from 'node:fs';
import path from 'node:path';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import type {AttributionResult} from './attribution.js';
import type {ResolutionKind} from './resolve.js';

const CACHE_DIR_SEGMENTS = ['.gaia', 'local', 'cache'];
const ATTRIBUTION_CACHE_FILE = 'residual-attribution.json';
const CURSOR_FILE = 'residual-cursor.json';

export type AttributionCache = {
  high_water_merged_at: null | string;
  prs: Record<string, CachedPrAttribution>;
  resolutions: Record<string, CachedResolution>;
  // Bumped independently of the dedup key's own v1 token: this cache's
  // keying is blind to a change in the grammar its stored attributions were
  // produced under, so a reader change that alters attribution bumps this.
  schema: 'v2';
};

export type CachedPrAttribution = {
  attribution: AttributionResult;
  bodyDigest: string;
  headRefOid: string;
  mergedAt: string;
};

// The digest an entry carries alongside its head SHA. Editing a merged pull
// request's body changes no SHA, so this is the only field that can see that
// edit.
export const attributionBodyDigest = (body: string): string =>
  createHash('sha256').update(body, 'utf8').digest('hex');

export type CachedResolution = {
  resolution: ResolutionKind;
  resolved_line_text: string;
};

export const emptyAttributionCache = (): AttributionCache => ({
  high_water_merged_at: null,
  prs: {},
  resolutions: {},
  schema: 'v2',
});

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

// Every consumer reads `entry.attribution.<field>` without a guard of its own,
// so validating the container alone lets a hand-edited or truncated cache
// through and turns the next property read into an uncaught TypeError. This
// command's contract is to exit 0 over a cache it cannot use, which means a
// bad entry has to be caught here, where the whole cache degrades to empty.
//
// The depth is set by where a consumer stops dereferencing, not by the type's
// own nesting: `compute-candidates.ts` reads two levels in, through
// `entry.key`, so an element check that stopped at the array would still hand
// it a `null` to dereference. `malformed[]` elements are spread rather than
// read field by field, so a record check is the whole of what they need; a
// non-record there costs a fieldless emitted row instead of a crash, which is
// why the two arrays are validated to different depths. Being stricter than a
// consumer needs is the safe direction anyway: an over-strict predicate costs
// a cold read, and a cold read is this cache's documented fallback.
const isValidResidueKey = (value: unknown): boolean =>
  isRecord(value) &&
  typeof value.class === 'string' &&
  typeof value.line === 'number' &&
  typeof value.path === 'string';

const isValidAttributedEntry = (value: unknown): boolean =>
  isRecord(value) &&
  typeof value.disposition === 'string' &&
  typeof value.failure_mode === 'string' &&
  typeof value.raw_key === 'string' &&
  isValidResidueKey(value.key);

// The resolution map is the `prs` map's sibling and takes the same treatment
// for the same reason: `makeCachingResolve` returns a cached value straight
// through to `compute-candidates.ts`, and `record-cmd.ts` reads its line text
// while appending an operator's dismissal, so a non-record here costs that
// dismissal rather than merely a stale read.
const isValidResolution = (value: unknown): boolean =>
  isRecord(value) &&
  typeof value.resolution === 'string' &&
  typeof value.resolved_line_text === 'string';

const isValidPrEntry = (value: unknown): value is CachedPrAttribution =>
  isRecord(value) &&
  typeof value.headRefOid === 'string' &&
  typeof value.mergedAt === 'string' &&
  isRecord(value.attribution) &&
  Array.isArray(value.attribution.entries) &&
  value.attribution.entries.every(isValidAttributedEntry) &&
  Array.isArray(value.attribution.keyless) &&
  Array.isArray(value.attribution.malformed) &&
  value.attribution.malformed.every(isRecord);

const isValidCache = (value: unknown): value is AttributionCache =>
  isRecord(value) &&
  value.schema === 'v2' &&
  (value.high_water_merged_at === null ||
    typeof value.high_water_merged_at === 'string') &&
  isRecord(value.prs) &&
  isRecord(value.resolutions) &&
  Object.values(value.prs).every(isValidPrEntry) &&
  Object.values(value.resolutions).every(isValidResolution);

const attributionCachePath = (repoRoot: string): string =>
  path.join(repoRoot, ...CACHE_DIR_SEGMENTS, ATTRIBUTION_CACHE_FILE);

export const readAttributionCache = (repoRoot: string): AttributionCache => {
  try {
    const parsed: unknown = JSON.parse(
      readFileSync(attributionCachePath(repoRoot), 'utf8')
    );

    return isValidCache(parsed) ? parsed : emptyAttributionCache();
  } catch {
    return emptyAttributionCache();
  }
};

export const writeAttributionCache = (
  repoRoot: string,
  cache: AttributionCache
): void => {
  const filePath = attributionCachePath(repoRoot);

  mkdirSync(path.dirname(filePath), {recursive: true});
  atomicWriteFileSync(filePath, `${JSON.stringify(cache)}\n`);
};

export const prCacheKey = String;

export const resolutionCacheKey = (
  sha: string,
  filePath: string,
  line: number
): string => `${sha}:${filePath}:${line}`;

// --- cursor ------------------------------------------------------------

export type ResidueCursor = {line: number; path: string; pr_number: number};

const isValidCursor = (value: unknown): value is ResidueCursor =>
  isRecord(value) &&
  typeof value.pr_number === 'number' &&
  typeof value.path === 'string' &&
  typeof value.line === 'number';

const cursorPath = (repoRoot: string): string =>
  path.join(repoRoot, ...CACHE_DIR_SEGMENTS, CURSOR_FILE);

export const readCursor = (repoRoot: string): null | ResidueCursor => {
  try {
    const parsed: unknown = JSON.parse(
      readFileSync(cursorPath(repoRoot), 'utf8')
    );

    return isValidCursor(parsed) ? parsed : null;
  } catch {
    return null;
  }
};

export const writeCursor = (repoRoot: string, cursor: ResidueCursor): void => {
  const filePath = cursorPath(repoRoot);

  mkdirSync(path.dirname(filePath), {recursive: true});
  atomicWriteFileSync(filePath, `${JSON.stringify(cursor)}\n`);
};

export const clearCursor = (repoRoot: string): void => {
  const filePath = cursorPath(repoRoot);

  if (!existsSync(filePath)) return;

  try {
    unlinkSync(filePath);
  } catch {
    // Best-effort: an already-gone cursor file is not a refusal.
  }
};
