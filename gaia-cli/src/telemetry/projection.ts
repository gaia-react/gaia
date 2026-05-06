/**
 * Cloud-stream structural projection (UAT-013, UAT-014).
 *
 * This module is the security boundary between the mentorship envelope
 * (which carries `_local` plus full identity in the payload) and the cloud
 * stream (which must contain zero identity-bearing fields). The projection
 * is whitelist-based: every cloud event is parsed through a `.strict()`
 * Zod schema; unknown keys cause a fail-loud return that the caller maps
 * to `EXIT_CODES.CLOUD_PROJECTION_DRIFT` with NEITHER stream written.
 *
 * Belt-and-suspenders: after the strict parse succeeds, a denylist sweep
 * scans the JSON-stringified cloud line for any forbidden-key substring
 * (defense against future drift where a payload field name slips through
 * `.strict()` despite being identity-bearing). The whitelist is the
 * security boundary; the denylist is the paranoid second line.
 *
 * See `cloud-telemetry-scope` (privacy contract) and
 * `task-cloud-projection.md` in the SPEC-001 plan folder.
 */
import {z} from 'zod';
import {
  CloudPayloadByType,
  EnvelopeSchema,
  FORBIDDEN_CLOUD_KEYS,
  MENTORSHIP_EVENT_TYPES,
} from '../schemas/index.js';
import type {CloudEventType} from '../schemas/index.js';

/**
 * Cloud-only event types that v1 ships without per-event strict schemas.
 * v1 ships envelope + projection contract + emit primitive only; per-consumer
 * cloud event payloads (Holistic Reviewer, Skill Curator, Package Steward,
 * Custodian) land with their respective Sequel features in v1.x.
 *
 * MUST stay in sync with `CLOUD_ONLY_EVENT_TYPES` in
 * `gaia-cli/src/telemetry/emit.ts` (owned by task-emit-core). Duplicated
 * intentionally so projection and emit-core can ship in parallel without
 * coupling. Drift between the two lists is a bug; the smoke harness
 * (Phase 6) asserts they match.
 */
