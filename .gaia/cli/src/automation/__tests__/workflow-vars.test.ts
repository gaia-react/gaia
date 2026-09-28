import {describe, expect, test} from 'vitest';
import type {
  AutomationConfig,
  ToolId,
} from '../../schemas/automation-config.js';
import {
  buildSchedulerVars,
  buildWorkflowVars,
  cronForSchedule,
} from '../workflow-vars.js';

const baseConfig: AutomationConfig = {
  setup_complete: true,
  setup_opted_out: false,
  stale_branches: {mode: 'ci', schedule: 'monthly'},
  update_gaia: {mode: 'local'},
  version: 1,
  wiki: {mode: 'ci'},
};

describe('cronForSchedule', () => {
  test('maps daily to 0 4 * * *', () => {
    expect(cronForSchedule('daily')).toBe('0 4 * * *');
  });

  test('maps weekly to 0 4 * * 0', () => {
    expect(cronForSchedule('weekly')).toBe('0 4 * * 0');
  });

  test('maps monthly to 0 4 1-7 * 0 (first Sunday)', () => {
    expect(cronForSchedule('monthly')).toBe('0 4 1-7 * 0');
  });

  test('returns a non-empty string for every schedule value', () => {
    for (const schedule of ['daily', 'weekly', 'monthly'] as const) {
      expect(cronForSchedule(schedule).length).toBeGreaterThan(0);
    }
  });
});

describe('buildWorkflowVars', () => {
  test('returns the wiki vars with default daily schedule', () => {
    const vars = buildWorkflowVars(baseConfig, 'wiki');

    expect(vars).toEqual({
      config_key: 'wiki',
      cron: '0 4 * * *',
      enable_auto_merge: true,
      enable_diff_size_check: true,
      enable_stale_branch_delete: false,
      needs_human_label: 'needs-human',
      pr_label: 'gaia-ci',
      schedule: 'daily',
      tool_id: 'wiki',
      workflow_name: 'GAIA CI - Wiki',
    });
  });

  test('returns the stale-branches vars with monthly schedule', () => {
    const vars = buildWorkflowVars(baseConfig, 'stale-branches');

    expect(vars).toMatchObject({
      config_key: 'stale_branches',
      cron: '0 4 1-7 * 0',
      enable_auto_merge: false,
      enable_stale_branch_delete: true,
      schedule: 'monthly',
      tool_id: 'stale-branches',
      workflow_name: 'GAIA CI - Stale Branches',
    });
  });

  test('sets enable_auto_merge=true for wiki (the one PR-opening tool)', () => {
    const vars = buildWorkflowVars(baseConfig, 'wiki');
    expect(vars?.enable_auto_merge).toBe(true);
  });

  test('falls back to the default schedule when the config row omits it', () => {
    const config: AutomationConfig = {
      ...baseConfig,
      stale_branches: {mode: 'ci'},
    };

    expect(buildWorkflowVars(config, 'stale-branches')).toMatchObject({
      cron: '0 4 1-7 * 0',
      schedule: 'monthly',
    });
  });

  test('returns null when the tool mode is local', () => {
    const config: AutomationConfig = {
      ...baseConfig,
      wiki: {mode: 'local'},
    };

    expect(buildWorkflowVars(config, 'wiki')).toBeNull();
  });

  test('returns null when the tool mode is off', () => {
    const config: AutomationConfig = {
      ...baseConfig,
      stale_branches: {mode: 'off'},
    };

    expect(buildWorkflowVars(config, 'stale-branches')).toBeNull();
  });

  test('produces mutually exclusive enable_* flags per tool', () => {
    const tools: readonly ToolId[] = ['wiki', 'stale-branches'];

    for (const tool of tools) {
      const vars = buildWorkflowVars(baseConfig, tool);
      expect(vars).not.toBeNull();
      const flags = [
        vars!.enable_diff_size_check,
        vars!.enable_stale_branch_delete,
      ];
      expect(flags.filter(Boolean)).toHaveLength(1);
    }
  });
});

describe('buildSchedulerVars', () => {
  test('lists every CI-mode tool paired with its own cron', () => {
    expect(buildSchedulerVars(baseConfig)).toEqual({
      scheduler_crons: ['0 4 * * *', '0 4 1-7 * 0'],
      scheduler_decisions: ["wiki '0 4 * * *'", "stale-branches '0 4 1-7 * 0'"],
      scheduler_tools: ['wiki', 'stale-branches'],
      workflow_name: 'GAIA CI',
    });
  });

  test('omits a tool that is not in ci mode, and its cron with it', () => {
    const config: AutomationConfig = {
      ...baseConfig,
      stale_branches: {mode: 'off'},
    };

    expect(buildSchedulerVars(config)).toEqual({
      scheduler_crons: ['0 4 * * *'],
      scheduler_decisions: ["wiki '0 4 * * *'"],
      scheduler_tools: ['wiki'],
      workflow_name: 'GAIA CI',
    });
  });

  test('drops a cron once its only tool leaves ci mode', () => {
    const config: AutomationConfig = {
      ...baseConfig,
      stale_branches: {mode: 'off'},
    };

    expect(buildSchedulerVars(config)?.scheduler_crons).not.toContain(
      '0 4 1-7 * 0'
    );
  });

  test('returns null when no tool is in ci mode', () => {
    const config: AutomationConfig = {
      ...baseConfig,
      stale_branches: {mode: 'off'},
      wiki: {mode: 'off'},
    };

    expect(buildSchedulerVars(config)).toBeNull();
  });
});
