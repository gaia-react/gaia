/* eslint-disable unicorn/prevent-abbreviations -- envelope/argv field names
   are frozen interface contracts. */
import {createHash} from 'node:crypto';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {isMentorshipEnabled} from '../mentorship/config.js';
import {AgentTypeSchema} from '../schemas/envelope.js';
import type {AgentType} from '../schemas/envelope.js';
import {
  MENTORSHIP_EVENT_TYPES,
  MentorshipPayloadByType,
} from '../schemas/mentorship-payloads.js';
import type {MentorshipEventType} from '../schemas/mentorship-payloads.js';
import {structuredError} from '../stderr.js';
import {
  ensureCloudDirs,
  ensureMentorshipDirs,
  readOrCreateProjectId,
  resolveStorageRoots,
} from '../storage/index.js';
import type {StorageRoots} from '../storage/index.js';
import {buildEnvelope} from './envelope.js';
import type {EventEnvelopeWithLocal} from './envelope.js';
import {appendIdempotent} from './ndjson-writer.js';
import {projectToCloud} from './projection.js';

/**
 * Cloud-only event types — accepted by the CLI for envelope-validation only.
 * Per-consumer payload shapes ship with the relevant Sequel feature; v1
 * accepts arbitrary payloads here and lets the cloud-projection module
 * surface drift via its `.strict()` defense.
 */
export const CLOUD_ONLY_EVENT_TYPES = [
  'pr_opened',
  'pr_merged',
  'dispatch_artifact_emitted',
  'engineer_return',
  'dry_violation_flagged',
  'skill_loaded',
  'skill_invoked',
  'skill_failed',
  'recurring_pattern_observed',
  'update_deps_run',
  'branch_opened',
  'interlock_held',
  'audit_finding',
  'boundary_zone_touch',
  'boundary_violation_flagged',
] as const;

type CloudOnlyEventType = (typeof CLOUD_ONLY_EVENT_TYPES)[number];

const isMentorshipEventType = (
  eventType: string
): eventType is MentorshipEventType =>
  (MENTORSHIP_EVENT_TYPES as readonly string[]).includes(eventType);

const isCloudOnlyEventType = (
  eventType: string
): eventType is CloudOnlyEventType =>
  (CLOUD_ONLY_EVENT_TYPES as readonly string[]).includes(eventType);

type FlagDefinition = {
  kind: FlagKind;
  target: string;
};

type FlagKind = 'boolean' | ValueKind;

type ParsedArgs = {
  eventType: string;
  flags: ParsedFlags;
};

type ParsedFlags = {
  // Free-form passthrough for cloud-only and unknown payload fields. The
  // strict cloud projection schema is the field-list contract.
  [key: string]: unknown;
  abandoned?: boolean;
  agentType?: string;
  // Mentorship payload fields (kebab-case CLI -> snake_case payload):
  amendmentReason?: string;
  areaTags?: string[];
  attempts?: number;
  auditorType?: string;
  classification?: string;
  contextRequestClass?: string;
  durationSeconds?: number;
  failureClass?: string;
  fieldsChanged?: string[];
  findingClass?: string;
  itemsAdded?: number;
  itemsRemoved?: number;
  localNamespace?: object;
  planId?: string;
  prNumber?: number;
  questionCount?: number;
  revisionClass?: string;
  sessionHash?: string;
  severity?: string;
  specId?: string;
  taskId?: string;
  timeSinceCloseSeconds?: number;
  uatId?: string;
};

