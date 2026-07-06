/**
 * Mentorship NDJSON reader for the compute-profile rolling window.
 *
 * Reads `<roots.mentorshipDir>/events-YYYY-MM-DD.jsonl` for each day in
 * the trailing N-day window (inclusive of both bookends). Validates each
 * line through the envelope schema then dispatches to the per-event-type
 * payload schema. Malformed lines are skipped (logged via stderr); one
 * bad line should not poison the whole window.
 */
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import {EnvelopeSchema} from '../schemas/envelope.js';
import {
  MENTORSHIP_EVENT_TYPES,
  MentorshipPayloadByType,
} from '../schemas/mentorship-payloads.js';
import type {MentorshipEventType} from '../schemas/mentorship-payloads.js';
import {structuredError} from '../stderr.js';
import type {StorageRoots} from '../storage/index.js';

/**
 * A mentorship event after envelope + payload validation. Generic over the
 * concrete event_type so callers can narrow without re-validating.
 */
export type MentorshipEvent<
  TType extends MentorshipEventType = MentorshipEventType,
> = {
  agent_type: string;
  event_id: string;
  event_type: TType;
  payload: ReturnType<(typeof MentorshipPayloadByType)[TType]['parse']>;
  project_id: string;
  schema_version: 1;
  session_hash: string;
  timestamp: string;
};

const MS_PER_DAY = 86_400_000;

const MENTORSHIP_TYPE_SET: ReadonlySet<string> = new Set(
  MENTORSHIP_EVENT_TYPES
);

const isMentorshipEventType = (value: string): value is MentorshipEventType =>
  MENTORSHIP_TYPE_SET.has(value);

const formatYyyyMmDd = (date: Date): string => {
  const yyyy = date.getUTCFullYear().toString().padStart(4, '0');
  const mm = (date.getUTCMonth() + 1).toString().padStart(2, '0');
  const dd = date.getUTCDate().toString().padStart(2, '0');

  return `${yyyy}-${mm}-${dd}`;
};

const enumerateWindowDates = (now: Date, windowDays: number): string[] => {
  const dates: string[] = [];
  const baseMs = now.getTime();

  for (let offset = windowDays - 1; offset >= 0; offset -= 1) {
    dates.push(formatYyyyMmDd(new Date(baseMs - offset * MS_PER_DAY)));
  }

  return dates;
};

const readFileIfExists = async (filePath: string): Promise<null | string> => {
  try {
    return await readFile(filePath, 'utf8');
  } catch (error) {
    if (
      error !== null &&
      typeof error === 'object' &&
      'code' in error &&
      error.code === 'ENOENT'
    ) {
      return null;
    }

    throw error;
  }
};

const parseLine = (
  rawLine: string,
  filePath: string
): MentorshipEvent | null => {
  const parseAttempt = ((): unknown => {
    try {
      return JSON.parse(rawLine) as unknown;
    } catch (error) {
      structuredError({
        code: 'mentorship_event_malformed',
        message: error instanceof Error ? error.message : String(error),
        path: filePath,
      });

      return null;
    }
  })();

  if (parseAttempt === null) return null;

  const envelopeResult = EnvelopeSchema.safeParse(parseAttempt);

  if (!envelopeResult.success) {
    structuredError({
      code: 'mentorship_event_envelope_invalid',
      issues: envelopeResult.error.issues,
      path: filePath,
    });

    return null;
  }
  const envelope = envelopeResult.data;
  const eventType = envelope.event_type;

  if (!isMentorshipEventType(eventType)) {
    // Cloud-only events should never land in the mentorship file in the
    // v1 design; if one does, skip silently - not our pattern's concern.
    return null;
  }
  const payloadSchema = MentorshipPayloadByType[eventType];
  const payloadResult = payloadSchema.safeParse(envelope.payload);

  if (!payloadResult.success) {
    structuredError({
      code: 'mentorship_event_payload_invalid',
      event_type: eventType,
      issues: payloadResult.error.issues,
      path: filePath,
    });

    return null;
  }

  return {
    agent_type: envelope.agent_type,
    event_id: envelope.event_id,
    event_type: eventType,
    // safeParse data is the validated, runtime-shape-correct payload; the
    // generic of MentorshipEvent lines up with the index-narrowed schema.
    payload: payloadResult.data,
    project_id: envelope.project_id,
    schema_version: 1,
    session_hash: envelope.session_hash,
    timestamp: envelope.timestamp,
  };
};

const parseFileLines = (raw: string, filePath: string): MentorshipEvent[] => {
  const events: MentorshipEvent[] = [];

  for (const line of raw.split('\n')) {
    if (line.length > 0) {
      const event = parseLine(line, filePath);

      if (event !== null) events.push(event);
    }
  }

  return events;
};

type ReadEventsArgs = {
  now?: Date;
  roots: StorageRoots;
  windowDays: number;
};

/**
 * Read every well-formed mentorship event from the trailing
 * `windowDays` window (inclusive of today and the day windowDays-1 ago).
 *
 * Iteration order: oldest-day-first. Within a file, lines are returned
 * in append order. Callers that care about timestamp order should sort.
 */
export const readMentorshipEvents = async (
  args: ReadEventsArgs
): Promise<MentorshipEvent[]> => {
  const {now = new Date(), roots, windowDays} = args;
  const dates = enumerateWindowDates(now, windowDays);
  const events: MentorshipEvent[] = [];

  for (const date of dates) {
    const filePath = path.join(roots.mentorshipDir, `events-${date}.jsonl`);
    // Sequential by design: per-file IO is cheap and keeps memory bounded.
    // eslint-disable-next-line no-await-in-loop -- intentional sequential
    const raw = await readFileIfExists(filePath);

    if (raw !== null) events.push(...parseFileLines(raw, filePath));
  }

  return events;
};
