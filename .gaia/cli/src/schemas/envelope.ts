import {z} from 'zod';

export const AgentTypeSchema = z.enum([
  'PO',
  'Senior',
  'Junior',
  'Lead',
  'Reviewer',
  'Curator',
  'Steward',
  'Custodian',
  'human',
]);

export type AgentType = z.infer<typeof AgentTypeSchema>;

const ULID_REGEX = /^[0-9A-HJKMNP-TV-Z]{26}$/;
const ISO8601_UTC_MS_REGEX = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;
const HEX_32_REGEX = /^[0-9a-f]{32}$/;

export const UlidSchema = z.string().regex(ULID_REGEX);

export const Iso8601UtcMsSchema = z.string().regex(ISO8601_UTC_MS_REGEX);

export const Sha256HexHalfSchema = z.string().regex(HEX_32_REGEX);

export const EnvelopeSchema = z.object({
  agent_type: AgentTypeSchema,
  event_id: UlidSchema,
  event_type: z.string(),
  payload: z.unknown(),
  project_id: Sha256HexHalfSchema,
  schema_version: z.literal(1),
  session_hash: Sha256HexHalfSchema,
  timestamp: Iso8601UtcMsSchema,
});

export type Envelope = z.infer<typeof EnvelopeSchema>;
