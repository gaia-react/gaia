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
 * to cover every entry still carrying a malformed key.
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
  schema: 'v1';
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
  schema: 'v1',
});

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

const isValidCache = (value: unknown): value is AttributionCache =>
  isRecord(value) &&
  value.schema === 'v1' &&
  isRecord(value.prs) &&
  isRecord(value.resolutions);

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
