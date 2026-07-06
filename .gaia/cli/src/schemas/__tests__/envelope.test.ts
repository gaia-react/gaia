import {describe, expect, test} from 'vitest';
import {z} from 'zod';
import assert from 'node:assert/strict';
import {
  AgentTypeSchema,
  EnvelopeSchema,
  Iso8601UtcMsSchema,
  Sha256HexHalfSchema,
  UlidSchema,
} from '../envelope.js';

const VALID_ULID = '01HZX0K3Q9JSAWC0TR6WYJ5ZNT';
const VALID_ISO = '2026-05-06T12:34:56.789Z';
const VALID_HEX_32 = 'a'.repeat(32);

describe('schemas/envelope', () => {
  describe('UlidSchema', () => {
    test('accepts a 26-char Crockford-base32 ULID', () => {
      expect(() => UlidSchema.parse(VALID_ULID)).not.toThrow();
    });

    test('rejects lowercase letters', () => {
      expect(() => UlidSchema.parse('01hzx0k3q9jsawc0tr6wyj5znt')).toThrow(
        z.ZodError
      );
    });

    test('rejects forbidden ULID alphabet letters (I, L, O, U)', () => {
      expect(() => UlidSchema.parse('01HZX0K3Q9JSAWC0TR6WYJ5ZNI')).toThrow(
        z.ZodError
      );
    });

    test('rejects wrong length', () => {
      expect(() => UlidSchema.parse('01HZX')).toThrow(z.ZodError);
    });
  });

  describe('Iso8601UtcMsSchema', () => {
    test('accepts ISO-8601 UTC with millisecond precision', () => {
      expect(() => Iso8601UtcMsSchema.parse(VALID_ISO)).not.toThrow();
    });

    test('rejects timestamps without milliseconds', () => {
      expect(() => Iso8601UtcMsSchema.parse('2026-05-06T12:34:56Z')).toThrow(
        z.ZodError
      );
    });

    test('rejects timestamps with timezone offset', () => {
      expect(() =>
        Iso8601UtcMsSchema.parse('2026-05-06T12:34:56.789+00:00')
      ).toThrow(z.ZodError);
    });
  });

  describe('Sha256HexHalfSchema', () => {
    test('accepts 32 lowercase hex chars', () => {
      expect(() => Sha256HexHalfSchema.parse(VALID_HEX_32)).not.toThrow();
    });

    test('rejects uppercase hex', () => {
      expect(() => Sha256HexHalfSchema.parse('A'.repeat(32))).toThrow(
        z.ZodError
      );
    });

    test('rejects wrong length', () => {
      expect(() => Sha256HexHalfSchema.parse('a'.repeat(31))).toThrow(
        z.ZodError
      );
    });
  });

  describe('AgentTypeSchema', () => {
    test.each([
      'PO',
      'Senior',
      'Junior',
      'Lead',
      'Reviewer',
      'Curator',
      'Steward',
      'Custodian',
      'human',
    ])('accepts %s', (agentType) => {
      expect(() => AgentTypeSchema.parse(agentType)).not.toThrow();
    });

    test('rejects unknown agent types', () => {
      expect(() => AgentTypeSchema.parse('engineer')).toThrow(z.ZodError);
    });
  });

  describe('EnvelopeSchema', () => {
    const validUatPassPayload = {
      area_tags: ['react'],
      attempts: 1,
      spec_id: 'SPEC-014',
      task_id: 'TASK-093',
      uat_id: 'UAT-007',
    };

    const validEnvelope = {
      agent_type: 'Senior',
      event_id: VALID_ULID,
      event_type: 'uat_pass',
      payload: validUatPassPayload,
      project_id: VALID_HEX_32,
      schema_version: 1,
      session_hash: VALID_HEX_32,
      timestamp: VALID_ISO,
    };

    test('accepts a hand-constructed example matching the SPEC snippet', () => {
      expect(() => EnvelopeSchema.parse(validEnvelope)).not.toThrow();
    });

    test('rejects a payload that does not match its mentorship event_type', () => {
      expect(() =>
        EnvelopeSchema.parse({
          ...validEnvelope,
          payload: {anything: 'goes-here'},
        })
      ).toThrow(z.ZodError);
    });

    test('reports the drift under the payload path', () => {
      const result = EnvelopeSchema.safeParse({
        ...validEnvelope,
        payload: {...validUatPassPayload, uat_id: 'not-a-uat-id'},
      });
      expect(result.success).toBe(false);
      assert.ok(!result.success);

      expect(
        result.error.issues.some((issue) => issue.path[0] === 'payload')
      ).toBe(true);
    });

    test('leaves the payload unconstrained for non-mentorship event_types', () => {
      expect(() =>
        EnvelopeSchema.parse({
          ...validEnvelope,
          event_type: 'pr_opened',
          payload: {anything: 'goes-here'},
        })
      ).not.toThrow();
    });

    test('rejects schema_version != 1', () => {
      expect(() =>
        EnvelopeSchema.parse({...validEnvelope, schema_version: 2})
      ).toThrow(z.ZodError);
    });

    test('rejects an invalid project_id', () => {
      expect(() =>
        EnvelopeSchema.parse({
          ...validEnvelope,
          project_id: 'not-a-hex-string',
        })
      ).toThrow(z.ZodError);
    });

    test('rejects an invalid agent_type', () => {
      expect(() =>
        EnvelopeSchema.parse({
          ...validEnvelope,
          agent_type: 'Engineer',
        })
      ).toThrow(z.ZodError);
    });
  });
});