const FLAG_DEFINITIONS: Readonly<Partial<Record<string, FlagDefinition>>> = {
  '--abandoned': {kind: 'boolean', target: 'abandoned'},
  '--agent-type': {kind: 'string', target: 'agentType'},
  '--amendment-reason': {kind: 'string', target: 'amendmentReason'},
  '--area-tags': {kind: 'list', target: 'areaTags'},
  '--attempts': {kind: 'number', target: 'attempts'},
  '--auditor-type': {kind: 'string', target: 'auditorType'},
  '--classification': {kind: 'string', target: 'classification'},
  '--context-request-class': {kind: 'string', target: 'contextRequestClass'},
  '--duration-seconds': {kind: 'number', target: 'durationSeconds'},
  '--failure-class': {kind: 'string', target: 'failureClass'},
  '--fields-changed': {kind: 'list', target: 'fieldsChanged'},
  '--finding-class': {kind: 'string', target: 'findingClass'},
  '--items-added': {kind: 'number', target: 'itemsAdded'},
  '--items-removed': {kind: 'number', target: 'itemsRemoved'},
  '--local': {kind: 'json', target: 'localNamespace'},
  '--plan-id': {kind: 'string', target: 'planId'},
  '--pr-number': {kind: 'number', target: 'prNumber'},
  '--question-count': {kind: 'number', target: 'questionCount'},
  '--revision-class': {kind: 'string', target: 'revisionClass'},
  '--session-hash': {kind: 'string', target: 'sessionHash'},
  '--severity': {kind: 'string', target: 'severity'},
  '--spec-id': {kind: 'string', target: 'specId'},
  '--task-id': {kind: 'string', target: 'taskId'},
  '--time-since-close-seconds': {
    kind: 'number',
    target: 'timeSinceCloseSeconds',
  },
  '--uat-id': {kind: 'string', target: 'uatId'},
};

type ValueKind = 'json' | 'list' | 'number' | 'string';

class ArgParseError extends Error {
  constructor(
    public readonly issue: string,
    public readonly arg?: string
  ) {
    super(issue);
    this.name = 'ArgParseError';
  }
}

const parseValueByKind: Readonly<
  Record<ValueKind, (token: string, valueToken: string) => unknown>
> = {
  json: (token, valueToken) => {
    try {
      return JSON.parse(valueToken) as object;
    } catch {
      throw new ArgParseError(
        `flag ${token} expects a JSON object; got ${valueToken}`,
        token
      );
    }
  },
  list: (_token, valueToken) =>
    valueToken
      .split(',')
      .map((entry) => entry.trim())
      .filter((entry) => entry.length > 0),
  number: (token, valueToken) => {
    const parsed = Number(valueToken);

    if (Number.isNaN(parsed)) {
      throw new ArgParseError(
        `flag ${token} expects a number; got ${valueToken}`,
        token
      );
    }

    return parsed;
  },
  string: (_token, valueToken) => valueToken,
};

const parseArgs = (argv: readonly string[]): ParsedArgs => {
  // First positional after `emit` is the event type. Without
  // `noUncheckedIndexedAccess`, `argv[0]` is typed `string` even when absent
  // at runtime; coerce through `string | undefined` to express reality.
  const eventType = argv[0] as string | undefined;
  const rest = argv.slice(1);

  if (eventType === undefined || eventType.startsWith('--')) {
    throw new ArgParseError('missing event_type positional');
  }

  const flags: ParsedFlags = {};
  let index = 0;

  while (index < rest.length) {
    // `rest[index]` types as `string` without `noUncheckedIndexedAccess`,
    // but the loop can only enter when `index < rest.length`, so the value
    // is always defined. Coerce explicitly to silence lint.
    const token = rest[index];
    const definition = FLAG_DEFINITIONS[token];

    if (definition === undefined) {
      throw new ArgParseError(`unknown flag: ${token}`, token);
    }

    if (definition.kind === 'boolean') {
      flags[definition.target] = true;
      index += 1;
    } else {
      const valueToken = rest[index + 1] as string | undefined;

      if (valueToken === undefined || valueToken.startsWith('--')) {
        throw new ArgParseError(`flag ${token} expects a value`, token);
      }
      const parser = parseValueByKind[definition.kind];
      flags[definition.target] = parser(token, valueToken);
      index += 2;
    }
  }

  return {eventType, flags};
};

