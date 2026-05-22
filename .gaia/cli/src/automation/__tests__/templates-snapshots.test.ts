import {describe, expect, it} from 'vitest';
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

// Inline snapshots catch unintentional drift in code review. Regenerate
// after deliberate template edits with `pnpm test --run -u`.
describe('workflow template snapshots', () => {
  it('gaia-ci-wiki.yml matches snapshot', () => {
    expect(renderForTool('wiki')).toMatchSnapshot();
  });

  it('gaia-ci-update-deps.yml matches snapshot', () => {
    expect(renderForTool('update-deps')).toMatchSnapshot();
  });

  it('gaia-ci-pnpm-audit.yml matches snapshot', () => {
    expect(renderForTool('pnpm-audit')).toMatchSnapshot();
  });

  it('gaia-ci-stale-branches.yml matches snapshot', () => {
    expect(renderForTool('stale-branches')).toMatchSnapshot();
  });
});
