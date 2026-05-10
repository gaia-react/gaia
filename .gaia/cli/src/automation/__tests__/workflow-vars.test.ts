import {describe, expect, it} from 'vitest';
import type {AutomationConfig, ToolId} from '../../schemas/automation-config.js';
import {buildWorkflowVars, cronForSchedule} from '../workflow-vars.js';

const baseConfig: AutomationConfig = {
  pnpm_audit: {mode: 'ci', schedule: 'daily'},
  setup_complete: true,
  setup_opted_out: false,
  stale_branches: {mode: 'ci', schedule: 'monthly'},
  update_deps: {mode: 'ci', schedule: 'weekly'},
  update_gaia: {mode: 'local'},
  version: 1,
  wiki: {mode: 'ci'},
};

describe('cronForSchedule', () => {
  it('maps daily to 0 4 * * *', () => {
    expect(cronForSchedule('daily')).toBe('0 4 * * *');
  });

  it('maps weekly to 0 4 * * 0', () => {
    expect(cronForSchedule('weekly')).toBe('0 4 * * 0');
  });

  it('maps monthly to 0 4 1-7 * 0 (first Sunday)', () => {
    expect(cronForSchedule('monthly')).toBe('0 4 1-7 * 0');
  });

  it('returns a non-empty string for every schedule value', () => {
    for (const schedule of ['daily', 'weekly', 'monthly'] as const) {
      expect(cronForSchedule(schedule).length).toBeGreaterThan(0);
    }
  });
});

describe('buildWorkflowVars', () => {
  it('returns the wiki vars with default daily schedule', () => {
    const vars = buildWorkflowVars(baseConfig, 'wiki');

    expect(vars).toEqual({
      config_key: 'wiki',
      cost_ceiling_dollars: 5,
      cron: '0 4 * * *',
      enable_auto_merge: true,
      enable_diff_size_check: true,
      enable_major_bump_split: false,
      enable_security_pr: false,
      enable_stale_branch_delete: false,
      needs_human_review_label: 'needs-human-review',
      pr_label: 'gaia-ci',
      schedule: 'daily',
      state_file: '.gaia/automation.state-wiki.json',
      tool_id: 'wiki',
      workflow_name: 'GAIA CI — Wiki',
    });
  });

  it('returns the update-deps vars with weekly schedule from config', () => {
    const vars = buildWorkflowVars(baseConfig, 'update-deps');

    expect(vars).toMatchObject({
      config_key: 'update_deps',
      cron: '0 4 * * 0',
      enable_major_bump_split: true,
      schedule: 'weekly',
      state_file: '.gaia/automation.state-update-deps.json',
      tool_id: 'update-deps',
      workflow_name: 'GAIA CI — Update Deps',
    });
  });

  it('returns the pnpm-audit vars with daily schedule', () => {
    const vars = buildWorkflowVars(baseConfig, 'pnpm-audit');

    expect(vars).toMatchObject({
      config_key: 'pnpm_audit',
      cron: '0 4 * * *',
      enable_security_pr: true,
      schedule: 'daily',
      state_file: '.gaia/automation.state-pnpm-audit.json',
      tool_id: 'pnpm-audit',
      workflow_name: 'GAIA CI — pnpm audit',
    });
  });

  it('returns the stale-branches vars with monthly schedule', () => {
    const vars = buildWorkflowVars(baseConfig, 'stale-branches');

    expect(vars).toMatchObject({
      config_key: 'stale_branches',
      cron: '0 4 1-7 * 0',
      enable_auto_merge: false,
      enable_stale_branch_delete: true,
      schedule: 'monthly',
      state_file: '.gaia/automation.state-stale-branches.json',
      tool_id: 'stale-branches',
      workflow_name: 'GAIA CI — Stale Branches',
    });
  });

  it('sets enable_auto_merge=true for the three PR-opening tools', () => {
    for (const tool of ['wiki', 'update-deps', 'pnpm-audit'] as const) {
      const vars = buildWorkflowVars(baseConfig, tool);
      expect(vars?.enable_auto_merge).toBe(true);
    }
  });

  it('falls back to the default schedule when the config row omits it', () => {
    const config: AutomationConfig = {
      ...baseConfig,
      update_deps: {mode: 'ci'},
    };

    expect(buildWorkflowVars(config, 'update-deps')).toMatchObject({
      cron: '0 4 * * 0',
      schedule: 'weekly',
    });
  });

  it('returns null when the tool mode is local', () => {
    const config: AutomationConfig = {
      ...baseConfig,
      wiki: {mode: 'local'},
    };

    expect(buildWorkflowVars(config, 'wiki')).toBeNull();
  });

  it('returns null when the tool mode is off', () => {
    const config: AutomationConfig = {
      ...baseConfig,
      pnpm_audit: {mode: 'off'},
    };

    expect(buildWorkflowVars(config, 'pnpm-audit')).toBeNull();
  });

  it('produces mutually exclusive enable_* flags per tool', () => {
    const tools: readonly ToolId[] = [
      'wiki',
      'update-deps',
      'pnpm-audit',
      'stale-branches',
    ];

    for (const tool of tools) {
      const vars = buildWorkflowVars(baseConfig, tool);
      expect(vars).not.toBeNull();
      const flags = [
        vars!.enable_diff_size_check,
        vars!.enable_major_bump_split,
        vars!.enable_security_pr,
        vars!.enable_stale_branch_delete,
      ];
      expect(flags.filter(Boolean)).toHaveLength(1);
    }
  });
});
