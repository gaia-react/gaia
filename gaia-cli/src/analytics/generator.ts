/**
 * Analytics report generator (UAT-043 / UAT-026 chain).
 *
 * Reads:
 *  - The mentorship NDJSON event files in the rolling 30-day window.
 *  - The install-id ULID (timestamp prefix → `weeks_since_install`).
 *  - The repo's top-level `package.json` (→ `gaia_version`).
 *  - The `PatternResult[]` aggregate from compute-profile (passed in).
 *
 * Writes nothing. The caller (writer.ts) handles persistence.
 *
 * The audit block is computed by `audit-attest.ts` after the rest of the
 * report is assembled — failing loud if any forbidden field would land.
 */
import {decodeTime, ulid} from 'ulid';
import {existsSync, readdirSync, readFileSync} from 'node:fs';
import path from 'node:path';
import type {AnalyticsReport} from '../schemas/analytics-report.js';
import {readOrCreateInstallId} from '../storage/install-id.js';
import type {StorageRoots} from '../storage/paths.js';
import {computeAuditBlock} from './audit-attest.js';

/**
 * Pattern result shape. Declared locally to decouple this task from
 * compute-profile's exact export path. TypeScript's structural typing
 * matches at the call site against compute-profile's exported type.
 *
 * `components` is `unknown` — analytics doesn't read it (the report exports
 * pattern aggregates, not the raw component breakdown), so the field is
 * carried for shape-compat with compute-profile's `{metric, value}[]` shape
 * without binding to that exact array shape here.
 */
export type PatternResult = {
  area_tag: string;
  components?: unknown;
  pattern_id: string;
  sample_count: number;
  strength: null | number;
};

const REPORT_WINDOW_DAYS = 30;
const MS_PER_DAY = 86_400_000;
const MS_PER_WEEK = MS_PER_DAY * 7;
const MENTORSHIP_FILENAME_REGEX = /^events-(\d{4}-\d{2}-\d{2})\.jsonl$/u;

const isoDateUtc = (date: Date): string => {
  const year = date.getUTCFullYear().toString().padStart(4, '0');
  const month = (date.getUTCMonth() + 1).toString().padStart(2, '0');
  const day = date.getUTCDate().toString().padStart(2, '0');

  return `${year}-${month}-${day}`;
};

/**
 * Read the GAIA package.json `version` field.
 *
 * Resolves relative to `roots.projectIdPath`'s repo root segment so the
 * function works in test sandboxes that don't have a real package.json.
 * Falls back to `'unknown'` so tests with no package.json fixture still
 * produce a valid report (the version field is a string per schema).
 */
const readGaiaVersion = (roots: StorageRoots): string => {
  // roots.projectIdPath is `<repoRoot>/.gaia/local/.project-id`.
  // Strip 3 segments to get back to repoRoot.
  const repoRoot = path.dirname(
    path.dirname(path.dirname(roots.projectIdPath))
  );
  const packagePath = path.join(repoRoot, 'package.json');

  if (!existsSync(packagePath)) return 'unknown';

  try {
    const raw = readFileSync(packagePath, 'utf8');
    const parsed = JSON.parse(raw) as {version?: unknown};

    return typeof parsed.version === 'string' ? parsed.version : 'unknown';
  } catch {
    return 'unknown';
  }
};

const computeWeeksSinceInstall = (
  installId: string,
  generatedAt: Date
): number => {
  try {
    const installMs = decodeTime(installId);
    const deltaMs = generatedAt.getTime() - installMs;

    if (deltaMs <= 0) return 0;

    return Math.floor(deltaMs / MS_PER_WEEK);
  } catch {
    // Malformed ULID → 0 weeks. The schema accepts integer ≥ 0 and the
    // audit block doesn't gate on this value.
    return 0;
  }
};

type WindowBounds = {
  endIso: string;
  startIso: string;
};

const computeWindowBounds = (
  generatedAt: Date,
  windowDays: number
): WindowBounds => {
  const endMs = generatedAt.getTime();
  const startMs = endMs - windowDays * MS_PER_DAY;

  return {
    endIso: new Date(endMs).toISOString(),
    startIso: new Date(startMs).toISOString(),
  };
};

type EngagementCounts = {
  daysActive: Set<string>;
  sessionHashes: Set<string>;
  specsClosed: number;
  tasksCompleted: number;
};

type MentorshipEventLine = {
  event_type?: string;
  payload?: Record<string, unknown>;
  session_hash?: string;
  timestamp?: string;
};

const newEngagementCounts = (): EngagementCounts => ({
  daysActive: new Set<string>(),
  sessionHashes: new Set<string>(),
  specsClosed: 0,
  tasksCompleted: 0,
});

const isWithinWindow = (
  timestamp: string | undefined,
  bounds: WindowBounds
): boolean => {
  if (typeof timestamp !== 'string') return false;

  return timestamp >= bounds.startIso && timestamp <= bounds.endIso;
};

