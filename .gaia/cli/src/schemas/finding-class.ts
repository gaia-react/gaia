import {z} from 'zod';

/**
 * A `finding_class` is a stable, machine-stable identifier for a kind of
 * code-audit-frontend finding. Recurrence (the policy-memory loop) keys on it,
 * so it must reject free-text drift.
 *
 * Per-bucket convention:
 *
 * - Oracle buckets (deterministic tools) carry the tool's own id verbatim
 *   after the prefix; the tool owns that id space, so any well-formed slug is
 *   accepted: `react-doctor/<rule-id>`, `axe/<rule-id>`, `knip/<issue-type>`,
 *   `cve/<advisory-id>`.
 * - Holistic / rule / workflow subagent buckets carry a CLOSED controlled
 *   vocabulary (the `as const` unions below). A holistic, rule, or workflow
 *   finding only becomes a countable class once it has a seeded member; an
 *   unseeded member is rejected so free-text drift never reaches the tally.
 */

export const FINDING_CLASS_PREFIXES = [
  'react-doctor',
  'axe',
  'knip',
  'cve',
  'holistic',
  'rule',
  'workflow',
] as const;

export type FindingClassPrefix = (typeof FINDING_CLASS_PREFIXES)[number];

// Open oracle buckets: the deterministic tool owns the id space after the
// prefix, so any non-empty slug is valid.
const ORACLE_PREFIXES: readonly FindingClassPrefix[] = [
  'react-doctor',
  'axe',
  'knip',
  'cve',
];

/**
 * Closed-vocabulary members for the holistic bucket. Seeded from the audit
 * agent's stable cross-cutting dimensions and the project-specific rules it
 * enforces. Deliberately small: seed only classes the agent can reliably and
 * repeatably assign. When in doubt, leave a class out.
 */
export const HOLISTIC_FINDING_CLASSES = [
  'holistic/missing-auth-check',
  'holistic/secret-exposure',
  'holistic/n-plus-one',
  'holistic/unnecessary-rerender',
  'holistic/unhandled-promise-rejection',
  'holistic/swallowed-error',
  'holistic/over-permissive-zod',
  'holistic/business-logic-in-component',
  'holistic/hardcoded-string',
  'holistic/non-null-assertion',
] as const;

export type HolisticFindingClass = (typeof HOLISTIC_FINDING_CLASSES)[number];

/**
 * Dedup-key fallback for an out-of-scope finding that maps to no seeded
 * finding_class.
 *
 * This sits outside the closed finding_class vocabulary on purpose, so
 * `isValidFindingClass` rejects it and it never reaches the tally. That is the
 * *only* thing it means. It is **not** a security signal: the audit's
 * security screen keys on a finding's content and severity, never on this
 * constant, and treating it as a "classless, therefore assume the worst"
 * trigger would divert every out-of-scope finding on a public repo and file
 * none of them. See the security-class fail-safe in
 * `.claude/agents/code-audit-frontend.md` (section B).
 */
export const OUT_OF_SCOPE_FALLBACK_FINDING_CLASS = 'holistic/unclassified';

/**
 * Closed-vocabulary members for the rule bucket. Seeded from the line-level
 * rule surfaces the specialist subagents enforce (react-code skill, typescript
 * skill, the thin-route rule). Small and defensible by design.
 */
export const RULE_FINDING_CLASSES = [
  'rule/use-effect-derived-state',
  'rule/use-effect-state-reset',
  'rule/unnecessary-use-callback',
  'rule/missing-effect-cleanup',
  'rule/generic-handler-name',
  'rule/switch-statement',
  'rule/interface-declaration',
  'rule/z-enum',
  'rule/array-generic-syntax',
  'rule/thin-route-violation',
] as const;

export type RuleFindingClass = (typeof RULE_FINDING_CLASSES)[number];

/**
 * Closed-vocabulary members for the workflow bucket. Seeded from the
 * workflow-security surface the `code-audit-github-workflows` member owns
 * (GitHub-Actions supply-chain, injection, and permission defects). Small and
 * defensible by design: seed only classes the agent can reliably and repeatably
 * assign. When in doubt, leave a class out.
 */
export const WORKFLOW_FINDING_CLASSES = [
  'workflow/script-injection',
  'workflow/unsafe-pull-request-target',
  'workflow/unpinned-action',
  'workflow/broad-permissions',
] as const;

export type WorkflowFindingClass = (typeof WORKFLOW_FINDING_CLASSES)[number];

const CLOSED_VOCABULARY: ReadonlySet<string> = new Set([
  ...HOLISTIC_FINDING_CLASSES,
  ...RULE_FINDING_CLASSES,
  ...WORKFLOW_FINDING_CLASSES,
]);

const splitPrefix = (
  value: string
): undefined | {prefix: string; slug: string} => {
  const separatorIndex = value.indexOf('/');

  if (separatorIndex === -1) return undefined;

  return {
    prefix: value.slice(0, separatorIndex),
    slug: value.slice(separatorIndex + 1),
  };
};

const isOraclePrefix = (prefix: string): prefix is FindingClassPrefix =>
  (ORACLE_PREFIXES as readonly string[]).includes(prefix);

/**
 * True when `value` matches the per-bucket convention: a well-formed oracle id
 * (open id space after a known oracle prefix) or a seeded holistic/rule member
 * (closed controlled vocabulary). Everything else (free text, unknown prefix,
 * empty slug, unseeded holistic/rule member) is invalid.
 */
export const isValidFindingClass = (value: string): boolean => {
  const parts = splitPrefix(value);

  if (parts === undefined) return false;

  if (isOraclePrefix(parts.prefix)) return parts.slug.length > 0;

  return CLOSED_VOCABULARY.has(value);
};

export const FindingClassSchema = z.string().refine(isValidFindingClass, {
  message:
    'finding_class must match the per-bucket convention (oracle id or controlled vocabulary)',
});
