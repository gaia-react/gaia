import {describe, expect, it} from 'vitest';
import {
  BlockedReturnedCloudPayload,
  CloudPayloadByType,
  CodeReviewAuditFindingCloudPayload,
  FORBIDDEN_CLOUD_KEYS,
  NeedsContextReturnedCloudPayload,
  PlanRevisedCloudPayload,
  SpecAmendedCloudPayload,
  TimeToResolvedSpecCloudPayload,
  UatFailCloudPayload,
  UatPassCloudPayload,
} from '../cloud-projection.js';

const goodUatPass = {
  area_tags: ['react'],
  attempts: 1,
  spec_id: 'SPEC-014',
  task_id: 'TASK-093',
  uat_id: 'UAT-007',
};

describe('schemas/cloud-projection', () => {
  describe('strict-mode rejection (UAT-014)', () => {
    it('rejects unknown keys on UatPassCloudPayload', () => {
      expect(() =>
        UatPassCloudPayload.parse({...goodUatPass, surprise: 1})
      ).toThrow();
    });

    it('rejects unknown keys on UatFailCloudPayload', () => {
      expect(() =>
        UatFailCloudPayload.parse({
          ...goodUatPass,
          email: 'leak@example.com',
          failure_class: 'exception',
        })
      ).toThrow();
    });

    it('rejects unknown keys on NeedsContextReturnedCloudPayload', () => {
      expect(() =>
        NeedsContextReturnedCloudPayload.parse({
          agent_type: 'Senior',
          area_tags: ['react'],
          context_request_class: 'unclear_acceptance_criteria',
          spec_id: 'SPEC-014',
          stowaway: true,
          task_id: 'TASK-093',
        })
      ).toThrow();
    });

    it('rejects unknown keys on BlockedReturnedCloudPayload', () => {
      expect(() =>
        BlockedReturnedCloudPayload.parse({
          agent_type: 'Senior',
          area_tags: ['react'],
          classification: 'intent',
          extra: 'field',
          spec_id: 'SPEC-014',
          task_id: 'TASK-093',
        })
      ).toThrow();
    });

    it('rejects unknown keys on SpecAmendedCloudPayload', () => {
      expect(() =>
        SpecAmendedCloudPayload.parse({
          amendment_reason: 'reason',
          fields_changed: ['uats'],
          machine_id: 'leak',
          spec_id: 'SPEC-014',
          time_since_close_seconds: 1,
        })
      ).toThrow();
    });

    it('rejects unknown keys on PlanRevisedCloudPayload', () => {
      expect(() =>
        PlanRevisedCloudPayload.parse({
          hostname: 'leak',
          items_added: 1,
          items_removed: 0,
          plan_id: 'plan-001',
          revision_class: 'scope_change',
          spec_id: 'SPEC-014',
        })
      ).toThrow();
    });

    it('rejects unknown keys on TimeToResolvedSpecCloudPayload', () => {
      expect(() =>
        TimeToResolvedSpecCloudPayload.parse({
          abandoned: false,
          area_tags: ['react'],
          author_email: 'leak@example.com',
          duration_seconds: 100,
          question_count: 2,
          spec_id: 'SPEC-014',
        })
      ).toThrow();
    });

    it('rejects unknown keys on CodeReviewAuditFindingCloudPayload', () => {
      expect(() =>
        CodeReviewAuditFindingCloudPayload.parse({
          area_tags: ['typescript'],
          auditor_type: 'code-review-audit',
          finding_class: 'axe/color-contrast',
          ip: '127.0.0.1',
          pr_number: 42,
          severity: 'warning',
        })
      ).toThrow();
    });

    it('rejects a free-text finding_class on CodeReviewAuditFindingCloudPayload', () => {
      expect(() =>
        CodeReviewAuditFindingCloudPayload.parse({
          area_tags: ['typescript'],
          auditor_type: 'code-review-audit',
          finding_class: 'type_hole',
          pr_number: 42,
          severity: 'warning',
        })
      ).toThrow();
    });
  });

  describe('happy paths', () => {
    it('accepts a clean uat_pass cloud payload', () => {
      expect(() => UatPassCloudPayload.parse(goodUatPass)).not.toThrow();
    });

    it('accepts a clean code_review_audit_finding (with optional spec_id)', () => {
      expect(() =>
        CodeReviewAuditFindingCloudPayload.parse({
          area_tags: ['typescript'],
          auditor_type: 'code-review-audit',
          finding_class: 'cve/1098765',
          pr_number: 42,
          severity: 'warning',
        })
      ).not.toThrow();
    });
  });

  describe('CloudPayloadByType', () => {
    it('exposes all eight event types', () => {
      const eventTypes = Object.keys(CloudPayloadByType);
      expect(eventTypes).toHaveLength(8);
      expect(new Set(eventTypes)).toEqual(
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
  });

  describe('FORBIDDEN_CLOUD_KEYS', () => {
    it('lists all UAT-013 forbidden identity-bearing fields', () => {
      const required = [
        '_local',
        'developer_id',
        'email',
        'git_author_email',
        'github_username',
        'hostname',
        'ip',
        'ip_address',
        'machine_id',
        'user_id',
        'username',
      ];

      for (const key of required) {
        expect(FORBIDDEN_CLOUD_KEYS).toContain(key);
      }
    });
  });
});
