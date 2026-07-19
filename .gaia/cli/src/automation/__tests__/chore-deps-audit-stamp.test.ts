/**
 * Regression guard for the chore(deps) merge-gate gap.
 *
 * A `chore(deps):` / `chore(deps-dev):` PR skips the expensive frontend audit
 * (pre-verified by the /update-deps local quality gate). But the required
 * GAIA-Audit context is a POSTed commit status, not a job conclusion, so a
 * job-level skip cannot satisfy it the way Chromatic/Vitest/bats satisfy theirs.
 * Without a stamp on the skip path the required check is unsatisfiable and the
 * PR can never merge. These assertions pin the dedicated stamp step so a future
 * edit cannot silently drop it and reopen the gap.
 *
 * Reads only the canonical template (always present in the maintainer clone;
 * the whole file is release-excluded on an adopter clone), matching the
 * findings-block contract guard in audit-template-dogfood.test.ts.
 */
import yaml from 'js-yaml';
import {describe, expect, test} from 'vitest';
import {readFileSync} from 'node:fs';
import {workflowAuditTemplatePath} from '../paths.js';

type AuditWorkflow = {
  jobs: {'code-review-audit': {steps: WorkflowStep[]}};
};

type WorkflowStep = {
  env?: Record<string, string>;
  id?: string;
  if?: string;
  name?: string;
  run?: string;
};

const loadSteps = (): WorkflowStep[] => {
  const doc = yaml.load(
    readFileSync(workflowAuditTemplatePath(), 'utf8')
  ) as AuditWorkflow;

  return doc.jobs['code-review-audit'].steps;
};

describe('chore(deps) GAIA-Audit stamp', () => {
  const steps = loadSteps();
  const stampStep = steps.find((step) => step.id === 'chore-deps-status');

  test('a dedicated stamp step fires on the chore(deps) skip path', () => {
    expect(stampStep).toBeDefined();
    expect(stampStep?.if).toContain("steps.chore-deps.outputs.skip == 'true'");
  });

  test('the chore(deps) skip path posts a member-aware GAIA-Audit status', () => {
    const run = stampStep?.run ?? '';

    // The gap this closes: the required GAIA-Audit context must be POSTed, not
    // skipped away with the audit.
    expect(run).toContain('context=GAIA-Audit');
    // success when the frontend bypass suffices; pending when a specialized
    // member CI cannot run is co-dispatched. Membership resolved over the full
    // PR diff via the one shared gate.
    expect(run).toContain('state=success');
    expect(run).toContain('state=pending');
    expect(run).toContain('gate-pending-members.sh');
  });

  test('the chore(deps) terminal comment reports the actual stamp outcome', () => {
    const comment = steps.find(
      (step) => step.name === 'Status - skipped (chore-deps PR)'
    );

    // It must read the stamp step's outputs rather than post a bare "skipped"
    // line that reads green on the pending / not-stamped paths.
    expect(comment?.env?.SUCCESS_STAMPED).toContain(
      'steps.chore-deps-status.outputs.success_stamped'
    );
    expect(comment?.env?.MEMBERS_PENDING).toContain(
      'steps.chore-deps-status.outputs.members_pending'
    );
  });
});
