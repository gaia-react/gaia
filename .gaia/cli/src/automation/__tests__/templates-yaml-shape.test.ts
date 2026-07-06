import {load} from 'js-yaml';
import {describe, expect, test} from 'vitest';
import {z} from 'zod';
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

const StepSchema = z.object({
  env: z.record(z.string(), z.string()).optional(),
  id: z.string().optional(),
  if: z.string().optional(),
  name: z.string(),
  run: z.string().optional(),
  uses: z.string().optional(),
  with: z.record(z.string(), z.unknown()).optional(),
});

const JobSchema = z.object({
  'runs-on': z.string(),
  steps: z.array(StepSchema).min(1),
  'timeout-minutes': z.number(),
});

const WorkflowSchema = z.object({
  concurrency: z.object({
    'cancel-in-progress': z.literal(false),
    group: z.string(),
  }),
  env: z.record(z.string(), z.string()),
  jobs: z.record(z.string(), JobSchema),
  name: z.string(),
  on: z.object({
    schedule: z.array(z.object({cron: z.string()})).min(1),
    workflow_dispatch: z.unknown(),
  }),
  permissions: z.record(z.string(), z.string()),
});

const renderForTool = (tool: ToolId): string => {
  const vars = buildWorkflowVars(baseConfig, tool);
  if (vars === null) throw new Error(`unexpected null vars for ${tool}`);

  return renderWorkflowTemplate(
    workflowTemplatePath(tool),
    workflowPartialsDirectory(),
    vars
  );
};

const tools: readonly ToolId[] = [
  'wiki',
  'update-deps',
  'pnpm-audit',
  'stale-branches',
];

describe('workflow YAML shape', () => {
  test.each(tools)('%s passes the WorkflowSchema', (tool) => {
    const rendered = renderForTool(tool);
    const parsed = load(rendered);
    const result = WorkflowSchema.safeParse(parsed);

    if (!result.success) {
      // Surface the issue path for fast diagnosis.
      throw new Error(
        `${tool} schema mismatch: ${JSON.stringify(result.error.issues, null, 2)}`
      );
    }
    expect(result.success).toBe(true);
  });

  test.each(tools)('%s declares permissions.contents = write', (tool) => {
    const parsed = load(renderForTool(tool)) as {
      permissions: Record<string, string>;
    };
    expect(parsed.permissions.contents).toBe('write');
    expect(parsed.permissions['pull-requests']).toBe('write');
    expect(parsed.permissions.issues).toBe('write');
  });
});
