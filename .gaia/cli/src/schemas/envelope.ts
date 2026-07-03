import {z} from 'zod';
import {
  MentorshipPayloadByType,
  type MentorshipEventType,
} from './mentorship-payloads.js';

export const AgentTypeSchema = z.literal([
  'Curator',
  'Custodian',
  'human',
  'Junior',
  'Lead',
  'PO',
  'Reviewer',
  'Senior',
  'Steward',
]);

export type AgentType = z.infer<typeof AgentTypeSchema>;

const ULID_REGEX = /^[0-9A-HJKMNP-TV-Z]{26}$/;
const ISO8601_UTC_MS_REGEX = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;
const HEX_32_REGEX = /^[0-9a-f]{32}$/;

export const UlidSchema = z.string().regex(ULID_REGEX);

export const Iso8601UtcMsSchema = z.string().regex(ISO8601_UTC_MS_REGEX);

export const Sha256HexHalfSchema = z.string().regex(HEX_32_REGEX);

const isMentorshipEventType = (
  eventType: string
): eventType is MentorshipEventType =>
  Object.hasOwn(MentorshipPayloadByType, eventType);

/**
 * Universal event envelope. `payload` is `unknown` at the field level
 * because cloud-only event types (`pr_opened`, etc.) have no per-type
 * schema in v1. The `superRefine` below cross-validates the payload
 * against `event_type`: for any known mentorship event type the payload
 * MUST satisfy that type's schema in `MentorshipPayloadByType`. Unknown
 * event types keep an unconstrained payload; projection's strict cloud
 * schemas (`telemetry/projection.ts`) own that boundary.
 */
export const EnvelopeSchema = z
  .object({
    agent_type: AgentTypeSchema,
    event_id: UlidSchema,
    event_type: z.string(),
    payload: z.unknown(),
    project_id: Sha256HexHalfSchema,
    schema_version: z.literal(1),
    session_hash: Sha256HexHalfSchema,
    timestamp: Iso8601UtcMsSchema,
  })
  .superRefine((envelope, ctx) => {
    if (!isMentorshipEventType(envelope.event_type)) return;

    const payloadSchema = MentorshipPayloadByType[envelope.event_type];
    const result = payloadSchema.safeParse(envelope.payload);

    if (result.success) return;

    for (const issue of result.error.issues) {
      ctx.addIssue({
        code: 'custom',
        message: issue.message,
        path: ['payload', ...issue.path],
      });
    }
  });

export type Envelope = z.infer<typeof EnvelopeSchema>;