const KNOWN_CLOUD_ONLY_TYPES = [
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

type KnownCloudOnlyType = (typeof KNOWN_CLOUD_ONLY_TYPES)[number];

const CLOUD_ONLY_TYPE_SET: ReadonlySet<string> = new Set(
  KNOWN_CLOUD_ONLY_TYPES
);

const MENTORSHIP_TYPE_SET: ReadonlySet<string> = new Set(
  MENTORSHIP_EVENT_TYPES
);

/**
 * Cloud-only payload schema — v1 placeholder. Sequel features will
 * register strict per-event schemas here. `passthrough()` is intentional
 * for v1: the per-consumer field sets aren't locked yet, and the
 * envelope-level guarantees (project_id, agent_type, etc.) plus the
 * denylist sweep cover the privacy invariant for v1 internal testing.
 */
const cloudOnlyPassthroughPayload = z.looseObject({});

export type ProjectionResult =
  | {
      cloudEvent: Record<string, unknown>;
      cloudLine: string;
      ok: true;
    }
  | {
      code: 'cloud_projection_drift';
      event_type: string;
      field: string;
      ok: false;
    };

type EnvelopeWithLocal = z.infer<typeof EnvelopeSchema> & {
  _local?: object;
};

const firstIssuePath = (issues: z.core.$ZodIssue[]): string => {
  if (issues.length === 0) return '<unknown>';
  const issue = issues[0];

  return issue.path.length > 0 ? issue.path.join('.') : '<root>';
};

const resolvePayloadSchema = (eventType: string): undefined | z.ZodType => {
  if (MENTORSHIP_TYPE_SET.has(eventType)) {
    return CloudPayloadByType[eventType as CloudEventType];
  }

  if (CLOUD_ONLY_TYPE_SET.has(eventType)) {
    return cloudOnlyPassthroughPayload;
  }

  return undefined;
};

/**
 * Project a mentorship-shaped envelope to a cloud-stream line.
 *
 * Algorithm (per task-cloud-projection.md):
 * 1. Strip `_local`.
 * 2. Validate the envelope shape.
 * 3. Look up the strict cloud payload schema for this event_type.
 * 4. Strict-parse the payload (drift fails loud).
 * 5. Re-attach the parsed (clean) payload.
 * 6. Run a denylist sweep over the stringified line.
 * 7. Return `{ ok: true, cloudEvent, cloudLine }`.
 *
 * Caller (emit-core) maps `{ ok: false }` to `EXIT_CODES.CLOUD_PROJECTION_DRIFT`
 * and writes nothing to either stream (UAT-014 ordering: projection runs
 * BEFORE either write).
 */
const LOCAL_KEY = '_local';

const stripLocal = (
  envelope: EnvelopeWithLocal
): z.infer<typeof EnvelopeSchema> => {
  const cloudEvent: Record<string, unknown> = {...envelope};

  delete cloudEvent[LOCAL_KEY];

  return cloudEvent as z.infer<typeof EnvelopeSchema>;
};

export const projectToCloud = (
  envelope: EnvelopeWithLocal
): ProjectionResult => {
  // 1. Strip `_local`. Spread copy keeps the input immutable.
  const cloudEvent = stripLocal(envelope);

  // 2. Validate envelope shape (catches malformed input early).
  const envelopeResult = EnvelopeSchema.safeParse(cloudEvent);

  if (!envelopeResult.success) {
    return {
      code: 'cloud_projection_drift',
      event_type: cloudEvent.event_type,
      field: firstIssuePath(envelopeResult.error.issues),
      ok: false,
    };
  }

  // 3. Resolve cloud payload schema by event_type.
  const eventType = cloudEvent.event_type;
  const payloadSchema = resolvePayloadSchema(eventType);

  if (payloadSchema === undefined) {
    return {
      code: 'cloud_projection_drift',
      event_type: eventType,
      field: 'event_type',
      ok: false,
    };
  }

  // 4. Strict-parse the payload (drift fails loud per UAT-014).
  const payloadResult = payloadSchema.safeParse(cloudEvent.payload);

  if (!payloadResult.success) {
    return {
      code: 'cloud_projection_drift',
      event_type: eventType,
      field: firstIssuePath(payloadResult.error.issues),
      ok: false,
    };
  }

  // 5. Re-attach the parsed (validated) payload — `.strict()` would have
  //    errored on unknown keys, so success means payload is clean.
  const projected: Record<string, unknown> = {
    ...cloudEvent,
    payload: payloadResult.data,
  };

  // 6. Final denylist sweep (belt-and-suspenders for UAT-013 / UAT-014).
  //    Scan the stringified JSON for any forbidden key appearing in
  //    JSON property-name position (`"<key>":`). This guards against
  //    future drift where a forbidden field name slips through `.strict()`.
  //    Property-name framing avoids substring false positives from value
  //    strings (e.g. `ip` matching `'typescript'`, `email` matching
  //    `'email_subject_ok'`); the boundary we care about is field names.
  const cloudLine = JSON.stringify(projected);
  const forbiddenHit = FORBIDDEN_CLOUD_KEYS.find((key) =>
    cloudLine.includes(`"${key}":`)
  );

  if (forbiddenHit !== undefined) {
    return {
      code: 'cloud_projection_drift',
      event_type: eventType,
      field: forbiddenHit,
      ok: false,
    };
  }

  // 7. Single-line JSON, no trailing newline (writer adds it).
  return {
    cloudEvent: projected,
    cloudLine,
    ok: true,
  };
};

/**
 * Re-export so emit-core can reference the same canonical list when
 * deciding whether an unknown event_type is a cloud-only future-Sequel
 * type vs. an outright unknown event. Drift between this list and
 * emit-core's own copy is a bug; smoke harness asserts equality.
 */
export const KNOWN_CLOUD_ONLY_EVENT_TYPES: readonly KnownCloudOnlyType[] =
  KNOWN_CLOUD_ONLY_TYPES;
