/**
 * `gaia residue-tally [--count-only] [--attribute-only] [--cap N] [--no-cap] [--json]`
 *
 * The `/gaia-residue` deterministic primitive: an I/O shell around
 * `compute-candidates.ts`'s pure core, structured like `gaia harden-tally`
 * (`../harden/tally.ts`). Reads the merged pull-request corpus and the
 * tech-debt issue corpus through the injectable `CorpusProvider` seam,
 * attributes each body through the incremental attribution cache, suppresses
 * on the filer's three arms plus the dismissal store, resolves the emitted
 * batch's cited lines, and prints the frozen JSON contract to stdout.
 *
 * Always exits 0: a failed window read is reported through `gh_ok`, never a
 * non-zero exit, so the statusline refresher and the skill never treat a
 * network outage as a crash.
 */
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../util/repo-root.js';
import {attributeBody} from './attribution.js';
import type {AttributionResult} from './attribution.js';
import {
  attributionBodyDigest,
  prCacheKey,
  readAttributionCache,
  readCursor,
  resolutionCacheKey,
  writeAttributionCache,
} from './cache.js';
import type {AttributionCache, ResidueCursor} from './cache.js';
import {computeCandidates} from './compute-candidates.js';
import type {
  CandidateInputPr,
  EmittedCandidate,
  EmittedMalformed,
} from './compute-candidates.js';
import {resolveProvider} from './corpus.js';
import type {CorpusProvider, MergedPrsResult} from './corpus.js';
import {resolveCitedLine, unresolvedResolver} from './resolve.js';
import type {ResolveCandidate, ResolvedCandidate} from './resolve.js';
import {readKeepWindowDays, readStore} from './store.js';
import type {StoreSkip, SuppressionMode} from './store.js';
import {encodeToken} from './token.js';

