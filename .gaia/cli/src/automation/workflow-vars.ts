/**
 * Per-tool template variables for the workflow YAML render pipeline.
 *
 * `buildWorkflowVars(config, tool)` reads slice 1's `AutomationConfig`
 * and emits the `WorkflowTemplateVars` object that the per-tool workflow
 * templates (and their shared partials) consume; `buildSchedulerVars`
 * does the same for the `gaia-ci.yml` scheduler that calls them. Returns `null` when
 * the tool's mode is not `'ci'` so callers short-circuit and skip
 * rendering that workflow.
 */
import {TOOL_ID_TO_CONFIG_KEY, TOOL_IDS} from '../schemas/automation-config.js';
import type {AutomationConfig, ToolId} from '../schemas/automation-config.js';

export type WorkflowSchedule = 'daily' | 'monthly' | 'weekly';

export type WorkflowTemplateVars = {
  config_key: string;
  cron: string;
  enable_auto_merge: boolean;
  enable_diff_size_check: boolean;
  enable_major_bump_split: boolean;
  enable_security_pr: boolean;
  enable_stale_branch_delete: boolean;
  needs_human_review_label: string;
  pr_label: string;
  schedule: WorkflowSchedule;
  tool_id: ToolId;
  workflow_name: string;
};

const CRON_BY_SCHEDULE: Readonly<Record<WorkflowSchedule, string>> = {
  daily: '0 4 * * *',
  monthly: '0 4 1-7 * 0',
  weekly: '0 4 * * 0',
};

const DEFAULT_SCHEDULE_BY_TOOL: Readonly<Record<ToolId, WorkflowSchedule>> = {
  'pnpm-audit': 'daily',
  'stale-branches': 'monthly',
  'update-deps': 'weekly',
  wiki: 'daily',
};

const WORKFLOW_NAME_BY_TOOL: Readonly<Record<ToolId, string>> = {
  'pnpm-audit': 'GAIA CI - pnpm audit',
  'stale-branches': 'GAIA CI - Stale Branches',
  'update-deps': 'GAIA CI - Update Deps',
  wiki: 'GAIA CI - Wiki',
};

export const cronForSchedule = (schedule: WorkflowSchedule): string =>
  CRON_BY_SCHEDULE[schedule];

/**
 * Build the per-template variables for one tool. Returns `null` if the
 * tool's mode in the config is not `'ci'`; callers short-circuit on
 * `null` and skip rendering that workflow.
 */
export const buildWorkflowVars = (
  config: AutomationConfig,
  tool: ToolId
): null | WorkflowTemplateVars => {
  const configKey = TOOL_ID_TO_CONFIG_KEY[tool];
  const toolConfig = config[configKey];

  // Defensive narrowing: TOOL_ID_TO_CONFIG_KEY only points at ToolConfig
  // entries, but the AutomationConfig union also contains UpdateGaiaConfig
  // and primitive values. The four ToolIds are guaranteed by construction
  // to map to ToolConfig rows. `ToolConfigKey` resolves `config[configKey]`
  // to `ToolConfig` directly, which is never `null`, so only the `typeof`
  // and `'mode' in` checks are meaningful here.
  if (typeof toolConfig !== 'object' || !('mode' in toolConfig)) {
    return null;
  }

  if (toolConfig.mode !== 'ci') return null;

  const schedule =
    'schedule' in toolConfig && toolConfig.schedule !== undefined ?
      toolConfig.schedule
    : DEFAULT_SCHEDULE_BY_TOOL[tool];

  return {
    config_key: configKey,
    // Read by the scheduler template, not by the tool template: a tool
    // workflow carries no `schedule:` of its own.
    cron: cronForSchedule(schedule),
    // stale-branches doesn't open a PR, so auto-merge is suppressed.
    // The auto-merge partial gates its body on this flag.
    enable_auto_merge: tool !== 'stale-branches',
    enable_diff_size_check: tool === 'wiki',
    enable_major_bump_split: tool === 'update-deps',
    enable_security_pr: tool === 'pnpm-audit',
    enable_stale_branch_delete: tool === 'stale-branches',
    needs_human_review_label: 'needs-human-review',
    pr_label: 'gaia-ci',
    schedule,
    tool_id: tool,
    workflow_name: WORKFLOW_NAME_BY_TOOL[tool],
  };
};

export const SCHEDULER_WORKFLOW_NAME = 'GAIA CI';

/**
 * Template variables for `gaia-ci.yml`, the one scheduled workflow that
 * fans out to the per-tool workflows. Every field is a list the template
 * iterates, so a tool added to `TOOL_IDS` needs no edit here and none in
 * the template.
 */
export type SchedulerTemplateVars = {
  scheduler_crons: string[];
  scheduler_decisions: string[];
  scheduler_tools: string[];
  workflow_name: string;
};

/**
 * Build the scheduler's variables from the whole config. Returns `null`
 * when no tool is in `ci` mode: there is then nothing to schedule, and the
 * caller writes no `gaia-ci.yml`.
 */
export const buildSchedulerVars = (
  config: AutomationConfig
): null | SchedulerTemplateVars => {
  // Per-tool vars are the single source for a tool's cron; deriving the
  // scheduler's copy from them is what keeps the two from disagreeing about
  // when a tool fires.
  const cronByTool = new Map<ToolId, string>();

  for (const tool of TOOL_IDS) {
    const vars = buildWorkflowVars(config, tool);

    if (vars !== null) cronByTool.set(tool, vars.cron);
  }

  if (cronByTool.size === 0) return null;

  // Deduplicated: two tools on the same schedule share one `schedule:` entry,
  // so their shared cron fires one run that decides for both.
  const distinctCrons: string[] = [...new Set(cronByTool.values())];

  return {
    scheduler_crons: distinctCrons.toSorted((a, b) => a.localeCompare(b)),
    // Each entry is one `decide_tool` argument list, tool and its own cron
    // composed in a single expression. Emitting the two as separate template
    // vars would let them be paired up wrongly downstream, and a tool handed
    // another tool's cron never matches its fired schedule and silently stops
    // running.
    scheduler_decisions: [...cronByTool].map(
      ([tool, cron]) => `${tool} '${cron}'`
    ),
    scheduler_tools: [...cronByTool.keys()],
    workflow_name: SCHEDULER_WORKFLOW_NAME,
  };
};