/**
 * Map kebab-case CLI flags to snake_case payload fields.
 * The schema validates the resulting object; CLI surface stays kebab-case.
 */
const flagsToPayload = (
  eventType: string,
  flags: ParsedFlags
): Record<string, unknown> => {
  const candidate: Record<string, unknown> = {};

  const assign = (key: string, value: unknown): void => {
    if (value !== undefined) {
      candidate[key] = value;
    }
  };

  assign('uat_id', flags.uatId);
  assign('spec_id', flags.specId);
  assign('task_id', flags.taskId);
  assign('attempts', flags.attempts);
  assign('area_tags', flags.areaTags);
  assign('failure_class', flags.failureClass);
  assign('context_request_class', flags.contextRequestClass);
  assign('classification', flags.classification);
  assign('fields_changed', flags.fieldsChanged);
  assign('amendment_reason', flags.amendmentReason);
  assign('time_since_close_seconds', flags.timeSinceCloseSeconds);
  assign('plan_id', flags.planId);
  assign('revision_class', flags.revisionClass);
  assign('items_added', flags.itemsAdded);
  assign('items_removed', flags.itemsRemoved);
  assign('question_count', flags.questionCount);
  assign('duration_seconds', flags.durationSeconds);
  assign('abandoned', flags.abandoned);
  assign('pr_number', flags.prNumber);
  assign('finding_class', flags.findingClass);
  assign('severity', flags.severity);
  assign('auditor_type', flags.auditorType);

  // For mentorship payloads that include agent_type in the body
  // (needs_context_returned, blocked_returned), surface the top-level
  // agent_type flag as the payload field too. The envelope's top-level
  // agent_type is the canonical home; this duplication mirrors the
  // SPEC's per-event-type schema shape.
  if (
    (eventType === 'needs_context_returned' ||
      eventType === 'blocked_returned') &&
    flags.agentType !== undefined
  ) {
    candidate.agent_type = flags.agentType;
  }

  return candidate;
};

const validatePayload = (
  eventType: string,
  candidate: Record<string, unknown>
): {data: object; ok: true} | {issues: unknown; ok: false} => {
  if (isMentorshipEventType(eventType)) {
    const schema = MentorshipPayloadByType[eventType];
    const parsed = schema.safeParse(candidate);

    if (!parsed.success) {
      return {issues: parsed.error.issues, ok: false};
    }

    return {data: parsed.data, ok: true};
  }

  // Cloud-only event type: payload is z.unknown() at v1. Pass through as-is.
  return {data: candidate, ok: true};
};

const todayIsoDate = (now: Date = new Date()): string => {
  const yyyy = now.getUTCFullYear().toString().padStart(4, '0');
  const mm = (now.getUTCMonth() + 1).toString().padStart(2, '0');
  const dd = now.getUTCDate().toString().padStart(2, '0');

  return `${yyyy}-${mm}-${dd}`;
};

const sha256Hex = (input: string): string =>
  createHash('sha256').update(input).digest('hex');

const deriveSessionHash = (override?: string): string => {
  if (override !== undefined && override.length > 0) {
    return override;
  }
  const sessionId = process.env.CLAUDE_SESSION_ID;

  if (sessionId !== undefined && sessionId.length > 0) {
    return sha256Hex(sessionId).slice(0, 32);
  }
  // Fallback: stable per-invocation hash from pid + start time.
  const start = process.hrtime.bigint().toString();

  return sha256Hex(`${process.pid}-${start}`).slice(0, 32);
};

const resolveAgentType = (raw: string | undefined): AgentType => {
  if (raw === undefined) {
    return 'human';
  }
  const parsed = AgentTypeSchema.safeParse(raw);

  if (!parsed.success) {
    throw new ArgParseError(`invalid --agent-type: ${raw}`);
  }

  return parsed.data;
};

type CloudWriteOutcome =
  | {drift: {event_type: string; field: string}; ok: false}
  | {ok: true; written: boolean};

