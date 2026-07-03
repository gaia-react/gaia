import {z} from 'zod';
import {FindingClassSchema} from './finding-class.js';

const SPEC_ID_REGEX = /^SPEC-\d{3,}$/;
const UAT_ID_REGEX = /^UAT-\d{3,}$/;

const AreaTagsSchema = z.array(z.string()).min(1);

export const UatPassPayload = z.object({
  area_tags: AreaTagsSchema,
  attempts: z.number().int().min(1),
  spec_id: z.string().regex(SPEC_ID_REGEX),
  task_id: z.string(),
  uat_id: z.string().regex(UAT_ID_REGEX),
});

export type UatPassPayload = z.infer<typeof UatPassPayload>;

export const UatFailPayload = UatPassPayload.extend({
  failure_class: z.literal([
    'assertion',
    'exception',
    'flake_suspected',
    'setup',
    'timeout',
  ]),
});

export type UatFailPayload = z.infer<typeof UatFailPayload>;

export const NeedsContextReturnedPayload = z.object({
  agent_type: z.literal(['Junior', 'Lead', 'PO', 'Senior']),
  area_tags: AreaTagsSchema,
  context_request_class: z.literal([
    'ambiguous_boundary',
    'missing_codebase_knowledge',
    'unclear_acceptance_criteria',
    'unclear_business_intent',
  ]),
  spec_id: z.string().regex(SPEC_ID_REGEX),
  task_id: z.string(),
});

export type NeedsContextReturnedPayload = z.infer<
  typeof NeedsContextReturnedPayload
>;

export const BlockedReturnedPayload = z.object({
  agent_type: z.literal(['Junior', 'Lead', 'PO', 'Senior']),
  area_tags: AreaTagsSchema,
  classification: z.literal(['code', 'intent', 'spec']),
  spec_id: z.string().regex(SPEC_ID_REGEX),
  task_id: z.string(),
});

export type BlockedReturnedPayload = z.infer<typeof BlockedReturnedPayload>;

export const SpecAmendedPayload = z.object({
  amendment_reason: z.string().min(1),
  fields_changed: z
    .array(
      z.literal([
        'clarifications',
        'intent',
        'scope_boundaries',
        'success_criteria',
        'uats',
      ])
    )
    .min(1),
  spec_id: z.string().regex(SPEC_ID_REGEX),
  time_since_close_seconds: z.number().int().min(0),
});

export type SpecAmendedPayload = z.infer<typeof SpecAmendedPayload>;

export const PlanRevisedPayload = z.object({
  items_added: z.number().int().min(0),
  items_removed: z.number().int().min(0),
  plan_id: z.string(),
  revision_class: z.literal([
    'bug_fix_added',
    'dispatch_artifact_refinement',
    'scope_change',
    'sequencing_change',
  ]),
  spec_id: z.string().regex(SPEC_ID_REGEX),
});

export type PlanRevisedPayload = z.infer<typeof PlanRevisedPayload>;

export const TimeToResolvedSpecPayload = z.object({
  abandoned: z.boolean(),
  area_tags: AreaTagsSchema,
  // Optional partition marker: true when an auto-mode `/gaia-spec` run (the
  // agent answered its own Socratic questions) produced this SPEC. Absent
  // means a human-driven run. Consumers partition on it so auto-mode pacing
  // does not pollute the human baseline.
  auto: z.boolean().optional(),
  duration_seconds: z.number().int().min(0),
  question_count: z.number().int().min(0),
  spec_id: z.string().regex(SPEC_ID_REGEX),
});

export type TimeToResolvedSpecPayload = z.infer<
  typeof TimeToResolvedSpecPayload
>;

export const CodeReviewAuditFindingPayload = z.object({
  area_tags: AreaTagsSchema,
  auditor_type: z.string(),
  finding_class: FindingClassSchema,
  pr_number: z.number().int().min(1),
  severity: z.literal(['error', 'suggestion', 'warning']),
  spec_id: z.string().regex(SPEC_ID_REGEX).optional(),
});

export type CodeReviewAuditFindingPayload = z.infer<
  typeof CodeReviewAuditFindingPayload
>;

// Discriminated map by event_type.
export const MentorshipPayloadByType = {
  blocked_returned: BlockedReturnedPayload,
  code_review_audit_finding: CodeReviewAuditFindingPayload,
  needs_context_returned: NeedsContextReturnedPayload,
  plan_revised: PlanRevisedPayload,
  spec_amended: SpecAmendedPayload,
  time_to_resolved_spec: TimeToResolvedSpecPayload,
  uat_fail: UatFailPayload,
  uat_pass: UatPassPayload,
} as const;

export type MentorshipEventType = keyof typeof MentorshipPayloadByType;

export const MENTORSHIP_EVENT_TYPES = Object.keys(
  MentorshipPayloadByType
) as MentorshipEventType[];
