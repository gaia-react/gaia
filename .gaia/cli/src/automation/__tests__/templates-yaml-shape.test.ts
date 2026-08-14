import {load} from 'js-yaml';
import {describe, expect, test} from 'vitest';
import {z} from 'zod';
import type {
  AutomationConfig,
  ToolId,
} from '../../schemas/automation-config.js';
import {
  workflowPartialsDirectory,
  workflowSchedulerTemplatePath,
  workflowTemplatePath,
} from '../paths.js';
import {renderWorkflowTemplate} from '../render.js';
import {buildSchedulerVars, buildWorkflowVars} from '../workflow-vars.js';

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

// A tool workflow carries no `schedule:`: `gaia-ci.yml` is the only
// scheduled entry point, and it reaches these through `workflow_call`.
// `workflow_dispatch` stays so a tool can still be run by hand.
const WorkflowSchema = z.object({
  concurrency: z.object({
    'cancel-in-progress': z.literal(false),
    group: z.string(),
  }),
  env: z.record(z.string(), z.string()),
  jobs: z.record(z.string(), JobSchema),
  name: z.string(),
  on: z.object({
    schedule: z.undefined().optional(),
    workflow_call: z.unknown(),
    workflow_dispatch: z.unknown(),
  }),
  permissions: z.record(z.string(), z.string()),
});

// The scheduler's own shape: one `decide` job with steps, then one
// `uses:`-only call job per CI-mode tool.
const CallJobSchema = z.object({
  if: z.string(),
  needs: z.string(),
  secrets: z.literal('inherit'),
  uses: z.string(),
});

const SchedulerSchema = z.object({
  jobs: z.object({
    decide: JobSchema.extend({
      outputs: z.record(z.string(), z.string()),
      permissions: z.record(z.string(), z.string()),
    }),
  }),
  name: z.string(),
  on: z.object({
    schedule: z.array(z.object({cron: z.string()})).min(1),
    workflow_dispatch: z.unknown(),
  }),
  permissions: z.record(z.string(), z.string()),
});

const byText = (a: string, b: string): number => a.localeCompare(b);

const renderScheduler = (): string => {
  const vars = buildSchedulerVars(baseConfig);
  if (vars === null) throw new Error('unexpected null scheduler vars');

  return renderWorkflowTemplate(
    workflowSchedulerTemplatePath(),
    workflowPartialsDirectory(),
    vars
  );
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

const tools: readonly ToolId[] = [
  'wiki',
  'update-deps',
  'pnpm-audit',
  'stale-branches',
];

// Extracted so the `if (!result.success) throw` lives outside the test
// body (vitest/no-conditional-in-test forbids conditionals in test bodies);
// the `expect`-prefixed name still satisfies vitest/expect-expect.
const expectWorkflowSchemaValid = (tool: ToolId, rendered: string): void => {
  const parsed = load(rendered);
  const result = WorkflowSchema.safeParse(parsed);

  if (!result.success) {
    // Surface the issue path for fast diagnosis.
    throw new Error(
      `${tool} schema mismatch: ${JSON.stringify(result.error.issues, null, 2)}`
    );
  }
};

describe('workflow YAML shape', () => {
  test.each(tools)('%s passes the WorkflowSchema', (tool) => {
    expectWorkflowSchemaValid(tool, renderForTool(tool));
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

describe('scheduler YAML shape', () => {
  test('passes the SchedulerSchema', () => {
    const result = SchedulerSchema.safeParse(load(renderScheduler()));
    const issues = result.success ? '' : JSON.stringify(result.error.issues);

    expect(issues).toBe('');
  });

  // The scheduler's `permissions` must cover the union of what the called
  // workflows declare: a callee's own block can narrow the caller's grant but
  // never widen it, so a permission missing here is silently absent in every
  // tool run the scheduler starts.
  test('grants the union of every called workflow permission', () => {
    const scheduler = load(renderScheduler()) as {
      permissions: Record<string, string>;
    };
    const required = tools.flatMap((tool) => {
      const parsed = load(renderForTool(tool)) as {
        permissions: Record<string, string>;
      };

      return Object.entries(parsed.permissions);
    });
    const uncovered = required.filter(
      ([scope, level]) => scheduler.permissions[scope] !== level
    );

    expect(uncovered).toEqual([]);
  });

  // A job's own `permissions` block replaces the workflow-level grant for that
  // job instead of adding to it, so any scope the block omits is `none` there.
  // The union test above reads only the workflow-level block and cannot see
  // this. `decide` runs `gh pr list`, which needs `pull-requests`; without it
  // the call 403s on a private repo, `set -euo pipefail` fails the job, and
  // every `needs: decide` call job is skipped.
  test('grants the decide job every scope its own step reads', () => {
    const scheduler = load(renderScheduler()) as {
      jobs: {decide: {permissions: Record<string, string>}};
    };

    expect(scheduler.jobs.decide.permissions).toEqual({
      contents: 'read',
      'pull-requests': 'read',
    });
  });

  test('calls one reusable workflow per CI-mode tool', () => {
    const scheduler = load(renderScheduler()) as {
      jobs: Record<string, unknown>;
    };
    const callJobs = tools.map((tool) =>
      CallJobSchema.parse(scheduler.jobs[tool])
    );

    expect(callJobs.map((job) => job.uses)).toEqual(
      tools.map((tool) => `./.github/workflows/gaia-ci-${tool}.yml`)
    );
  });

  // The `decide` script gates each tool on a cron literal, and nothing else
  // in the rendered file ties the two together: a tool handed a sibling's
  // cron still parses, still schedules, and simply never matches its own
  // fired tick again. Bind each rendered argument pair back to the tool's own
  // `buildWorkflowVars` cron so a transposition fails here.
  test('gates each tool on its own cron in the decide script', () => {
    const rendered = renderScheduler();
    const pairs = [...rendered.matchAll(/decide_tool (\S+) '([^']+)'/gu)].map(
      ([, tool, cron]) => `${tool} ${cron}`
    );
    const expected = tools.map((tool) => {
      const vars = buildWorkflowVars(baseConfig, tool);
      if (vars === null) throw new Error(`unexpected null vars for ${tool}`);

      return `${tool} ${vars.cron}`;
    });

    expect(pairs.toSorted(byText)).toEqual(expected.toSorted(byText));
  });

  // Every distinct tool cron reaches the scheduler's `schedule:`. A cron
  // dropped here is a tool that silently never fires again, since its own
  // workflow no longer carries one.
  test('schedules every distinct tool cron exactly once', () => {
    const scheduler = load(renderScheduler()) as {
      on: {schedule: {cron: string}[]};
    };
    const crons: string[] = scheduler.on.schedule.map((entry) => entry.cron);
    const toolCrons: string[] = tools.map((tool) => {
      const vars = buildWorkflowVars(baseConfig, tool);
      if (vars === null) throw new Error(`unexpected null vars for ${tool}`);

      return vars.cron;
    });
    const distinctToolCrons: string[] = [...new Set(toolCrons)];

    expect(crons.toSorted(byText)).toEqual(distinctToolCrons.toSorted(byText));
  });
});
