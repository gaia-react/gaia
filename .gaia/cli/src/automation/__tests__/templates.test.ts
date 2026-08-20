import {load} from 'js-yaml';
import {describe, expect, test} from 'vitest';
import type {
  AutomationConfig,
  ToolId,
} from '../../schemas/automation-config.js';
import {workflowPartialsDirectory, workflowTemplatePath} from '../paths.js';
import {renderWorkflowTemplate} from '../render.js';
import {buildWorkflowVars} from '../workflow-vars.js';

const baseConfig: AutomationConfig = {
  pnpm_audit: {mode: 'ci', schedule: 'daily'},
  setup_complete: true,
  setup_opted_out: false,
  stale_branches: {mode: 'ci', schedule: 'monthly'},
  update_deps: {mode: 'ci', schedule: 'weekly'},
  update_gaia: {mode: 'local'},
  version: 1,
  wiki: {mode: 'ci', schedule: 'daily'},
};

const renderForTool = (tool: ToolId): string => {
  const vars = buildWorkflowVars(baseConfig, tool);
  if (vars === null) throw new Error(`unexpected null vars for ${tool}`);

  return renderWorkflowTemplate(
    workflowTemplatePath(tool),
    workflowPartialsDirectory(),
    vars
  );
};

const parseRendered = (raw: string): Record<string, unknown> =>
  load(raw) as Record<string, unknown>;

type RenderedStep = {readonly if?: string; readonly name: string};

// Throws rather than returning `[]` for an unknown job: a job name that
// resolves to nothing would make an absence assertion below pass against
// nothing at all.
const jobSteps = (
  doc: Record<string, unknown>,
  job: string
): readonly RenderedStep[] => {
  const jobs = doc.jobs as Record<string, {steps: readonly RenderedStep[]}>;
  const found = jobs[job];

  if (found === undefined) {
    throw new Error(`rendered workflow declares no job named '${job}'`);
  }

  return found.steps;
};

const stepNames = (doc: Record<string, unknown>): readonly string[] =>
  jobSteps(doc, 'run').map((step) => step.name);

// The setup a skipped tick must not pay for, and the `if:` that spares it.
// The negative form is what lets one partial serve both the `run` job and a
// job gated at the job level with no `pre_run` step of its own.
const GATED_SETUP_STEPS = [
  'Setup pnpm',
  'Setup Node',
  'Install dependencies',
] as const;

const SKIP_GATE = "steps.pre_run.outputs.decision != 'skip'";

const PRE_RUN_STEP = 'Pre-run skip - open gaia-ci PR or cron-decide';

const expectedSteps = [
  'Checkout',
  PRE_RUN_STEP,
  ...GATED_SETUP_STEPS,
  'Quality Gate',
] as const;

const EXPECTED_TOP_LEVEL_KEYS = [
  'concurrency',
  'env',
  'jobs',
  'name',
  'on',
  'permissions',
];

