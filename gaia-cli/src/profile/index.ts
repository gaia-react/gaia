/**
 * `gaia telemetry compute-profile` subcommand handler.
 *
 * Behavior (UAT-026 chain trigger relies on the silent-success short-circuit):
 *   1. Read mentorship config. If !enabled → exit 0 silently (UAT-040).
 *   2. Read trailing 30-day mentorship event window.
 *   3. Run all three pattern detectors.
 *   4. Resolve each pattern → adaptation, computing fade and active/faded status.
 *   5. Atomically write profile.md (UAT-035, UAT-036).
 *   6. If config.analytics.enabled, write today's analytics report.
 *
 * Pattern strengths < threshold (or sample_count < min) are reported in
 * profile.md's "Pattern detail" section but produce no active adaptations.
 * v1.0.0 ships wired-but-inert: with no real-usage events, every area is
 * below threshold and the file lists "(none)" under active patterns and
 * adaptations (UAT-029 path).
 */
import {
  generateAnalyticsReport,
  writeAnalyticsReport,
} from '../analytics/index.js';
import {EXIT_CODES} from '../exit.js';
import {readMentorshipConfig} from '../mentorship/config.js';
import {structuredError} from '../stderr.js';
import {resolveStorageRoots} from '../storage/index.js';
import type {StorageRoots} from '../storage/index.js';
import {PATTERN_TO_ADAPTATION} from './adaptation-map.js';
import type {AdaptationId, PatternId} from './adaptation-map.js';
import {runAllPatternDetectors} from './patterns/index.js';
import type {PatternResult} from './patterns/types.js';
import {readMentorshipEvents} from './reader.js';
import type {MentorshipEvent} from './reader.js';
import {fadeFactor, RATE_TARGET, STRENGTH_THRESHOLD} from './strength.js';
import {atomicWriteProfile, renderProfile} from './writer.js';
import type {AdaptationRecord} from './writer.js';

const WINDOW_DAYS = 30;
const RECENT_WINDOW_DAYS = 7;
const FADE_ELIGIBLE_AGE_DAYS = 7;
const MS_PER_DAY = 86_400_000;

type RunOptions = {
  // Test seam: callers that want a deterministic timestamp pass `now`.
  now?: Date;
  roots?: StorageRoots;
};

const parseTimestampMs = (timestamp: string): number => {
  const parsed = Date.parse(timestamp);

  return Number.isNaN(parsed) ? 0 : parsed;
};

/**
 * For a fired pattern, compute the effective strength after applying the
 * fade curve. Fade is only considered when the pattern's events span ≥1
 * week of history (UAT-031: "active for 3 weeks").
 *
 * `improvement` is `historic_rate - recent_rate` — positive means the
 * user is getting better. We map strengths back to underlying rate scale
 * (strength = min(1, rate / RATE_TARGET) → rate ≈ strength * RATE_TARGET).
 */
const computeAdaptationRecord = (args: {
  pattern: PatternResult;
  recentMatchingPattern?: PatternResult;
  windowAgeDays: number;
}): AdaptationRecord | null => {
  const {pattern, recentMatchingPattern, windowAgeDays} = args;

  if (pattern.strength === null) return null;
  const adaptationId: AdaptationId = PATTERN_TO_ADAPTATION[pattern.pattern_id];
  const fadeIsEligible =
    windowAgeDays >= FADE_ELIGIBLE_AGE_DAYS &&
    recentMatchingPattern !== undefined;
  const recentStrength = recentMatchingPattern?.strength ?? 0;
  const improvement =
    fadeIsEligible ? (pattern.strength - recentStrength) * RATE_TARGET : 0;
  const fade = fadeFactor(improvement);
  const effective = pattern.strength * fade;

  return {
    adaptation_id: adaptationId,
    area_tag: pattern.area_tag,
    effective_strength: effective,
    fade_factor: fade,
    pattern_id: pattern.pattern_id,
    raw_strength: pattern.strength,
    sample_count: pattern.sample_count,
    status: effective >= STRENGTH_THRESHOLD ? 'active' : 'faded',
  };
};

const oldestEventAgeDays = (
  events: readonly MentorshipEvent[],
  now: Date
): number => {
  if (events.length === 0) return 0;
  const stamps = events
    .map((event) => parseTimestampMs(event.timestamp))
    .filter((value) => value > 0);

  if (stamps.length === 0) return 0;
  const oldestMs = Math.min(...stamps);

  return Math.floor((now.getTime() - oldestMs) / MS_PER_DAY);
};

const eventsWithinRecentWindow = (
  events: readonly MentorshipEvent[],
  now: Date
): MentorshipEvent[] => {
  const cutoffMs = now.getTime() - RECENT_WINDOW_DAYS * MS_PER_DAY;

  return events.filter(
    (event) => parseTimestampMs(event.timestamp) >= cutoffMs
  );
};

const findMatchingPattern = (
  patterns: readonly PatternResult[],
  patternId: PatternId,
  area: string
): PatternResult | undefined =>
  patterns.find(
    (candidate) =>
      candidate.pattern_id === patternId && candidate.area_tag === area
  );

const buildAdaptationRecords = (args: {
  patterns: readonly PatternResult[];
  recentPatterns: readonly PatternResult[];
  windowAgeDays: number;
}): AdaptationRecord[] => {
  const {patterns, recentPatterns, windowAgeDays} = args;
  const fired = patterns.filter(
    (pattern) =>
      pattern.strength !== null && pattern.strength >= STRENGTH_THRESHOLD
  );

  return fired
    .map((pattern) =>
      computeAdaptationRecord({
        pattern,
        recentMatchingPattern: findMatchingPattern(
          recentPatterns,
          pattern.pattern_id,
          pattern.area_tag
        ),
        windowAgeDays,
      })
    )
    .filter((record): record is AdaptationRecord => record !== null);
};