const accumulateEvent = (
  line: string,
  bounds: WindowBounds,
  counts: EngagementCounts
): void => {
  if (line.length === 0) return;
  let parsed: MentorshipEventLine;

  try {
    parsed = JSON.parse(line) as MentorshipEventLine;
  } catch {
    return; // skip malformed line (mentorship file is best-effort)
  }

  if (!isWithinWindow(parsed.timestamp, bounds)) return;

  if (typeof parsed.session_hash === 'string') {
    counts.sessionHashes.add(parsed.session_hash);
  }

  if (typeof parsed.timestamp === 'string') {
    counts.daysActive.add(parsed.timestamp.slice(0, 10));
  }

  if (parsed.event_type === 'time_to_resolved_spec') {
    counts.specsClosed += 1;
  }

  if (parsed.event_type === 'uat_pass' || parsed.event_type === 'uat_fail') {
    counts.tasksCompleted += 1;
  }
};

const consumeFile = (
  filePath: string,
  bounds: WindowBounds,
  counts: EngagementCounts
): void => {
  let raw: string;

  try {
    raw = readFileSync(filePath, 'utf8');
  } catch {
    return;
  }

  for (const line of raw.split('\n')) {
    accumulateEvent(line, bounds, counts);
  }
};

const readMentorshipEngagement = (
  roots: StorageRoots,
  bounds: WindowBounds
): EngagementCounts => {
  const counts = newEngagementCounts();

  if (!existsSync(roots.mentorshipDir)) return counts;
  let entries: string[];

  try {
    entries = readdirSync(roots.mentorshipDir);
  } catch {
    return counts;
  }
  const startDate = bounds.startIso.slice(0, 10);

  for (const entry of entries) {
    const match = MENTORSHIP_FILENAME_REGEX.exec(entry);
    const fileDate = match?.[1];

    // Skip non-matching filenames and files clearly outside the 30-day window.
    if (fileDate !== undefined && fileDate >= startDate) {
      consumeFile(path.join(roots.mentorshipDir, entry), bounds, counts);
    }
  }

  return counts;
};

type AdaptationAggregate = AnalyticsReport['adaptations'][number];
type PatternAggregate = AnalyticsReport['patterns'][number];

const buildPatternAggregates = (
  results: readonly PatternResult[]
): PatternAggregate[] =>
  results.map((result) => {
    const minSampleSizeMet = result.sample_count >= 10;
    // strength can be null when below threshold; clamp to 0 for the aggregate
    // so downstream consumers don't carry the null variant. p10/p90 collapse
    // to the same value at v1 (single-strength signal); v1.x will widen.
    const strength = result.strength ?? 0;

    return {
      avg_strength_at_fire: strength,
      fire_count: minSampleSizeMet ? 1 : 0,
      min_sample_size_met: minSampleSizeMet,
      pattern_id: result.pattern_id,
      strength_p10: strength,
      strength_p90: strength,
    };
  });

/**
 * Build adaptation aggregates from pattern results.
 *
 * v1.0.0 ships wired-but-inert: pattern-detection sample threshold (N≥10)
 * blocks any active pattern from firing until real-usage data accumulates.
 * Until then, every PatternResult yields no adaptation. This function is
 * the placeholder structure — adaptations land empty at v1.0.0 and shape
 * up against real signal in v1.x.
 */
const buildAdaptationAggregates = (
  _results: readonly PatternResult[]
): AdaptationAggregate[] => [];

type GenerateArgs = {
  generatedAt?: Date;
  patternResults: readonly PatternResult[];
  roots: StorageRoots;
  windowDays: 30;
};

/**
 * Build the daily analytics report.
 *
 * Pure assembly; the caller atomically writes the result via writer.ts.
 * Throws via `computeAuditBlock` if the assembled body would carry any
 * forbidden field — drift surfaces at generation time, not after the
 * file lands.
 */
export const generateAnalyticsReport = async (
  args: GenerateArgs
): Promise<AnalyticsReport> => {
  const {patternResults, roots} = args;
  const generatedAt = args.generatedAt ?? new Date();
  const installId = readOrCreateInstallId(roots);
  const bounds = computeWindowBounds(generatedAt, REPORT_WINDOW_DAYS);
  const engagement = readMentorshipEngagement(roots, bounds);

  const body: Omit<AnalyticsReport, 'audit'> = {
    adaptations: buildAdaptationAggregates(patternResults),
    anonymous_install_id: installId,
    engagement: {
      days_active_in_window: engagement.daysActive.size,
      profile_md_read_count: 0,
      sessions_in_window: engagement.sessionHashes.size,
      specs_closed_in_window: engagement.specsClosed,
      tasks_completed_in_window: engagement.tasksCompleted,
      weeks_since_install: computeWeeksSinceInstall(installId, generatedAt),
    },
    gaia_version: readGaiaVersion(roots),
    patterns: buildPatternAggregates(patternResults),
    report_generated_at: generatedAt.toISOString(),
    report_id: ulid(generatedAt.getTime()),
    report_window_days: REPORT_WINDOW_DAYS,
    schema_version: 1,
  };

  const audit = computeAuditBlock(body);

  return {...body, audit};
};

export {isoDateUtc};