describe('workflow templates: gaia-ci-wiki', () => {
  const rendered = renderForTool('wiki');
  const doc = parseRendered(rendered);

  test('parses cleanly as YAML with the expected top-level keys', () => {
    expect(Object.keys(doc).toSorted((a, b) => a.localeCompare(b))).toEqual(
      EXPECTED_TOP_LEVEL_KEYS.toSorted((a, b) => a.localeCompare(b))
    );
  });

  // The cron lives in gaia-ci.yml, which reaches this workflow through
  // workflow_call. A schedule here would fire a second run for the same tick
  // and bill GitHub's whole-minute job floor twice.
  test('declares workflow_call and workflow_dispatch, and no schedule', () => {
    const on = doc.on as {
      schedule?: unknown;
      workflow_call: unknown;
      workflow_dispatch: unknown;
    };
    expect(on.schedule).toBeUndefined();
    expect(on.workflow_call).toBeDefined();
    expect(on.workflow_dispatch).toBeDefined();
  });

  test('uses concurrency group gaia-ci-wiki with cancel-in-progress: false', () => {
    expect(doc.concurrency).toEqual({
      'cancel-in-progress': false,
      group: 'gaia-ci-wiki',
    });
  });

  test('declares the three secrets at the env level', () => {
    expect(doc.env).toEqual({
      // eslint-disable-next-line no-template-curly-in-string -- literal GH Actions `${{ }}` syntax, not JS interpolation
      ANTHROPIC_API_KEY: '${{ secrets.ANTHROPIC_API_KEY }}',
      // eslint-disable-next-line no-template-curly-in-string -- literal GH Actions `${{ }}` syntax, not JS interpolation
      CLAUDE_CODE_OAUTH_TOKEN: '${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}',
      // eslint-disable-next-line no-template-curly-in-string -- literal GH Actions `${{ }}` syntax, not JS interpolation
      GH_TOKEN: '${{ secrets.GITHUB_TOKEN }}',
    });
  });

  test('emits the expected steps in the correct order', () => {
    expect(stepNames(doc)).toEqual([
      ...expectedSteps,
      'Run gaia wiki chain',
      'Open and auto-merge gaia-ci PR',
    ]);
  });

  test('contains the wiki diff-size sanity check', () => {
    expect(rendered).toContain('wiki diff-size --threshold-pct 25');
    expect(rendered).toContain('needs-human');
  });

  test('does NOT emit major-bump-split, security-pr, or stale-branch logic', () => {
    expect(rendered).not.toContain('semver-major bumps');
    expect(rendered).not.toContain('pnpm audit --json');
    expect(rendered).not.toContain('gh api -X DELETE');
  });

  test('emits the gh pr merge --auto --squash invocation', () => {
    expect(rendered).toContain('gh pr merge "$pr_number" --auto --squash');
  });

  test('contains no unresolved {{ or }} mustache tokens', () => {
    // We purposely allow `${{ ... }}` (GitHub Actions). Strip those before
    // checking for residual mustache markers.
    const stripped = rendered.replaceAll(/\$\{\{[\s\S]*?\}\}/gu, '');
    expect(stripped).not.toContain('{{');
    expect(stripped).not.toContain('}}');
  });
});

describe('workflow templates: gaia-ci-update-deps', () => {
  const rendered = renderForTool('update-deps');
  const doc = parseRendered(rendered);

  test('uses concurrency group gaia-ci-update-deps', () => {
    expect((doc.concurrency as {group: string}).group).toBe(
      'gaia-ci-update-deps'
    );
  });

  test('invokes the emit-updates plan + claude-code-action chain', () => {
    expect(rendered).toContain('update-deps run --emit-updates');
    expect(rendered).toContain(
      'anthropics/claude-code-action@63322d7b2bc79e7b621b89f41b53ceb8e5a5d314'
    );
    expect(rendered).toContain('wave_b_matrix');
    expect(rendered).toContain('strategy:');
    expect(rendered).toContain(
      // eslint-disable-next-line no-template-curly-in-string -- literal GH Actions `${{ }}` syntax, not JS interpolation
      'matrix: ${{ fromJson(needs.run.outputs.wave_b_matrix) }}'
    );
  });

  test('emits the auto-merge step', () => {
    expect(rendered).toContain('gh pr merge "$pr_number" --auto --squash');
  });

  // The wave-B fan-out is gated at the job level and runs no `pre_run` step,
  // so `steps.pre_run.outputs.decision` is absent there. The `!= 'skip'` gate
  // the setup partial carries is true against an absent output; an `== 'run'`
  // gate would skip the install and leave every wave-B `pnpm add` without a
  // node_modules to add to.
  test('keeps the wave-B setup reachable without a pre_run step', () => {
    const waveB = jobSteps(doc, 'wave_b');
    const gates = GATED_SETUP_STEPS.map(
      (name) => waveB.find((step) => step.name === name)?.if
    );

    expect(waveB.map((step) => step.name)).not.toContain(PRE_RUN_STEP);
    expect(gates).toEqual(GATED_SETUP_STEPS.map(() => SKIP_GATE));
  });

  test('does NOT emit wiki, pnpm-audit, or stale-branch logic', () => {
    expect(rendered).not.toContain('wiki diff-size');
    expect(rendered).not.toContain('pnpm audit --json');
    expect(rendered).not.toContain('gh api -X DELETE');
  });

  test('contains no unresolved {{ or }} mustache tokens', () => {
    const stripped = rendered.replaceAll(/\$\{\{[\s\S]*?\}\}/gu, '');
    expect(stripped).not.toContain('{{');
    expect(stripped).not.toContain('}}');
  });
});

