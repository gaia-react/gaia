import {describe, expect, test} from 'vitest';
import {z} from 'zod';
import {
  BlockedReturnedPayload,
  CodeReviewAuditFindingPayload,
  MENTORSHIP_EVENT_TYPES,
  MentorshipPayloadByType,
  NeedsContextReturnedPayload,
  PlanRevisedPayload,
  SpecAmendedPayload,
  TimeToResolvedSpecPayload,
  UatFailPayload,
  UatPassPayload,
} from '../mentorship-payloads.js';

describe('schemas/mentorship-payloads', () => {
  describe('UatPassPayload', () => {
    test('accepts a fully-populated good case', () => {
      expect(() =>
        UatPassPayload.parse({
          area_tags: ['visual', 'react', 'form'],
          attempts: 1,
          spec_id: 'SPEC-014',
          task_id: 'TASK-093',
          uat_id: 'UAT-007',
        })
      ).not.toThrow();
    });

    test('rejects when required fields are missing', () => {
      expect(() => UatPassPayload.parse({uat_id: 'UAT-007'})).toThrow(
        z.ZodError
      );
    });

    test('rejects malformed UAT id', () => {
      expect(() =>
        UatPassPayload.parse({
          area_tags: ['visual'],
          attempts: 1,
          spec_id: 'SPEC-014',
          task_id: 'TASK-093',
          uat_id: 'uat-7',
        })
      ).toThrow(z.ZodError);
    });

    test('rejects empty area_tags', () => {
      expect(() =>
        UatPassPayload.parse({
          area_tags: [],
          attempts: 1,
          spec_id: 'SPEC-014',
          task_id: 'TASK-093',
          uat_id: 'UAT-007',
        })
      ).toThrow(z.ZodError);
    });

    test('rejects attempts < 1', () => {
      expect(() =>
        UatPassPayload.parse({
          area_tags: ['visual'],
          attempts: 0,
          spec_id: 'SPEC-014',
          task_id: 'TASK-093',
          uat_id: 'UAT-007',
        })
      ).toThrow(z.ZodError);
    });
  });

  describe('UatFailPayload', () => {
    test('accepts a good case with valid failure_class', () => {
      expect(() =>
        UatFailPayload.parse({
          area_tags: ['react'],
          attempts: 1,
          failure_class: 'exception',
          spec_id: 'SPEC-014',
          task_id: 'TASK-093',
          uat_id: 'UAT-007',
        })
      ).not.toThrow();
    });

    test('rejects unknown failure_class', () => {
      expect(() =>
        UatFailPayload.parse({
          area_tags: ['react'],
          attempts: 1,
          failure_class: 'unknown',
          spec_id: 'SPEC-014',
          task_id: 'TASK-093',
          uat_id: 'UAT-007',
        })
      ).toThrow(z.ZodError);
    });
  });

  describe('NeedsContextReturnedPayload', () => {
    test('accepts a good case', () => {
      expect(() =>
        NeedsContextReturnedPayload.parse({
          agent_type: 'Senior',
          area_tags: ['visual'],
          context_request_class: 'unclear_acceptance_criteria',
          spec_id: 'SPEC-014',
          task_id: 'TASK-093',
        })
      ).not.toThrow();
    });

    test('rejects unknown context_request_class', () => {
      expect(() =>
        NeedsContextReturnedPayload.parse({
          agent_type: 'Senior',
          area_tags: ['visual'],
          context_request_class: 'bogus_class',
          spec_id: 'SPEC-014',
          task_id: 'TASK-093',
        })
      ).toThrow(z.ZodError);
    });
  });

  describe('BlockedReturnedPayload', () => {
    test.each(['intent', 'spec', 'code'])(
      'accepts classification: %s',
      (classification) => {
        expect(() =>
          BlockedReturnedPayload.parse({
            agent_type: 'Senior',
            area_tags: ['react'],
            classification,
            spec_id: 'SPEC-014',
            task_id: 'TASK-093',
          })
        ).not.toThrow();
      }
    );

    test('rejects unknown classification', () => {
      expect(() =>
        BlockedReturnedPayload.parse({
          agent_type: 'Senior',
          area_tags: ['react'],
          classification: 'process',
          spec_id: 'SPEC-014',
          task_id: 'TASK-093',
        })
      ).toThrow(z.ZodError);
    });
  });

  describe('SpecAmendedPayload', () => {
    test('accepts a good case', () => {
      expect(() =>
        SpecAmendedPayload.parse({
          amendment_reason: 'add missed empty-state UAT',
          fields_changed: ['uats'],
          spec_id: 'SPEC-014',
          time_since_close_seconds: 14_400,
        })
      ).not.toThrow();
    });

    test('rejects empty fields_changed', () => {
      expect(() =>
        SpecAmendedPayload.parse({
          amendment_reason: 'reason',
          fields_changed: [],
          spec_id: 'SPEC-014',
          time_since_close_seconds: 1,
        })
      ).toThrow(z.ZodError);
    });

    test('rejects unknown field name', () => {
      expect(() =>
        SpecAmendedPayload.parse({
          amendment_reason: 'reason',
          fields_changed: ['title'],
          spec_id: 'SPEC-014',
          time_since_close_seconds: 1,
        })
      ).toThrow(z.ZodError);
    });
  });

  describe('PlanRevisedPayload', () => {
    test('accepts a good case', () => {
      expect(() =>
        PlanRevisedPayload.parse({
          items_added: 2,
          items_removed: 0,
          plan_id: 'plan-001',
          revision_class: 'scope_change',
          spec_id: 'SPEC-014',
        })
      ).not.toThrow();
    });

    test('rejects unknown revision_class', () => {
      expect(() =>
        PlanRevisedPayload.parse({
          items_added: 0,
          items_removed: 0,
          plan_id: 'plan-001',
          revision_class: 'unknown',
          spec_id: 'SPEC-014',
        })
      ).toThrow(z.ZodError);
    });

    test('rejects negative items_added', () => {
      expect(() =>
        PlanRevisedPayload.parse({
          items_added: -1,
          items_removed: 0,
          plan_id: 'plan-001',
          revision_class: 'scope_change',
          spec_id: 'SPEC-014',
        })
      ).toThrow(z.ZodError);
    });
  });

  describe('TimeToResolvedSpecPayload', () => {
    test('accepts a good case', () => {
      expect(() =>
        TimeToResolvedSpecPayload.parse({
          abandoned: false,
          area_tags: ['visual'],
          duration_seconds: 1850,
          question_count: 12,
          spec_id: 'SPEC-014',
        })
      ).not.toThrow();
    });

    test('rejects non-boolean abandoned', () => {
      expect(() =>
        TimeToResolvedSpecPayload.parse({
          abandoned: 'no',
          area_tags: ['visual'],
          duration_seconds: 1850,
          question_count: 12,
          spec_id: 'SPEC-014',
        })
      ).toThrow(z.ZodError);
    });
  });

  describe('CodeReviewAuditFindingPayload', () => {
    test('accepts a good case (with optional spec_id)', () => {
      expect(() =>
        CodeReviewAuditFindingPayload.parse({
          area_tags: ['typescript'],
          auditor_type: 'code-review-audit',
          finding_class: 'react-doctor/no-generic-handler-names',
          pr_number: 42,
          severity: 'warning',
          spec_id: 'SPEC-014',
        })
      ).not.toThrow();
    });

    test('accepts a good case omitting optional spec_id', () => {
      expect(() =>
        CodeReviewAuditFindingPayload.parse({
          area_tags: ['typescript'],
          auditor_type: 'code-review-audit',
          finding_class: 'holistic/missing-auth-check',
          pr_number: 42,
          severity: 'warning',
        })
      ).not.toThrow();
    });

    test('rejects pr_number < 1', () => {
      expect(() =>
        CodeReviewAuditFindingPayload.parse({
          area_tags: ['typescript'],
          auditor_type: 'code-review-audit',
          finding_class: 'axe/color-contrast',
          pr_number: 0,
          severity: 'warning',
        })
      ).toThrow(z.ZodError);
    });

    test('rejects unknown severity', () => {
      expect(() =>
        CodeReviewAuditFindingPayload.parse({
          area_tags: ['typescript'],
          auditor_type: 'code-review-audit',
          finding_class: 'axe/color-contrast',
          pr_number: 42,
          severity: 'critical',
        })
      ).toThrow(z.ZodError);
    });

    test('rejects a free-text finding_class (drift)', () => {
      expect(() =>
        CodeReviewAuditFindingPayload.parse({
          area_tags: ['typescript'],
          auditor_type: 'code-review-audit',
          finding_class: 'type_hole',
          pr_number: 42,
          severity: 'warning',
        })
      ).toThrow(z.ZodError);
    });

    test('rejects an unseeded holistic finding_class', () => {
      expect(() =>
        CodeReviewAuditFindingPayload.parse({
          area_tags: ['typescript'],
          auditor_type: 'code-review-audit',
          finding_class: 'holistic/something-made-up',
          pr_number: 42,
          severity: 'warning',
        })
      ).toThrow(z.ZodError);
    });
  });

  describe('MentorshipPayloadByType', () => {
    test('exposes all eight event types', () => {
      expect(MENTORSHIP_EVENT_TYPES).toHaveLength(8);
      expect(new Set(MENTORSHIP_EVENT_TYPES)).toEqual(
        new Set([
          'blocked_returned',
          'code_review_audit_finding',
          'needs_context_returned',
          'plan_revised',
          'spec_amended',
          'time_to_resolved_spec',
          'uat_fail',
          'uat_pass',
        ])
      );
    });

    test('maps every event type to a Zod schema', () => {
      for (const eventType of MENTORSHIP_EVENT_TYPES) {
        expect(typeof MentorshipPayloadByType[eventType].parse).toBe(
          'function'
        );
      }
    });
  });
});
