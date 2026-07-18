import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {z} from 'zod';
import assert from 'node:assert/strict';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {
  AutomationConfigSchema,
  CONFIG_KEY_TO_TOOL_ID,
  ISOLATION_POLICIES,
  parseAutomationConfig,
  readAutomationConfig,
  ScheduleSchema,
  TOOL_ID_TO_CONFIG_KEY,
  TOOL_IDS,
  ToolModeSchema,
} from '../automation-config.js';

type Sandbox = {
  cleanup: () => void;
  configDir: string;
  configPath: string;
  root: string;
};

const VALID_CONFIG = {
  pnpm_audit: {mode: 'local', schedule: 'weekly'},
  setup_complete: true,
  setup_opted_out: false,
  stale_branches: {mode: 'ci', schedule: 'weekly'},
  update_deps: {mode: 'off'},
  update_gaia: {mode: 'local'},
  version: 1,
  wiki: {mode: 'ci', schedule: 'daily'},
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-automation-config-'));
  const configDir = path.join(root, '.gaia');
  mkdirSync(configDir, {recursive: true});

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    configDir,
    configPath: path.join(configDir, 'automation.json'),
    root,
  };
};

describe('schemas/automation-config', () => {
  describe('AutomationConfigSchema', () => {
    test('parses a valid config', () => {
      expect(() => parseAutomationConfig(VALID_CONFIG)).not.toThrow();
    });

    test('tolerates an unrecognized version, defaulting to 1', () => {
      const parsed = AutomationConfigSchema.parse({
        ...VALID_CONFIG,
        version: 2,
      });
      expect(parsed.version).toBe(1);
    });

    test('tolerates an unrecognized tool mode, defaulting to "off"', () => {
      const parsed = AutomationConfigSchema.parse({
        ...VALID_CONFIG,
        wiki: {mode: 'ci2'},
      });
      expect(parsed.wiki.mode).toBe('off');
    });

    test('tolerates an unrecognized schedule, defaulting to undefined', () => {
      const parsed = AutomationConfigSchema.parse({
        ...VALID_CONFIG,
        wiki: {mode: 'ci', schedule: 'hourly'},
      });
      expect(parsed.wiki.schedule).toBeUndefined();
    });

    test('ToolModeSchema still rejects an unrecognized mode (write boundary stays strict)', () => {
      expect(ToolModeSchema.safeParse('banana').success).toBe(false);
    });

    test('ScheduleSchema still rejects an unrecognized schedule (write boundary stays strict)', () => {
      expect(ScheduleSchema.safeParse('hourly').success).toBe(false);
    });

    test('rejects missing wiki section', () => {
      const rest: Record<string, unknown> = {...VALID_CONFIG};
      delete rest.wiki;
      expect(() => AutomationConfigSchema.parse(rest)).toThrow(z.ZodError);
    });

    test('accepts ToolConfig without schedule', () => {
      expect(() =>
        AutomationConfigSchema.parse({
          ...VALID_CONFIG,
          update_deps: {mode: 'off'},
        })
      ).not.toThrow();
    });

    test('rejects update_gaia mode != "local"', () => {
      expect(() =>
        AutomationConfigSchema.parse({
          ...VALID_CONFIG,
          update_gaia: {mode: 'ci'},
        })
      ).toThrow(z.ZodError);
    });

    test('parses and retains sandbox_recommended: true', () => {
      const parsed = AutomationConfigSchema.parse({
        ...VALID_CONFIG,
        sandbox_recommended: true,
      });
      expect(parsed.sandbox_recommended).toBe(true);
    });

    test('parses when sandbox_recommended is absent (tolerated)', () => {
      const parsed = AutomationConfigSchema.parse(VALID_CONFIG);
      expect(parsed.sandbox_recommended).toBeUndefined();
    });

    test('rejects a non-boolean sandbox_recommended', () => {
      expect(() =>
        AutomationConfigSchema.parse({
          ...VALID_CONFIG,
          sandbox_recommended: 'yes',
        })
      ).toThrow(z.ZodError);
    });

    test('parses when isolation_policy is absent (tolerated)', () => {
      const parsed = AutomationConfigSchema.parse(VALID_CONFIG);
      expect(parsed.isolation_policy).toBeUndefined();
    });

    for (const policy of ISOLATION_POLICIES) {
      test(`parses and retains a known isolation_policy (${policy})`, () => {
        const parsed = AutomationConfigSchema.parse({
          ...VALID_CONFIG,
          isolation_policy: policy,
        });
        expect(parsed.isolation_policy).toBe(policy);
      });
    }

    test('parses an unrecognized isolation_policy value without malforming the config', () => {
      const parsed = AutomationConfigSchema.parse({
        ...VALID_CONFIG,
        isolation_policy: 'always-wortree',
      });
      expect(parsed.isolation_policy).toBe('always-wortree');
    });

    test('parses a non-string isolation_policy without malforming the config', () => {
      const parsed = AutomationConfigSchema.parse({
        ...VALID_CONFIG,
        isolation_policy: 42,
      });
      expect(parsed.isolation_policy).toBeUndefined();
    });

    test('tolerates an unknown key (never .strict())', () => {
      expect(() =>
        AutomationConfigSchema.parse({
          ...VALID_CONFIG,
          some_future_key: 'x',
        })
      ).not.toThrow();
    });
  });

  describe('TOOL_ID_TO_CONFIG_KEY <-> CONFIG_KEY_TO_TOOL_ID round-trip', () => {
    for (const tool of TOOL_IDS) {
      test(`round-trips for ${tool}`, () => {
        const configKey = TOOL_ID_TO_CONFIG_KEY[tool];
        expect(CONFIG_KEY_TO_TOOL_ID[configKey]).toBe(tool);
      });
    }
  });

  describe('readAutomationConfig', () => {
    let sandbox: Sandbox;

    beforeEach(() => {
      sandbox = setupSandbox();
    });

    afterEach(() => {
      sandbox.cleanup();
    });

    test('returns {status: "missing"} when the file does not exist', () => {
      const result = readAutomationConfig(sandbox.root);
      expect(result.status).toBe('missing');
    });

    test('returns {status: "ok", config} for valid JSON', () => {
      writeFileSync(sandbox.configPath, JSON.stringify(VALID_CONFIG), 'utf8');
      const result = readAutomationConfig(sandbox.root);
      expect(result.status).toBe('ok');
      assert.ok(result.status === 'ok');
      expect(result.config.wiki.mode).toBe('ci');
    });

    test('round-trips a fully-valid config unchanged (no regression)', () => {
      writeFileSync(sandbox.configPath, JSON.stringify(VALID_CONFIG), 'utf8');
      const result = readAutomationConfig(sandbox.root);
      expect(result.status).toBe('ok');
      assert.ok(result.status === 'ok');
      expect(result.config).toEqual(VALID_CONFIG);
    });

    test('returns {status: "ok"} for an unrecognized mode on one tool, defaulting that tool to "off" and leaving every other field intact', () => {
      writeFileSync(
        sandbox.configPath,
        JSON.stringify({...VALID_CONFIG, wiki: {mode: 'banana'}}),
        'utf8'
      );
      const result = readAutomationConfig(sandbox.root);
      expect(result.status).toBe('ok');
      assert.ok(result.status === 'ok');
      expect(result.config.wiki.mode).toBe('off');
      expect(result.config.pnpm_audit).toEqual(VALID_CONFIG.pnpm_audit);
      expect(result.config.stale_branches).toEqual(VALID_CONFIG.stale_branches);
      expect(result.config.update_deps).toEqual(VALID_CONFIG.update_deps);
      expect(result.config.setup_complete).toBe(true);
      expect(result.config.setup_opted_out).toBe(false);
      expect(result.config.version).toBe(1);
    });

    test('returns {status: "ok"} for an unrecognized schedule on one tool, defaulting that tool\'s schedule to undefined', () => {
      writeFileSync(
        sandbox.configPath,
        JSON.stringify({
          ...VALID_CONFIG,
          wiki: {mode: 'ci', schedule: 'hourly'},
        }),
        'utf8'
      );
      const result = readAutomationConfig(sandbox.root);
      expect(result.status).toBe('ok');
      assert.ok(result.status === 'ok');
      expect(result.config.wiki.schedule).toBeUndefined();
      expect(result.config.wiki.mode).toBe('ci');
    });

    test('returns {status: "ok"} for version: 2, defaulting version to 1', () => {
      writeFileSync(
        sandbox.configPath,
        JSON.stringify({...VALID_CONFIG, version: 2}),
        'utf8'
      );
      const result = readAutomationConfig(sandbox.root);
      expect(result.status).toBe('ok');
      assert.ok(result.status === 'ok');
      expect(result.config.version).toBe(1);
    });

    test('returns {status: "malformed"} for invalid JSON', () => {
      writeFileSync(sandbox.configPath, '{not json', 'utf8');
      const result = readAutomationConfig(sandbox.root);
      expect(result.status).toBe('malformed');
      assert.ok(result.status === 'malformed');
      expect(result.error).toContain('automation.json');
      expect(result.error).toContain('invalid JSON');
    });

    test('returns {status: "malformed"} for schema-violating JSON', () => {
      writeFileSync(
        sandbox.configPath,
        JSON.stringify({...VALID_CONFIG, setup_complete: 'yes'}),
        'utf8'
      );
      const result = readAutomationConfig(sandbox.root);
      expect(result.status).toBe('malformed');
      assert.ok(result.status === 'malformed');
      expect(result.error).toContain('setup_complete');
    });

    test('returns {status: "malformed"} when the wiki section is entirely missing', () => {
      const rest: Record<string, unknown> = {...VALID_CONFIG};
      delete rest.wiki;
      writeFileSync(sandbox.configPath, JSON.stringify(rest), 'utf8');
      const result = readAutomationConfig(sandbox.root);
      expect(result.status).toBe('malformed');
    });

    test('returns {status: "ok"} with version defaulted to 1 when version is missing', () => {
      const rest: Record<string, unknown> = {...VALID_CONFIG};
      delete rest.version;
      writeFileSync(sandbox.configPath, JSON.stringify(rest), 'utf8');
      const result = readAutomationConfig(sandbox.root);
      expect(result.status).toBe('ok');
      assert.ok(result.status === 'ok');
      expect(result.config.version).toBe(1);
    });

    test('returns {status: "ok"} for an unrecognized isolation_policy value', () => {
      writeFileSync(
        sandbox.configPath,
        JSON.stringify({...VALID_CONFIG, isolation_policy: 'always-wortree'}),
        'utf8'
      );
      const result = readAutomationConfig(sandbox.root);
      expect(result.status).toBe('ok');
    });

    test('returns {status: "ok"} for a non-string isolation_policy value', () => {
      writeFileSync(
        sandbox.configPath,
        JSON.stringify({...VALID_CONFIG, isolation_policy: 42}),
        'utf8'
      );
      const result = readAutomationConfig(sandbox.root);
      expect(result.status).toBe('ok');
    });
  });
});