type CoreResult = {
  adaptations: AdaptationRecord[];
  events: MentorshipEvent[];
  patterns: PatternResult[];
};

const computeProfileCore = async (args: {
  now: Date;
  roots: StorageRoots;
}): Promise<CoreResult> => {
  const {now, roots} = args;
  const events = await readMentorshipEvents({
    now,
    roots,
    windowDays: WINDOW_DAYS,
  });
  const patterns = runAllPatternDetectors({events, windowDays: WINDOW_DAYS});
  const recentPatterns = runAllPatternDetectors({
    events: eventsWithinRecentWindow(events, now),
    windowDays: RECENT_WINDOW_DAYS,
  });
  const adaptations = buildAdaptationRecords({
    patterns,
    recentPatterns,
    windowAgeDays: oldestEventAgeDays(events, now),
  });

  return {adaptations, events, patterns};
};

const renderAndWriteProfile = async (args: {
  core: CoreResult;
  now: Date;
  roots: StorageRoots;
}): Promise<void> => {
  const {core, now, roots} = args;
  const profileContents = renderProfile({
    adaptations: core.adaptations,
    generatedAt: now,
    mentorshipEnabled: true,
    patterns: core.patterns,
    windowDays: WINDOW_DAYS,
  });
  await atomicWriteProfile(roots.profilePath, profileContents);
};

const writeAnalytics = async (args: {
  core: CoreResult;
  now: Date;
  roots: StorageRoots;
}): Promise<void> => {
  const {core, now, roots} = args;
  const report = await generateAnalyticsReport({
    generatedAt: now,
    patternResults: core.patterns,
    roots,
    windowDays: WINDOW_DAYS,
  });
  await writeAnalyticsReport({generatedAt: now, report, roots});
};

type StepOutcome<T> = {exitCode: number; ok: false} | {ok: true; value: T};

const errorMessage = (error: unknown): string =>
  error instanceof Error ? error.message : String(error);

const safeReadConfig = (
  roots: StorageRoots
): StepOutcome<ReturnType<typeof readMentorshipConfig>> => {
  try {
    return {ok: true, value: readMentorshipConfig(roots)};
  } catch (error) {
    structuredError({
      code: 'config_invalid',
      message: errorMessage(error),
      path: 'mentorship.json',
    });

    return {exitCode: EXIT_CODES.CONFIG_INVALID, ok: false};
  }
};

const safeComputeCore = async (args: {
  now: Date;
  roots: StorageRoots;
}): Promise<StepOutcome<CoreResult>> => {
  try {
    return {ok: true, value: await computeProfileCore(args)};
  } catch (error) {
    structuredError({
      code: 'storage_inaccessible',
      message: errorMessage(error),
      path: args.roots.mentorshipDir,
    });

    return {exitCode: EXIT_CODES.STORAGE_INACCESSIBLE, ok: false};
  }
};

const safeWriteProfile = async (args: {
  core: CoreResult;
  now: Date;
  roots: StorageRoots;
}): Promise<StepOutcome<undefined>> => {
  try {
    await renderAndWriteProfile(args);

    return {ok: true, value: undefined};
  } catch (error) {
    structuredError({
      code: 'storage_inaccessible',
      message: errorMessage(error),
      path: args.roots.profilePath,
    });

    return {exitCode: EXIT_CODES.STORAGE_INACCESSIBLE, ok: false};
  }
};

const safeWriteAnalytics = async (args: {
  core: CoreResult;
  now: Date;
  roots: StorageRoots;
}): Promise<StepOutcome<undefined>> => {
  try {
    await writeAnalytics(args);

    return {ok: true, value: undefined};
  } catch (error) {
    structuredError({
      code: 'analytics_report_failed',
      message: errorMessage(error),
      path: args.roots.analyticsDir,
    });

    return {exitCode: EXIT_CODES.STORAGE_INACCESSIBLE, ok: false};
  }
};

/**
 * Public handler. Returns the process exit code; never writes to stdout
 * on the happy path (UAT-026 chain triggers expect silent success).
 */
export const computeProfile = async (
  options: RunOptions = {}
): Promise<number> => {
  const roots = options.roots ?? resolveStorageRoots();
  const configStep = safeReadConfig(roots);

  if (!configStep.ok) return configStep.exitCode;

  // UAT-040: short-circuit silently when mentorship is disabled. UAT-026
  // chain trigger from spec_close depends on this returning 0 quietly.
  if (configStep.value.enabled !== true) return EXIT_CODES.OK;

  const now = options.now ?? new Date();
  const coreStep = await safeComputeCore({now, roots});

  if (!coreStep.ok) return coreStep.exitCode;
  const profileStep = await safeWriteProfile({
    core: coreStep.value,
    now,
    roots,
  });

  if (!profileStep.ok) return profileStep.exitCode;

  if (!configStep.value.analytics.enabled) return EXIT_CODES.OK;

  const analyticsStep = await safeWriteAnalytics({
    core: coreStep.value,
    now,
    roots,
  });

  return analyticsStep.ok ? EXIT_CODES.OK : analyticsStep.exitCode;
};

/**
 * Subcommand entry shape used by the CLI router.
 */
export const run = async (
  _argv: readonly string[],
  options: RunOptions = {}
): Promise<number> => computeProfile(options);
