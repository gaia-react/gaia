/* eslint-disable no-bitwise -- Crockford-base32 encoding requires bitwise
   shifts/masks on the sha256-derived 16-byte seed. No readable alternative. */
import {createHash} from 'node:crypto';
import type {AgentType, Envelope} from '../schemas/envelope.js';

/**
 * Universal envelope returned by `buildEnvelope`. Mentorship-stream events
 * carry the optional `_local` namespace; cloud-stream events project it away.
 */
export type EventEnvelopeWithLocal = Envelope & {_local?: object};

type BuildEnvelopeArgs = {
  agentType: AgentType;
  eventType: string;
  localNamespace?: object;
  now?: Date;
  payload: object;
  projectId: string;
  sessionHash: string;
};

type DeriveEventIdArgs = {
  eventType: string;
  payload: object;
  projectId: string;
  sessionHash: string;
  timestamp: Date;
};

const CROCKFORD_ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/**
 * Encode 16 raw bytes as a 26-char Crockford-base32 string matching the ULID
 * alphabet `[0-9A-HJKMNP-TV-Z]`. ULIDs are 130 bits when fully encoded; we
 * pad the high-order nibble with two zero bits so 16 bytes (128 bits) round
 * to 26 base-32 characters.
 */
const encodeCrockford = (bytes: Uint8Array): string => {
  if (bytes.length !== 16) {
    throw new Error(`expected 16 bytes; got ${bytes.length}`);
  }

  // Build a bit buffer, MSB-first. Two leading zero bits pad to 130 bits.
  let bits = 0n;

  for (const byte of bytes) {
    bits = (bits << 8n) | BigInt(byte);
  }

  // 26 base-32 characters * 5 bits = 130 bits; left-shift by 2 for padding.
  bits <<= 2n;

  let out = '';

  for (let index = 25; index >= 0; index -= 1) {
    const fiveBits = Number((bits >> BigInt(index * 5)) & 0x1fn);
    out += CROCKFORD_ALPHABET[fiveBits];
  }

  return out;
};

/**
 * Stable JSON serialization with sorted keys. Required so that
 * `deriveEventId` is content-addressable across hosts and process restarts.
 */
const stableStringify = (value: unknown): string => {
  if (value === null || typeof value !== 'object') {
    return JSON.stringify(value);
  }

  if (Array.isArray(value)) {
    return `[${value.map((entry) => stableStringify(entry)).join(',')}]`;
  }
  const entries = Object.keys(value).toSorted((a, b) => a.localeCompare(b));
  const body = entries
    .map(
      (key) =>
        `${JSON.stringify(key)}:${stableStringify(
          (value as Record<string, unknown>)[key]
        )}`
    )
    .join(',');

  return `{${body}}`;
};

/**
 * Content-derived ULID:
 *   1. Stable JSON of {event_type, project_id, session_hash, payload, minute}.
 *   2. seed = sha256(canonicalContent), first 16 bytes.
 *   3. Crockford-base32 encode bytes -> 26 chars matching the ULID alphabet.
 *
 * Two emits with the same content within the same minute -> identical ULIDs
 * -> idempotent. Two emits more than a minute apart -> distinct ULIDs.
 */
export const deriveEventId = (args: DeriveEventIdArgs): string => {
  const minute = Math.floor(args.timestamp.getTime() / 60_000);
  const canonical = stableStringify({
    event_type: args.eventType,
    minute,
    payload: args.payload,
    project_id: args.projectId,
    session_hash: args.sessionHash,
  });
  const hash = createHash('sha256').update(canonical).digest();
  const seed = hash.subarray(0, 16);

  return encodeCrockford(seed);
};

/**
 * Format a Date as ISO-8601 UTC with millisecond precision.
 * `Date.prototype.toISOString` already produces this format.
 */
const isoMs = (now: Date): string => now.toISOString();

/**
 * The envelope schema requires `project_id` to be 32-char lowercase hex.
 * `readOrCreateProjectId` returns a UUIDv4 string with hyphens; strip them
 * here so the envelope satisfies the schema while the on-disk file remains
 * human-readable UUIDv4.
 */
const normalizeProjectId = (projectId: string): string =>
  projectId.replaceAll('-', '').toLowerCase();

/**
 * Build the full event envelope. Returns the same shape regardless of stream;
 * `_local` is only attached when `localNamespace` is provided. Cloud projection
 * (sibling task) strips `_local` and any unexpected keys at write time.
 */
export const buildEnvelope = (
  args: BuildEnvelopeArgs
): EventEnvelopeWithLocal => {
  const now = args.now ?? new Date();
  const projectId = normalizeProjectId(args.projectId);
  const eventId = deriveEventId({
    eventType: args.eventType,
    payload: args.payload,
    projectId,
    sessionHash: args.sessionHash,
    timestamp: now,
  });

  const envelope: EventEnvelopeWithLocal = {
    agent_type: args.agentType,
    event_id: eventId,
    event_type: args.eventType,
    payload: args.payload,
    project_id: projectId,
    schema_version: 1,
    session_hash: args.sessionHash,
    timestamp: isoMs(now),
  };

  if (args.localNamespace !== undefined) {
    // `_local` is the SPEC-mandated mentorship-namespace key. Object.assign
    // with a string-key bag attaches the property without tripping the
    // no-underscore-dangle rule that fires on direct member access.
    return Object.assign(envelope, {_local: args.localNamespace});
  }

  return envelope;
};
