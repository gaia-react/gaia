import {describe, expect, test} from 'vitest';
import {FORBIDDEN_CLOUD_KEYS} from '../../schemas/cloud-projection.js';
import {KNOWN_CLOUD_ONLY_EVENT_TYPES, projectToCloud} from '../projection.js';

const VALID_ULID = '01HZX0K3Q9JSAWC0TR6WYJ5ZNT';
const VALID_ISO = '2026-05-06T12:34:56.789Z';
const VALID_HEX_32 = 'a'.repeat(32);

const baseEnvelope = {
  agent_type: 'Senior' as const,
  event_id: VALID_ULID,
  event_type: 'uat_pass',
  payload: {
    area_tags: ['react'],
    attempts: 1,
    spec_id: 'SPEC-014',
    task_id: 'TASK-093',
    uat_id: 'UAT-007',
  },
  project_id: VALID_HEX_32,
  schema_version: 1 as const,
  session_hash: VALID_HEX_32,
  timestamp: VALID_ISO,
};

describe('projectToCloud', () => {
  describe('UAT-013 — required cloud tags + zero forbidden fields', () => {
    test('projects a uat_pass envelope to a cloud line containing the five required tags', () => {
      const result = projectToCloud(baseEnvelope);

      expect(result.ok).toBe(true);

      if (!result.ok) return;

      expect(result.cloudEvent).toMatchObject({
        agent_type: 'Senior',
        event_type: 'uat_pass',
        project_id: VALID_HEX_32,
        session_hash: VALID_HEX_32,
        timestamp: VALID_ISO,
      });
    });

    test('cloud line is a single-line JSON string with no trailing newline', () => {
      const result = projectToCloud(baseEnvelope);

      expect(result.ok).toBe(true);

      if (!result.ok) return;

      expect(result.cloudLine).toBe(JSON.stringify(result.cloudEvent));
      expect(result.cloudLine.includes('\n')).toBe(false);
    });

    test('strips `_local` cleanly even when it carries identity-bearing fields', () => {
      const envelopeWithLocal = {
        ...baseEnvelope,
        _local: {git_author_email: 'leak@example.com'},
      };

      const result = projectToCloud(envelopeWithLocal);

      expect(result.ok).toBe(true);

      if (!result.ok) return;

      // `_local` and its values must not appear anywhere in the cloud line.
      expect('_local' in result.cloudEvent).toBe(false);
      expect(result.cloudLine.includes('_local')).toBe(false);
      expect(result.cloudLine.includes('git_author_email')).toBe(false);
      expect(result.cloudLine.includes('leak@example.com')).toBe(false);
    });

    test('strips `_local` cleanly when its contents are benign', () => {
      const envelopeWithBenignLocal = {
        ...baseEnvelope,
        _local: {extra_diagnostic: 'safe-string'},
      };

      const result = projectToCloud(envelopeWithBenignLocal);

      expect(result.ok).toBe(true);

      if (!result.ok) return;

      expect('_local' in result.cloudEvent).toBe(false);
      expect(result.cloudLine.includes('_local')).toBe(false);
      expect(result.cloudLine.includes('safe-string')).toBe(false);
    });
  });

  describe('UAT-014 — fail loud on drift', () => {
    test('rejects an envelope whose payload carries an unexpected field', () => {
      const envelopeWithDrift = {
        ...baseEnvelope,
        payload: {
          ...baseEnvelope.payload,
          email: 'leak@example.com',
        },
      };

      const result = projectToCloud(envelopeWithDrift);

      expect(result.ok).toBe(false);

      if (result.ok) return;

      expect(result.code).toBe('cloud_projection_drift');
      expect(result.event_type).toBe('uat_pass');
      expect(result.field).toBeTruthy();
    });

    test('reports the drifting field path', () => {
      const envelopeWithDrift = {
        ...baseEnvelope,
        payload: {
          ...baseEnvelope.payload,
          surprise_field: 'oops',
        },
      };

      const result = projectToCloud(envelopeWithDrift);

      expect(result.ok).toBe(false);

      if (result.ok) return;

      expect(result.field.length).toBeGreaterThan(0);
    });

    test('rejects unknown event_type', () => {
      const envelopeWithUnknownType = {
        ...baseEnvelope,
        event_type: 'utterly_unknown_event',
      };

      const result = projectToCloud(envelopeWithUnknownType);

      expect(result.ok).toBe(false);

      if (result.ok) return;

      expect(result.code).toBe('cloud_projection_drift');
      expect(result.event_type).toBe('utterly_unknown_event');
      expect(result.field).toBe('event_type');
    });

    test('rejects malformed envelope (bad project_id)', () => {
      const envelopeWithBadId = {
        ...baseEnvelope,
        project_id: 'not-hex',
      };

      const result = projectToCloud(envelopeWithBadId);

      expect(result.ok).toBe(false);

      if (result.ok) return;

      expect(result.code).toBe('cloud_projection_drift');
      expect(result.field).toBe('project_id');
    });

    test('rejects malformed envelope (bad timestamp precision)', () => {
      const envelopeWithBadTimestamp = {
        ...baseEnvelope,
        timestamp: '2026-05-06T12:34:56Z',
      };

      const result = projectToCloud(envelopeWithBadTimestamp);

      expect(result.ok).toBe(false);

      if (result.ok) return;

      expect(result.field).toBe('timestamp');
    });

    test('returns a string event_type even when event_type is absent', () => {
      // event_type missing -> envelope parse fails. The drift result's
      // event_type field is typed `string`; it must not be `undefined`.
      const {event_type: _omitted, ...withoutType} = baseEnvelope;
      const result = projectToCloud(
        withoutType as unknown as typeof baseEnvelope
      );

      expect(result.ok).toBe(false);

      if (result.ok) return;

      expect(typeof result.event_type).toBe('string');
    });

    test('returns a string event_type when event_type is a non-string', () => {
      const envelopeWithNonStringType = {
        ...baseEnvelope,
        event_type: 42,
      };

      const result = projectToCloud(
        envelopeWithNonStringType as unknown as typeof baseEnvelope
      );

      expect(result.ok).toBe(false);

      if (result.ok) return;

      expect(typeof result.event_type).toBe('string');
    });
  });

  describe('denylist sweep (belt-and-suspenders)', () => {
    test('does not false-positive on forbidden-key substrings in value strings', () => {
      // The denylist scans for `"<key>":` (property-name position), not
      // raw substrings — otherwise common values like `'typescript'`
      // (contains `ip`) would trip every cloud line. This test pins
      // that boundary: a clean payload whose values incidentally
      // contain forbidden-key substrings still projects successfully.
      const envelope = {
        ...baseEnvelope,
        payload: {
          area_tags: ['typescript', 'recipient'], // 'ip' substring
          attempts: 1,
          spec_id: 'SPEC-014',
          task_id: 'TASK-093',
          uat_id: 'UAT-007',
        },
      };

      const result = projectToCloud(envelope);

      expect(result.ok).toBe(true);
    });

    test('catches a forbidden field name appearing as a JSON property', () => {
      // Pathological case: imagine a future schema drift where
      // `cloudPayloadSchema` somehow lets through a `hostname` field
      // (e.g. a Sequel feature's passthrough() registration mistakenly
      // permits it). Pre-construct that line by tunneling through
      // `as unknown as` casts to confirm the denylist sweep traps it.
      const envelope = {
        ...baseEnvelope,
        event_type: 'pr_opened', // cloud-only, uses passthrough payload
        payload: {
          hostname: 'leaked-hostname',
          pr_number: 42,
        },
      };

      const result = projectToCloud(envelope);

      expect(result.ok).toBe(false);

      if (result.ok) return;

      expect(result.code).toBe('cloud_projection_drift');
      expect(FORBIDDEN_CLOUD_KEYS).toContain(result.field);
      expect(result.field).toBe('hostname');
    });

    test('catches a forbidden field name in a cloud-only passthrough payload', () => {
      const envelope = {
        ...baseEnvelope,
        event_type: 'pr_merged',
        payload: {
          email: 'leaked@example.com',
          pr_number: 42,
        },
      };

      const result = projectToCloud(envelope);

      expect(result.ok).toBe(false);

      if (result.ok) return;

      expect(result.code).toBe('cloud_projection_drift');
      expect(result.field).toBe('email');
    });
  });

  describe('happy paths across mentorship event types', () => {
    test('projects a code_review_audit_finding envelope cleanly', () => {
      const envelope = {
        ...baseEnvelope,
        agent_type: 'Reviewer' as const,
        event_type: 'code_review_audit_finding',
        payload: {
          area_tags: ['typescript'],
          auditor_type: 'code-review-audit',
          finding_class: 'type_hole',
          pr_number: 42,
          severity: 'warning',
        },
      };

      const result = projectToCloud(envelope);

      expect(result.ok).toBe(true);

      if (!result.ok) return;

      expect(result.cloudEvent.event_type).toBe('code_review_audit_finding');
      expect(result.cloudEvent.payload).toMatchObject({
        area_tags: ['typescript'],
        finding_class: 'type_hole',
        pr_number: 42,
      });
    });

    test('projects a plan_revised envelope cleanly', () => {
      const envelope = {
        ...baseEnvelope,
        agent_type: 'Lead' as const,
        event_type: 'plan_revised',
        payload: {
          items_added: 2,
          items_removed: 0,
          plan_id: 'plan-001',
          revision_class: 'scope_change',
          spec_id: 'SPEC-014',
        },
      };

      const result = projectToCloud(envelope);

      expect(result.ok).toBe(true);

      if (!result.ok) return;

      expect(result.cloudEvent.payload).toMatchObject({
        items_added: 2,
        revision_class: 'scope_change',
      });
    });
  });

  describe('cloud-only event types (Sequel features)', () => {
    test('passes a known cloud-only event_type through with passthrough payload', () => {
      const envelope = {
        ...baseEnvelope,
        agent_type: 'Reviewer' as const,
        event_type: 'pr_opened',
        payload: {
          pr_number: 42,
          repo: 'gaia-react/gaia',
        },
      };

      const result = projectToCloud(envelope);

      expect(result.ok).toBe(true);

      if (!result.ok) return;

      expect(result.cloudEvent.event_type).toBe('pr_opened');
    });
  });

  describe('KNOWN_CLOUD_ONLY_EVENT_TYPES', () => {
    test('lists the v1 Sequel-feature cloud event types', () => {
      // Spot-check key entries; full equality lives in the smoke harness
      // (Phase 6) where it cross-checks emit-core's own list.
      expect(KNOWN_CLOUD_ONLY_EVENT_TYPES).toContain('pr_opened');
      expect(KNOWN_CLOUD_ONLY_EVENT_TYPES).toContain('pr_merged');
      expect(KNOWN_CLOUD_ONLY_EVENT_TYPES).toContain('skill_loaded');
    });
  });
});