describe('workflow templates: gaia-ci-pnpm-audit', () => {
  const rendered = renderForTool('pnpm-audit');
  const doc = parseRendered(rendered);

  test('uses concurrency group gaia-ci-pnpm-audit', () => {
    expect((doc.concurrency as {group: string}).group).toBe(
      'gaia-ci-pnpm-audit'
    );
  });

  test('runs pnpm audit and opens a security PR + issue for high/critical', () => {
    expect(rendered).toContain('pnpm audit --json');
    expect(rendered).toContain('gh issue create');
    expect(rendered).toContain('--label gaia-ci,security');
  });

  test('emits the auto-merge step', () => {
    expect(rendered).toContain('gh pr merge "$pr_number" --auto --squash');
  });

  test('does NOT emit wiki, update-deps, or stale-branch logic', () => {
    expect(rendered).not.toContain('wiki diff-size');
    expect(rendered).not.toContain('semver-major bumps');
    expect(rendered).not.toContain('gh api -X DELETE');
  });

  test('contains no unresolved {{ or }} mustache tokens', () => {
    const stripped = rendered.replaceAll(/\$\{\{[\s\S]*?\}\}/gu, '');
    expect(stripped).not.toContain('{{');
    expect(stripped).not.toContain('}}');
  });
});

describe('workflow templates: gaia-ci-stale-branches', () => {
  const rendered = renderForTool('stale-branches');
  const doc = parseRendered(rendered);

  test('uses concurrency group gaia-ci-stale-branches', () => {
    expect((doc.concurrency as {group: string}).group).toBe(
      'gaia-ci-stale-branches'
    );
  });

  test('emits the branch-deletion step', () => {
    expect(rendered).toContain('gh api -X DELETE');
    expect(rendered).toContain('30 days ago');
  });

  test('emits NO gh pr merge invocation (auto-merge gated off)', () => {
    expect(rendered).not.toContain('gh pr merge');
  });

  test('omits the auto-merge step entirely (no PR-creation logic)', () => {
    expect(stepNames(doc)).not.toContain('Open and auto-merge gaia-ci PR');
  });

  test('contains no unresolved {{ or }} mustache tokens', () => {
    const stripped = rendered.replaceAll(/\$\{\{[\s\S]*?\}\}/gu, '');
    expect(stripped).not.toContain('{{');
    expect(stripped).not.toContain('}}');
  });
});