const HELP_TEXT = `Usage: gaia residue-tally [options]

  Reads the merged pull-request corpus, attributes each body's keyed audit
  residue, suppresses a candidate the tech-debt filer would refuse or the
  dismissal store still suppresses, resolves the emitted batch's cited line,
  and prints the candidate list as JSON.

  --count-only      No head fetch, no git call. Every candidate carries
                     resolution "unresolved"; store suppression matches on
                     path and line alone (count_approximate: true).
  --attribute-only  Emit the per-pull-request attribution only: no
                     suppression, no resolution, no cache write.
  --cap N           Cap the emitted batch (default: GAIA_RESIDUE_CAP, or 10).
  --no-cap          Emit every survivor.
  --json            Accepted and ignored; JSON is the only output.

  Network failures are non-fatal: a failed window read emits gh_ok: false
  with an empty candidate list, and the command still exits 0.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const DEFAULT_CAP = 10;

type ParsedFlags = {
  attributeOnly: boolean;
  cap: null | number;
  countOnly: boolean;
};

type RunOptions = {
  cwd?: string;
  env?: NodeJS.ProcessEnv;
  now?: () => Date;
};

const parseCapEnvironment = (env: NodeJS.ProcessEnv): number => {
  const raw = env.GAIA_RESIDUE_CAP;

  if (raw === undefined) return DEFAULT_CAP;

  const parsed = Number.parseInt(raw, 10);

  return Number.isInteger(parsed) && parsed > 0 ? parsed : DEFAULT_CAP;
};

type MutableFlags = {
  attributeOnly: boolean;
  cap: number;
  countOnly: boolean;
  noCap: boolean;
};

// `--json` is accepted and ignored: JSON is the only output shape this emits.
const NOOP_TOKENS = new Set(['--json']);

const applyBooleanFlag = (token: string, flags: MutableFlags): boolean => {
  if (token === '--attribute-only') flags.attributeOnly = true;
  else if (token === '--count-only') flags.countOnly = true;
  else if (token === '--no-cap') flags.noCap = true;
  else return false;

  return true;
};

const parseCapValue = (rawValue: string | undefined): null | number => {
  const parsed =
    rawValue === undefined ? Number.NaN : Number.parseInt(rawValue, 10);

  return Number.isInteger(parsed) && parsed > 0 ? parsed : null;
};

const parseArgs = (
  argv: readonly string[],
  env: NodeJS.ProcessEnv
): {error: string} | {value: ParsedFlags} => {
  const flags: MutableFlags = {
    attributeOnly: false,
    cap: parseCapEnvironment(env),
    countOnly: false,
    noCap: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (
      token !== undefined &&
      (NOOP_TOKENS.has(token) || applyBooleanFlag(token, flags))
    ) {
      // handled above
    } else if (token === '--cap') {
      // Refuse rather than skip: advancing past an unparseable value swallows
      // whatever sits in the value position, so `--cap --count-only` would eat
      // the mode flag and silently run the resolving path `--count-only`
      // forbids. An unknown argument is already an error; so is this.
      const capValue = argv[index + 1];
      const parsedCap = parseCapValue(capValue);

      if (parsedCap === null) {
        // Two conditions reach this refusal and they need different words: a
        // value that is present and unusable, and no value at all. Naming the
        // absent one by interpolation shows the operator a JavaScript
        // sentinel where the cause is that they typed nothing.
        return {
          error:
            capValue === undefined ?
              '--cap needs a positive integer value'
            : `--cap needs a positive integer: ${capValue}`,
        };
      }

      flags.cap = parsedCap;
      index += 1;
    } else {
      return {error: `unknown argument: ${token}`};
    }
  }

  return {
    value: {
      attributeOnly: flags.attributeOnly,
      cap: flags.noCap ? null : flags.cap,
      countOnly: flags.countOnly,
    },
  };
};

// Deliberately an if-statement, not a `a > b ? a : b` reduce: these are ISO
// date strings, not numbers, and `Math.max` would coerce them to NaN.
const latestIsoTimestamp = (timestamps: readonly string[]): null | string => {
  let latest: null | string = null;

  for (const timestamp of timestamps) {
    if (latest === null || timestamp > latest) latest = timestamp;
  }

  return latest;
};

// The merge date the incremental read starts from. Normally the cache's
// high-water mark, but a body digest can only see an edit on a pull request
// the window still re-reads, and after one full run that window starts at the
// NEWEST merge: precisely the pull request least likely to need re-reading.
// Repairing a key this tally reported as malformed is an edit to an older
// merged body, so lower the start to the oldest merge still carrying one.
//
// State the cost honestly, because it is larger than it looks. `mergedPrs`
// takes a DATE, so the widening is not bounded by how many malformed keys
// exist but by the AGE of the oldest one: a single unrepaired key on the
// oldest merged pull request admits every pull request merged since it.
// Nothing retires a malformed entry either, since an unrepaired body keeps its
// digest and so keeps its `malformed[]`, so the window stays at that width on
// every run until the key is repaired. It is wide and persistent, not wide and
// transient.
//
// That is why `--count-only` never widens. The statusline refresher calls it
// on every tick, and a permanently full-corpus `gh pr list --json body` there
// is exactly the standing cost the incremental cache exists to prevent. The
// price of excluding it is bounded and one-directional: between a repair and
// the next interactive run, the refresher's counts omit the repaired entry, so
// the nudge under-reports rather than inventing work. The interactive run pays
// the wide read, sees the repair, and rewrites the cache the refresher then
// reads.
//
// Only malformed keys earn the widening at all. Any other body edit is equally
// invisible on an older merge, but nothing tells an operator to make one.
const incrementalWindowStart = (
  cache: AttributionCache,
  countOnly: boolean
): null | string => {
  const highWater = cache.high_water_merged_at;

  if (highWater === null || countOnly) return highWater;

  let oldestMalformed: null | string = null;

  for (const entry of Object.values(cache.prs)) {
    const carriesMalformed = entry.attribution.malformed.length > 0;

    if (
      carriesMalformed &&
      (oldestMalformed === null || entry.mergedAt < oldestMalformed)
    ) {
      oldestMalformed = entry.mergedAt;
    }
  }

  if (oldestMalformed === null) return highWater;

  return oldestMalformed < highWater ? oldestMalformed : highWater;
};

const resolveRoot = (cwd: string): string => {
  try {
    return resolveRepoRoot(cwd);
  } catch {
    return cwd;
  }
};

type EmitCursor = null | {
  line: number;
  path: string;
  pr_number: number;
  token: string;
};

const cursorForEmit = (cursor: null | ResidueCursor): EmitCursor =>
  cursor === null ? null : {...cursor, token: encodeToken(cursor)};

type TallyEmit = {
  aged_candidate_count: number;
  candidate_count: number;
  candidates: EmittedCandidate[];
  cap: number;
  count_approximate: boolean;
  cursor: EmitCursor;
  gh_ok: boolean;
  malformed: EmittedMalformed[];
  remaining_count: number;
  schema: 'v1';
  store_skipped: StoreSkip[];
  total_keyed_count: number;
  window: WindowEmit;
};

type WindowEmit = {
  high_water_merged_at: null | string;
  mode: 'full' | 'incremental';
  truncated: boolean;
};

const printEmit = (emit: TallyEmit): void => {
  process.stdout.write(`${JSON.stringify(emit)}\n`);
};

// The shared shape of the two `gh_ok: false` arms: a failed window read (no
// corpus at all) and a failed issue read (attribution succeeded, but nothing
// can be safely suppressed). Callers vary only `total_keyed_count`.
const buildFailureEmit = (params: {
  cap: number;
  countOnly: boolean;
  cursor: EmitCursor;
  storeSkipped: StoreSkip[];
  totalKeyedCount: number;
  window: WindowEmit;
}): TallyEmit => ({
  aged_candidate_count: 0,
  candidate_count: 0,
  candidates: [],
  cap: params.cap,
  count_approximate: params.countOnly,
  cursor: params.cursor,
  gh_ok: false,
  malformed: [],
  remaining_count: 0,
  schema: 'v1',
  store_skipped: params.storeSkipped,
  total_keyed_count: params.totalKeyedCount,
  window: params.window,
});

const runAttributeOnly = (provider: CorpusProvider): number => {
  const mergedPrsResult = provider.mergedPrs(null);

  if (!mergedPrsResult.ok) {
    process.stdout.write(
      `${JSON.stringify({bodies: [], gh_ok: false, schema: 'v1'})}\n`
    );

    return EXIT_CODES.OK;
  }

  const bodies = mergedPrsResult.prs.map((pr) => {
    const attribution: AttributionResult = attributeBody(pr.body);

    return {
      entries: attribution.entries,
      keyless: attribution.keyless,
      keyless_count: attribution.keyless_count,
      malformed: attribution.malformed,
      pr_number: pr.number,
    };
  });

  process.stdout.write(
    `${JSON.stringify({bodies, gh_ok: true, schema: 'v1'})}\n`
  );

  return EXIT_CODES.OK;
};

// Wraps the real resolver with the attribution cache's permanent
// `<sha>:<path>:<line>` result cache (mutates `cache.resolutions` in place;
// the caller persists it once at the end of the run).
const makeCachingResolve =
  (
    cache: AttributionCache,
    provider: CorpusProvider
  ): ((candidate: ResolveCandidate) => ResolvedCandidate) =>
  (candidate) => {
    const key = resolutionCacheKey(
      candidate.headSha,
      candidate.path,
      candidate.line
    );
    const cached = cache.resolutions[key];

    if (cached !== undefined) return cached;

    const resolved = resolveCitedLine(provider, candidate);

    cache.resolutions[key] = resolved;

    return resolved;
  };

// Merges an incremental `mergedPrs` read onto the existing cache: seeds with
// every previously-cached pull request, then overlays the freshly-read ones,
// reusing a cached attribution only when the head SHA **and** the digest of
// the body that attribution was computed from both still match. The SHA alone
// is not enough: editing a merged pull request's body is the natural repair
// for a key reported in `malformed[]`, and that edit moves no SHA. The digest
// is compared only for the pull requests this read returned, so seeing such an
// edit depends on `incrementalWindowStart` having lowered the window far
// enough to return them.
const mergeAttributionCache = (
  cache: AttributionCache,
  mergedPrsResult: MergedPrsResult & {ok: true}
): {prs: CandidateInputPr[]; updatedCache: AttributionCache} => {
  const updatedCache: AttributionCache = {...cache, prs: {...cache.prs}};
  const prMap = new Map<number, CandidateInputPr>();

  for (const [key, entry] of Object.entries(cache.prs)) {
    const prNumber = Number.parseInt(key, 10);

    if (Number.isInteger(prNumber)) {
      prMap.set(prNumber, {
        attribution: entry.attribution,
        headRefOid: entry.headRefOid,
        mergedAt: entry.mergedAt,
        number: prNumber,
      });
    }
  }

  for (const pr of mergedPrsResult.prs) {
    const existing = updatedCache.prs[prCacheKey(pr.number)];
    const digest = attributionBodyDigest(pr.body);
    const attribution =
      existing?.headRefOid === pr.headRefOid && existing.bodyDigest === digest ?
        existing.attribution
      : attributeBody(pr.body);

    updatedCache.prs[prCacheKey(pr.number)] = {
      attribution,
      bodyDigest: digest,
      headRefOid: pr.headRefOid,
      mergedAt: pr.mergedAt,
    };

    prMap.set(pr.number, {
      attribution,
      headRefOid: pr.headRefOid,
      mergedAt: pr.mergedAt,
      number: pr.number,
    });
  }

  const prs = [...prMap.values()];
  const mergedAts = prs.map((pr) => pr.mergedAt);
  const highWaterMerged = latestIsoTimestamp(mergedAts);

  updatedCache.high_water_merged_at =
    highWaterMerged ?? cache.high_water_merged_at;

  return {prs, updatedCache};
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  const [first] = argv;

  if (first !== undefined && HELP_TOKENS.has(first)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const env = options.env ?? process.env;
  const cwd = options.cwd ?? process.cwd();
  const now = (options.now ?? (() => new Date()))();

  const parsed = parseArgs(argv, env);

  if ('error' in parsed) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.error,
      subcommand: 'residue-tally',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const provider = resolveProvider(cwd, env);

  if (parsed.value.attributeOnly) return runAttributeOnly(provider);

  const repoRoot = resolveRoot(cwd);
  const keepWindowDays = readKeepWindowDays(env);
  const {records: storeRecords, skipped: storeSkipped} = readStore(repoRoot);
  const cursor = readCursor(repoRoot);
  const cache = readAttributionCache(repoRoot);
  const emitCursor = cursorForEmit(cursor);
  const capForEmpty = parsed.value.cap ?? 0;

  const mergedPrsResult = provider.mergedPrs(
    incrementalWindowStart(cache, parsed.value.countOnly)
  );

  if (!mergedPrsResult.ok) {
    printEmit(
      buildFailureEmit({
        cap: capForEmpty,
        countOnly: parsed.value.countOnly,
        cursor: emitCursor,
        storeSkipped,
        totalKeyedCount: 0,
        window: {
          high_water_merged_at: cache.high_water_merged_at,
          mode: cache.high_water_merged_at === null ? 'full' : 'incremental',
          truncated: false,
        },
      })
    );

    return EXIT_CODES.OK;
  }

  const {prs, updatedCache} = mergeAttributionCache(cache, mergedPrsResult);
  const totalKeyedCount = prs.reduce(
    (sum, pr) => sum + pr.attribution.entries.length,
    0
  );
  const windowEmit: WindowEmit = {
    high_water_merged_at: updatedCache.high_water_merged_at,
    mode: cache.high_water_merged_at === null ? 'full' : 'incremental',
    truncated: mergedPrsResult.truncated,
  };

  const issuesResult = provider.techDebtIssues();

  if (!issuesResult.ok) {
    writeAttributionCache(repoRoot, updatedCache);
    printEmit(
      buildFailureEmit({
        cap: capForEmpty,
        countOnly: parsed.value.countOnly,
        cursor: emitCursor,
        storeSkipped,
        totalKeyedCount,
        window: windowEmit,
      })
    );

    return EXIT_CODES.OK;
  }

  const suppressionMode: SuppressionMode =
    parsed.value.countOnly ? 'coordinate-only' : 'content-bound';
  const resolve =
    parsed.value.countOnly ?
      unresolvedResolver
    : makeCachingResolve(updatedCache, provider);

  const result = computeCandidates({
    cap: parsed.value.cap ?? Number.MAX_SAFE_INTEGER,
    cursor,
    issues: issuesResult.issues,
    keepWindowDays,
    now,
    prs,
    resolve,
    storeRecords,
    suppressionMode,
  });

  writeAttributionCache(repoRoot, updatedCache);

  printEmit({
    aged_candidate_count: result.aged_candidate_count,
    candidate_count: result.candidate_count,
    candidates: result.candidates,
    cap: parsed.value.cap ?? result.candidate_count,
    count_approximate: parsed.value.countOnly,
    cursor: emitCursor,
    gh_ok: true,
    malformed: result.malformed,
    remaining_count: result.remaining_count,
    schema: 'v1',
    store_skipped: storeSkipped,
    total_keyed_count: result.total_keyed_count,
    window: windowEmit,
  });

  return EXIT_CODES.OK;
};
