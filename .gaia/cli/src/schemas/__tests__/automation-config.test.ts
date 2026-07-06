import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {
  AutomationConfigSchema,
  CONFIG_KEY_TO_TOOL_ID,
  parseAutomationConfig,
  readAutomationConfig,
  TOOL_ID_TO_CONFIG_KEY,
  TOOL_IDS,
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

    test('rejects version != 1', () => {
      expect(() =>
        AutomationConfigSchema.parse({...VALID_CONFIG, version: 2})
      ).toThrow();
    });

    test('rejects unknown tool mode', () => {
      expect(() =>
        AutomationConfigSchema.parse({
          ...VALID_CONFIG,
          wiki: {mode: 'ci2'},
        })
      ).toThrow();
    });

    test('rejects missing wiki section', () => {
      const {wiki: _wiki, ...rest} = VALID_CONFIG;
      expect(() => AutomationConfigSchema.parse(rest)).toThrow();
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
      ).toThrow();
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

      if (result.status === 'ok') {
        expect(result.config.wiki.mode).toBe('ci');
      }
    });

    test('returns {status: "malformed"} for invalid JSON', () => {
      writeFileSync(sandbox.configPath, '{not json', 'utf8');
      const result = readAutomationConfig(sandbox.root);
      expect(result.status).toBe('malformed');

      if (result.status === 'malformed') {
        expect(result.error).toContain('automation.json');
        expect(result.error).toContain('invalid JSON');
      }
    });

    test('returns {status: "malformed"} for schema-violating JSON', () => {
      writeFileSync(
        sandbox.configPath,
        JSON.stringify({...VALID_CONFIG, wiki: {mode: 'wat'}}),
        'utf8'
      );
      const result = readAutomationConfig(sandbox.root);
      expect(result.status).toBe('malformed');

      if (result.status === 'malformed') {
        expect(result.error).toContain('wiki.mode');
      }
    });

    test('returns {status: "malformed"} when version is missing', () => {
      const {version: _version, ...rest} = VALID_CONFIG;
      writeFileSync(sandbox.configPath, JSON.stringify(rest), 'utf8');
      const result = readAutomationConfig(sandbox.root);
      expect(result.status).toBe('malformed');
    });
  });
});
