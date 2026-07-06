/**
 * Per-tool template variables for the workflow YAML render pipeline.
 *
 * `buildWorkflowVars(config, tool)` reads slice 1's `AutomationConfig`
 * and emits the `WorkflowTemplateVars` object that the four workflow
 * templates (and their shared partials) consume. Returns `null` when
 * the tool's mode is not `'ci'` so callers short-circuit and skip
 * rendering that workflow.
 */
import {TOOL_ID_TO_CONFIG_KEY} from '../schemas/automation-config.js';
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
  // to map to ToolConfig rows.
  if (
    typeof toolConfig !== 'object' ||
    toolConfig === null ||
    !('mode' in toolConfig)
  ) {
    return null;
  }

  if (toolConfig.mode !== 'ci') return null;

  const schedule =
    'schedule' in toolConfig && toolConfig.schedule !== undefined ?
      toolConfig.schedule
    : DEFAULT_SCHEDULE_BY_TOOL[tool];

  return {
    config_key: configKey,
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
