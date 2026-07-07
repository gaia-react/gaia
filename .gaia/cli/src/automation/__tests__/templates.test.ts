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

const stepNames = (doc: Record<string, unknown>): readonly string[] => {
  const jobs = doc.jobs as {run: {steps: readonly {name: string}[]}};

  return jobs.run.steps.map((step) => step.name);
};

const expectedSteps = [
  'Checkout',
  'Setup pnpm',
  'Setup Node',
  'Install dependencies',
  'Pre-run skip - open gaia-ci PR or cron-decide',
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

  test('declares cron 0 4 * * * (daily) and workflow_dispatch', () => {
    const on = doc.on as {
      schedule: {cron: string}[];
      workflow_dispatch: unknown;
    };
    expect(on.schedule[0]?.cron).toBe('0 4 * * *');
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
    expect(rendered).toContain('needs-human-review');
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

  test('declares cron 0 4 * * 0 (weekly Sunday)', () => {
    const on = doc.on as {schedule: {cron: string}[]};
    expect(on.schedule[0]?.cron).toBe('0 4 * * 0');
  });

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

  test('declares cron 0 4 * * * (daily)', () => {
    const on = doc.on as {schedule: {cron: string}[]};
    expect(on.schedule[0]?.cron).toBe('0 4 * * *');
  });

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

  test('declares cron 0 4 1-7 * 0 (first Sunday of month)', () => {
    const on = doc.on as {schedule: {cron: string}[]};
    expect(on.schedule[0]?.cron).toBe('0 4 1-7 * 0');
  });

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