const writeCloud = async (
  envelope: EventEnvelopeWithLocal,
  roots: StorageRoots,
  now: Date
): Promise<CloudWriteOutcome> => {
  const projection = projectToCloud(envelope);

  if (!projection.ok) {
    return {
      drift: {event_type: projection.event_type, field: projection.field},
      ok: false,
    };
  }
  const cloudPath = path.join(
    roots.cloudDir,
    `events-${todayIsoDate(now)}.jsonl`
  );

  const result = await appendIdempotent({
    eventId: envelope.event_id,
    fileMode: 0o644,
    filePath: cloudPath,
    line: projection.cloudLine,
  });

  return {ok: true, written: result.written};
};

const writeMentorship = async (
  envelope: EventEnvelopeWithLocal,
  roots: StorageRoots,
  now: Date
): Promise<{written: boolean}> => {
  const mentorshipLine = JSON.stringify(envelope);
  const mentorshipPath = path.join(
    roots.mentorshipDir,
    `events-${todayIsoDate(now)}.jsonl`
  );

  return appendIdempotent({
    eventId: envelope.event_id,
    fileMode: 0o600,
    filePath: mentorshipPath,
    line: mentorshipLine,
  });
};

type HandleEmitOptions = {
  /**
   * Inject pre-resolved storage roots. Production callers pass nothing
   * (resolution falls through to `resolveStorageRoots()` which reads the
   * git repo root + `homedir()`). Tests pass a `mkdtemp`-anchored sandbox.
   */
  roots?: StorageRoots;
};

type ValidatedInput = {
  agentType: AgentType;
  eventType: string;
  flags: ParsedFlags;
  payload: object;
};

type ValidationOutcome =
  | {exitCode: number; ok: false}
  | {input: ValidatedInput; ok: true};

const parseAndValidate = (argv: readonly string[]): ValidationOutcome => {
  let parsed: ParsedArgs;

  try {
    parsed = parseArgs(argv);
  } catch (error) {
    const issue =
      error instanceof ArgParseError ? error.issue
      : error instanceof Error ? error.message
      : String(error);
    const arg = error instanceof ArgParseError ? error.arg : undefined;
    structuredError({arg, code: 'arg_parse_error', issue});

    return {exitCode: EXIT_CODES.PAYLOAD_VALIDATION_FAILED, ok: false};
  }
  const {eventType, flags} = parsed;

  // Unknown event type -> structured error, non-zero exit, no writes.
  if (!isMentorshipEventType(eventType) && !isCloudOnlyEventType(eventType)) {
    structuredError({code: 'unknown_event_type', event_type: eventType});

    return {exitCode: EXIT_CODES.UNKNOWN_EVENT_TYPE, ok: false};
  }

  let agentType: AgentType;

  try {
    agentType = resolveAgentType(flags.agentType);
  } catch (error) {
    structuredError({
      code: 'arg_parse_error',
      issue: error instanceof Error ? error.message : String(error),
    });

    return {exitCode: EXIT_CODES.PAYLOAD_VALIDATION_FAILED, ok: false};
  }
  // Payload validation failure -> structured error, non-zero, no writes.
  const candidate = flagsToPayload(eventType, flags);
  const validation = validatePayload(eventType, candidate);

  if (!validation.ok) {
    structuredError({
      code: 'payload_validation_failed',
      event_type: eventType,
      issues: validation.issues,
    });

    return {exitCode: EXIT_CODES.PAYLOAD_VALIDATION_FAILED, ok: false};
  }

  return {
    input: {agentType, eventType, flags, payload: validation.data},
    ok: true,
  };
};

type StoragePrepOutcome =
  | {exitCode: number; ok: false}
  | {mentorshipOn: boolean; ok: true; projectId: string};