describe('workflow templates: cross-tool invariants', () => {
  const tools: readonly ToolId[] = [
    'wiki',
    'update-deps',
    'pnpm-audit',
    'stale-branches',
  ];

  test.each(tools)(
    'every rendered file references the three secrets (%s)',
    (tool) => {
      const rendered = renderForTool(tool);
      // eslint-disable-next-line no-template-curly-in-string -- literal GH Actions `${{ }}` syntax, not JS interpolation
      expect(rendered).toContain('${{ secrets.GITHUB_TOKEN }}');
      // eslint-disable-next-line no-template-curly-in-string -- literal GH Actions `${{ }}` syntax, not JS interpolation
      expect(rendered).toContain('${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}');
      // eslint-disable-next-line no-template-curly-in-string -- literal GH Actions `${{ }}` syntax, not JS interpolation
      expect(rendered).toContain('${{ secrets.ANTHROPIC_API_KEY }}');
    }
  );

  test.each(tools)(
    'every rendered file declares cancel-in-progress: false (%s)',
    (tool) => {
      const doc = parseRendered(renderForTool(tool));
      expect(
        (doc.concurrency as {'cancel-in-progress': boolean})[
          'cancel-in-progress'
        ]
      ).toBe(false);
    }
  );

  test.each(tools)(
    'every rendered file runs the open-PR + cron-decide pre-run skip (%s)',
    (tool) => {
      const rendered = renderForTool(tool);
      expect(rendered).toContain('--label gaia-ci');
      expect(rendered).toContain("'author:app/github-actions'");
      expect(rendered).toContain('automation cron-decide');
    }
  );

  test.each(tools)(
    'every rendered file runs the Quality Gate before merge (%s)',
    (tool) => {
      const rendered = renderForTool(tool);
      expect(rendered).toContain('pnpm typecheck');
      expect(rendered).toContain('pnpm lint');
    }
  );

  // A skipped tick still bills a whole runner minute, rounded up, on the
  // private repositories most adopters run this on. Asking `cron-decide`
  // after the install means every skip pays for an install it never uses,
  // so the decision comes first and the setup is gated on it.
  test.each(tools)(
    'decides whether to skip before installing anything (%s)',
    (tool) => {
      const names = stepNames(parseRendered(renderForTool(tool)));
      const setupAt = GATED_SETUP_STEPS.map((name) => names.indexOf(name));

      expect(setupAt).not.toContain(-1);
      expect(Math.min(...setupAt)).toBeGreaterThan(names.indexOf(PRE_RUN_STEP));
    }
  );

  // All three, not the install alone: setup-node's `cache: 'pnpm'` post step
  // saves the store unconditionally, so an ungated setup-node above a skipped
  // install fails the job saving a store nothing created.
  test.each(tools)('gates every setup step on the decision (%s)', (tool) => {
    const steps = jobSteps(parseRendered(renderForTool(tool)), 'run');
    const gates = GATED_SETUP_STEPS.map(
      (name) => steps.find((step) => step.name === name)?.if
    );

    expect(gates).toEqual(GATED_SETUP_STEPS.map(() => SKIP_GATE));
  });
});

describe('workflow templates: push re-authentication (issue #581)', () => {
  // A `claude-code-action` step earlier in the job runs in OIDC mode and
  // rewrites the checkout-persisted git credential
  // (`http.https://github.com/.extraheader`) around a short-lived,
  // OIDC-derived GitHub App token that no longer authorizes the subsequent
  // `git push`. Every push that can follow such a step must first reset the
  // extraheader to the workflow `GH_TOKEN` so it authenticates
  // deterministically. `wiki` (confirmed failing) and `update-deps` (same
  // bug, latent) are the affected tools.
  const REAUTH = 'git config --local http.https://github.com/.extraheader';
  const affected = ['wiki', 'update-deps'] as const;

  test.each(affected)(
    're-authenticates with GH_TOKEN before the auto-merge push (%s)',
    (tool) => {
      const rendered = renderForTool(tool);
      const reauthAt = rendered.indexOf(REAUTH);
      const pushAt = rendered.indexOf('git push origin "$branch"');

      expect(reauthAt).toBeGreaterThan(-1);
      expect(pushAt).toBeGreaterThan(reauthAt);
      expect(rendered).toContain('x-access-token:%s');
      expect(rendered).toContain('"$GH_TOKEN"');
    }
  );

  test('re-authenticates before the wave-B push too (update-deps)', () => {
    const rendered = renderForTool('update-deps');
    const waveBPushAt = rendered.indexOf('git push origin "$BRANCH"');
    const reauthBeforeWaveB = rendered.lastIndexOf(REAUTH, waveBPushAt);

    expect(waveBPushAt).toBeGreaterThan(-1);
    expect(reauthBeforeWaveB).toBeGreaterThan(-1);
    expect(reauthBeforeWaveB).toBeLessThan(waveBPushAt);
    // Both the run-job auto-merge push and the wave-B group push re-auth.
    expect(rendered.split(REAUTH).length - 1).toBe(2);
  });
});
