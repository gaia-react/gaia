import {describe, expect, test} from 'vitest';
import type {AutomationConfig} from '../../schemas/automation-config.js';
import {
  buildSchedulerVars,
  buildWorkflowVars,
  cronForSchedule,
} from '../workflow-vars.js';

const baseConfig: AutomationConfig = {
  setup_complete: true,
  setup_opted_out: false,
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
      enable_diff_size_check: true,
      needs_human_label: 'needs-human',
      pr_label: 'gaia-ci',
      schedule: 'daily',
      tool_id: 'wiki',
      workflow_name: 'GAIA CI - Wiki',
    });
  });

  test('uses the schedule the config row names over the default', () => {
    const config: AutomationConfig = {
      ...baseConfig,
      wiki: {mode: 'ci', schedule: 'monthly'},
    };

    expect(buildWorkflowVars(config, 'wiki')).toMatchObject({
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
      wiki: {mode: 'off'},
    };

    expect(buildWorkflowVars(config, 'wiki')).toBeNull();
  });
});

describe('buildSchedulerVars', () => {
  test('lists every CI-mode tool paired with its own cron', () => {
    expect(buildSchedulerVars(baseConfig)).toEqual({
      scheduler_crons: ['0 4 * * *'],
      scheduler_decisions: ["wiki '0 4 * * *'"],
      scheduler_tools: ['wiki'],
      workflow_name: 'GAIA CI',
    });
  });

  test('returns null when no tool is in ci mode', () => {
    const config: AutomationConfig = {
      ...baseConfig,
      wiki: {mode: 'off'},
    };

    expect(buildSchedulerVars(config)).toBeNull();
  });
});