const prepareStorage = async (
  roots: StorageRoots
): Promise<StoragePrepOutcome> => {
  try {
    await ensureCloudDirs(roots);
  } catch (error) {
    structuredError({
      code: 'storage_inaccessible',
      message: error instanceof Error ? error.message : String(error),
      path: roots.cloudDir,
    });

    return {exitCode: EXIT_CODES.STORAGE_INACCESSIBLE, ok: false};
  }
  let mentorshipOn: boolean;

  try {
    mentorshipOn = isMentorshipEnabled(roots);
  } catch (error) {
    structuredError({
      code: 'config_invalid',
      message: error instanceof Error ? error.message : String(error),
      path: 'mentorship.json',
    });

    return {exitCode: EXIT_CODES.CONFIG_INVALID, ok: false};
  }

  if (mentorshipOn) {
    try {
      await ensureMentorshipDirs(roots);
    } catch (error) {
      structuredError({
        code: 'storage_inaccessible',
        message: error instanceof Error ? error.message : String(error),
        path: roots.mentorshipDir,
      });

      return {exitCode: EXIT_CODES.STORAGE_INACCESSIBLE, ok: false};
    }
  }
  let projectId: string;

  try {
    projectId = readOrCreateProjectId(roots);
  } catch (error) {
    structuredError({
      code: 'storage_inaccessible',
      message: error instanceof Error ? error.message : String(error),
      path: roots.projectIdPath,
    });

    return {exitCode: EXIT_CODES.STORAGE_INACCESSIBLE, ok: false};
  }

  return {mentorshipOn, ok: true, projectId};
};

type WriteStreamsArgs = {
  envelope: EventEnvelopeWithLocal;
  mentorshipOn: boolean;
  now: Date;
  roots: StorageRoots;
};

const writeStreams = async (args: WriteStreamsArgs): Promise<number> => {
  const {envelope, mentorshipOn, now, roots} = args;
  // Cloud emit is independent of mentorship opt-in. Projection runs BEFORE
  // either write; drift -> CLOUD_PROJECTION_DRIFT and nothing lands.
  let cloudOutcome: CloudWriteOutcome;

  try {
    cloudOutcome = await writeCloud(envelope, roots, now);
  } catch (error) {
    structuredError({
      code: 'storage_inaccessible',
      message: error instanceof Error ? error.message : String(error),
      path: roots.cloudDir,
    });

    return EXIT_CODES.STORAGE_INACCESSIBLE;
  }

  if (!cloudOutcome.ok) {
    structuredError({
      code: 'cloud_projection_drift',
      event_type: cloudOutcome.drift.event_type,
      field: cloudOutcome.drift.field,
    });

    return EXIT_CODES.CLOUD_PROJECTION_DRIFT;
  }

  if (mentorshipOn) {
    try {
      await writeMentorship(envelope, roots, now);
    } catch (error) {
      structuredError({
        code: 'storage_inaccessible',
        message: error instanceof Error ? error.message : String(error),
        path: roots.mentorshipDir,
      });

      return EXIT_CODES.STORAGE_INACCESSIBLE;
    }
  }

  return EXIT_CODES.OK;
};

/**
 * Handle one `gaia telemetry emit <event_type> [--field value ...]`
 * invocation. Returns the process exit code; never returns when the caller
 * exits via `process.exit` after this resolves. Silent success on the
 * happy path — no stdout writes.
 */
export const handleEmit = async (
  argv: readonly string[],
  options: HandleEmitOptions = {}
): Promise<number> => {
  const validation = parseAndValidate(argv);

  if (!validation.ok) return validation.exitCode;

  const {agentType, eventType, flags, payload} = validation.input;
  const roots = options.roots ?? resolveStorageRoots();
  const prep = await prepareStorage(roots);

  if (!prep.ok) return prep.exitCode;

  const now = new Date();
  const envelope = buildEnvelope({
    agentType,
    eventType,
    localNamespace: flags.localNamespace,
    now,
    payload,
    projectId: prep.projectId,
    sessionHash: deriveSessionHash(flags.sessionHash),
  });

  return writeStreams({envelope, mentorshipOn: prep.mentorshipOn, now, roots});
};
