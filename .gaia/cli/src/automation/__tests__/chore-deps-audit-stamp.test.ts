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
 *
 * The POST itself now lives in the shared writer that all five terminal paths
 * route through (#1286), so the stamp is pinned at both ends: this step must
 * still invoke the writer member-awarely, and the writer must still POST the
 * required context. Asserting only the step would let the writer stop posting;
 * asserting only the writer would let this path stop calling it.
 */
import yaml from 'js-yaml';
import {describe, expect, test} from 'vitest';
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from '../../util/repo-root-fixture.js';
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

// Walks up to `.git` rather than counting `..` levels, so moving this file
// cannot silently land on the wrong directory and surface as an opaque ENOENT
// on write-audit-status.sh. Same helper the sibling audit-template-dogfood
// test resolves the identical root with.
const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);

const loadWriter = (): string =>
  readFileSync(
    path.join(repoRoot, '.github', 'audit', 'write-audit-status.sh'),
    'utf8'
  );

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
    const writer = loadWriter();

    // The step's half: it delegates to the shared writer, and it passes the
    // FULL-PR base, which is what makes the stamp member-aware. A stamp step
    // that stopped passing --base would clear the gate for a diff a required
    // auditor never read.
    // toMatch, not toContain: sibling steps in this workflow name the writer in
    // a rationale comment above their call, so a bare substring is satisfiable
    // by prose. The `bash ` prefix binds the assertion to the real invocation.
    expect(run).toMatch(/bash "?[^"]*write-audit-status\.sh/);
    // eslint-disable-next-line no-template-curly-in-string -- literal shell `${ }` syntax, not JS interpolation
    expect(run).toContain('--base "${PR_BASE_SHA}"');

    // The writer's half. The gap this closes: the required GAIA-Audit context
    // must be POSTed, not skipped away with the audit.
    expect(writer).toContain('context=GAIA-Audit');
    // success when the frontend bypass suffices; pending when a specialized
    // member CI cannot run is co-dispatched. Membership resolved over the full
    // PR diff via the one shared gate.
    expect(writer).toContain('state=success');
    expect(writer).toContain('state=pending');
    // toMatch, not toContain: the writer names this script in comments above
    // the call too, so a substring pin is satisfiable by prose. The `bash `
    // prefix binds it to the real invocation, and `--base` is pinned because
    // feeding the base through is the member-awareness claim itself.
    expect(writer).toMatch(/bash "?[^"]*gate-pending-members\.sh"? --base /);
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
