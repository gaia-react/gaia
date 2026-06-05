import {z} from 'zod';
import {FindingClassSchema} from './finding-class.js';

// Cloud payloads strip identity-bearing fields. Mirror the mentorship payloads
// minus any field that could re-identify the developer.
//
// Forbidden fields (developer_id, email, username, GitHub username, machine
// ID, hostname, IP) never appear.
//
// Drift fails loud; every schema is a `z.strictObject()`. An unexpected field
// on a cloud event triggers a non-zero exit at projection time.
//
// `cloud-telemetry-scope` is the source of truth for what belongs on the
// cloud stream; the per-event-type whitelists below mirror the mentorship
// payload field set, dropping anything identity-bearing per that doc.
// At v1, the mentorship payloads themselves carry no identity-bearing
// fields (those live in the `_local` namespace), so the cloud schemas
// match the mentorship payload shape one-for-one.

export const UatPassCloudPayload = z.strictObject({
  area_tags: z.array(z.string()),
  attempts: z.number().int(),
  spec_id: z.string(),
  task_id: z.string(),
  uat_id: z.string(),
});

export type UatPassCloudPayload = z.infer<typeof UatPassCloudPayload>;

export const UatFailCloudPayload = z.strictObject({
  area_tags: z.array(z.string()),
  attempts: z.number().int(),
  failure_class: z.string(),
  spec_id: z.string(),
  task_id: z.string(),
  uat_id: z.string(),
});

export type UatFailCloudPayload = z.infer<typeof UatFailCloudPayload>;

export const NeedsContextReturnedCloudPayload = z.strictObject({
  agent_type: z.string(),
  area_tags: z.array(z.string()),
  context_request_class: z.string(),
  spec_id: z.string(),
  task_id: z.string(),
});

export type NeedsContextReturnedCloudPayload = z.infer<
  typeof NeedsContextReturnedCloudPayload
>;

export const BlockedReturnedCloudPayload = z.strictObject({
  agent_type: z.string(),
  area_tags: z.array(z.string()),
  classification: z.string(),
  spec_id: z.string(),
  task_id: z.string(),
});

export type BlockedReturnedCloudPayload = z.infer<
  typeof BlockedReturnedCloudPayload
>;

export const SpecAmendedCloudPayload = z.strictObject({
  amendment_reason: z.string(),
  fields_changed: z.array(z.string()),
  spec_id: z.string(),
  time_since_close_seconds: z.number().int(),
});

export type SpecAmendedCloudPayload = z.infer<typeof SpecAmendedCloudPayload>;

export const PlanRevisedCloudPayload = z.strictObject({
  items_added: z.number().int(),
  items_removed: z.number().int(),
  plan_id: z.string(),
  revision_class: z.string(),
  spec_id: z.string(),
});

export type PlanRevisedCloudPayload = z.infer<typeof PlanRevisedCloudPayload>;

export const TimeToResolvedSpecCloudPayload = z.strictObject({
  abandoned: z.boolean(),
  area_tags: z.array(z.string()),
  duration_seconds: z.number().int(),
  question_count: z.number().int(),
  spec_id: z.string(),
});

export type TimeToResolvedSpecCloudPayload = z.infer<
  typeof TimeToResolvedSpecCloudPayload
>;

export const CodeReviewAuditFindingCloudPayload = z.strictObject({
  area_tags: z.array(z.string()),
  auditor_type: z.string(),
  finding_class: FindingClassSchema,
  pr_number: z.number().int(),
  severity: z.string(),
  spec_id: z.string().optional(),
});

export type CodeReviewAuditFindingCloudPayload = z.infer<
  typeof CodeReviewAuditFindingCloudPayload
>;

export const CloudPayloadByType = {
  blocked_returned: BlockedReturnedCloudPayload,
  code_review_audit_finding: CodeReviewAuditFindingCloudPayload,
  needs_context_returned: NeedsContextReturnedCloudPayload,
  plan_revised: PlanRevisedCloudPayload,
  spec_amended: SpecAmendedCloudPayload,
  time_to_resolved_spec: TimeToResolvedSpecCloudPayload,
  uat_fail: UatFailCloudPayload,
  uat_pass: UatPassCloudPayload,
} as const;

export type CloudEventType = keyof typeof CloudPayloadByType;

// Forbidden-field denylist used as a final safety net by cloud-projection.
// If any of these substrings appears in the JSON-stringified cloud event line,
// projection fails loud (belt-and-suspenders for the strict-schema check).
export const FORBIDDEN_CLOUD_KEYS = [
  'developer_id',
  'user_id',
  'email',
  'username',
  'github_username',
  'machine_id',
  'hostname',
  'ip',
  'ip_address',
  'git_author_email',
  '_local',
] as const;
