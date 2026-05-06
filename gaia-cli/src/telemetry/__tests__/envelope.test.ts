/* eslint-disable no-underscore-dangle -- `_local` is the SPEC-mandated
   mentorship-namespace key. */
import {describe, expect, test} from 'vitest';
import {EnvelopeSchema} from '../../schemas/envelope.js';
import {buildEnvelope, deriveEventId} from '../envelope.js';

const PROJECT_ID = 'a'.repeat(32);
const SESSION_HASH = 'b'.repeat(32);

describe('deriveEventId', () => {
  test('returns a 26-char Crockford-base32 ULID', () => {
    const eventId = deriveEventId({
      eventType: 'uat_pass',
      payload: {uat_id: 'UAT-007'},
      projectId: PROJECT_ID,
      sessionHash: SESSION_HASH,
      timestamp: new Date('2026-05-07T00:00:00.000Z'),
    });

    expect(eventId).toMatch(/^[0-9A-HJKMNP-TV-Z]{26}$/u);
  });

  test('is deterministic for identical inputs (same minute floor)', () => {
    const a = deriveEventId({
      eventType: 'uat_pass',
      payload: {uat_id: 'UAT-007'},
      projectId: PROJECT_ID,
      sessionHash: SESSION_HASH,
      timestamp: new Date('2026-05-07T00:00:15.000Z'),
    });
    const b = deriveEventId({
      eventType: 'uat_pass',
      payload: {uat_id: 'UAT-007'},
      projectId: PROJECT_ID,
      sessionHash: SESSION_HASH,
      timestamp: new Date('2026-05-07T00:00:55.000Z'),
    });

    expect(a).toBe(b);
  });

  test('differs across minute boundaries', () => {
    const a = deriveEventId({
      eventType: 'uat_pass',
      payload: {uat_id: 'UAT-007'},
      projectId: PROJECT_ID,
      sessionHash: SESSION_HASH,
      timestamp: new Date('2026-05-07T00:00:30.000Z'),
    });
    const b = deriveEventId({
      eventType: 'uat_pass',
      payload: {uat_id: 'UAT-007'},
      projectId: PROJECT_ID,
      sessionHash: SESSION_HASH,
      timestamp: new Date('2026-05-07T00:01:30.000Z'),
    });

    expect(a).not.toBe(b);
  });

  test('differs when payload differs', () => {
    const a = deriveEventId({
      eventType: 'uat_pass',
      payload: {uat_id: 'UAT-007'},
      projectId: PROJECT_ID,
      sessionHash: SESSION_HASH,
      timestamp: new Date('2026-05-07T00:00:00.000Z'),
    });
    const b = deriveEventId({
      eventType: 'uat_pass',
      payload: {uat_id: 'UAT-008'},
      projectId: PROJECT_ID,
      sessionHash: SESSION_HASH,
      timestamp: new Date('2026-05-07T00:00:00.000Z'),
    });

    expect(a).not.toBe(b);
  });

  test('is invariant under payload key ordering (stable JSON)', () => {
    // Build two payloads with the same keys/values but different insertion
    // orders. Object key iteration order in JS is insertion order, so a
    // naive `JSON.stringify` would yield different strings; the stable
    // serializer in `envelope.ts` sorts keys before hashing.
    const orderA: Record<string, unknown> = {
      attempts: 1,
      spec_id: 'SPEC-014',
      uat_id: 'UAT-007',
    };

    const orderB: Record<string, unknown> = {
      attempts: 1,
      spec_id: 'SPEC-014',
      uat_id: 'UAT-007',
    };

    const a = deriveEventId({
      eventType: 'uat_pass',
      payload: orderA,
      projectId: PROJECT_ID,
      sessionHash: SESSION_HASH,
      timestamp: new Date('2026-05-07T00:00:00.000Z'),
    });
    const b = deriveEventId({
      eventType: 'uat_pass',
      payload: orderB,
      projectId: PROJECT_ID,
      sessionHash: SESSION_HASH,
      timestamp: new Date('2026-05-07T00:00:00.000Z'),
    });

    expect(a).toBe(b);
  });
});

describe('buildEnvelope', () => {
  test('produces an envelope that satisfies EnvelopeSchema', () => {
    const envelope = buildEnvelope({
      agentType: 'Senior',
      eventType: 'uat_pass',
      now: new Date('2026-05-07T12:34:56.789Z'),
      payload: {
        area_tags: ['react'],
        attempts: 1,
        spec_id: 'SPEC-014',
        task_id: 'TASK-093',
        uat_id: 'UAT-007',
      },
      projectId: PROJECT_ID,
      sessionHash: SESSION_HASH,
    });

    expect(() => EnvelopeSchema.parse(envelope)).not.toThrow();
    expect(envelope.schema_version).toBe(1);
    expect(envelope.timestamp).toBe('2026-05-07T12:34:56.789Z');
    expect(envelope.agent_type).toBe('Senior');
    expect(envelope.event_type).toBe('uat_pass');
  });

  test('attaches _local only when localNamespace is provided', () => {
    const without = buildEnvelope({
      agentType: 'human',
      eventType: 'uat_pass',
      now: new Date('2026-05-07T12:34:56.789Z'),
      payload: {area_tags: ['react']},
      projectId: PROJECT_ID,
      sessionHash: SESSION_HASH,
    });

    expect('_local' in without).toBe(false);

    const withNamespace = buildEnvelope({
      agentType: 'human',
      eventType: 'uat_pass',
      localNamespace: {git_author_email: 'dev@example.com'},
      now: new Date('2026-05-07T12:34:56.789Z'),
      payload: {area_tags: ['react']},
      projectId: PROJECT_ID,
      sessionHash: SESSION_HASH,
    });

    expect(withNamespace._local).toEqual({git_author_email: 'dev@example.com'});
  });

  test('normalizes a UUIDv4-formatted projectId to 32-char hex', () => {
    const envelope = buildEnvelope({
      agentType: 'human',
      eventType: 'uat_pass',
      now: new Date('2026-05-07T12:34:56.789Z'),
      payload: {area_tags: ['react']},
      projectId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      sessionHash: SESSION_HASH,
    });

    expect(envelope.project_id).toBe('aaaaaaaaaaaa4aaa8aaaaaaaaaaaaaaa');
    expect(envelope.project_id).toMatch(/^[0-9a-f]{32}$/u);
  });
});
