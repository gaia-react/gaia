import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, it} from 'vitest';
import {
  AutomationStateFileSchema,
  parseAutomationState,
  readAutomationState,
} from '../automation-state.js';

const VALID_STATE = {
  cost_overage: false,
  last_run_at: '2026-05-09T04:00:00Z',
  last_run_cost: 0.42,
  last_run_sha: 'a'.repeat(40),
  last_run_trigger: 'cron',
  skip_count: 0,
  version: 1,
};

type Sandbox = {
  cleanup: () => void;
  root: string;
  statePath: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-automation-state-'));
  mkdirSync(path.join(root, '.gaia'), {recursive: true});

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
    statePath: path.join(root, '.gaia', 'automation.state-wiki.json'),
  };
};

describe('schemas/automation-state', () => {
  describe('AutomationStateFileSchema', () => {
    it('parses a valid state', () => {
      expect(() => parseAutomationState(VALID_STATE)).not.toThrow();
    });

    it('rejects a non-40-char sha', () => {
      expect(() =>
        AutomationStateFileSchema.parse({
          ...VALID_STATE,
          last_run_sha: 'abc123',
        })
      ).toThrow();
    });

    it('rejects an uppercase sha', () => {
      expect(() =>
        AutomationStateFileSchema.parse({
          ...VALID_STATE,
          last_run_sha: 'A'.repeat(40),
        })
      ).toThrow();
    });

    it('rejects a non-ISO last_run_at', () => {
      expect(() =>
        AutomationStateFileSchema.parse({
          ...VALID_STATE,
          last_run_at: 'yesterday',
        })
      ).toThrow();
    });

    it('rejects negative skip_count', () => {
      expect(() =>
        AutomationStateFileSchema.parse({...VALID_STATE, skip_count: -1})
      ).toThrow();
    });

    it('rejects negative last_run_cost', () => {
      expect(() =>
        AutomationStateFileSchema.parse({...VALID_STATE, last_run_cost: -0.1})
      ).toThrow();
    });

    it('rejects unknown trigger', () => {
      expect(() =>
        AutomationStateFileSchema.parse({
          ...VALID_STATE,
          last_run_trigger: 'rerun',
        })
      ).toThrow();
    });
  });

  describe('readAutomationState', () => {
    let sandbox: Sandbox;

    beforeEach(() => {
      sandbox = setupSandbox();
    });

    afterEach(() => {
      sandbox.cleanup();
    });

    it('returns {status: "missing"} when the file does not exist', () => {
      const result = readAutomationState(sandbox.root, 'wiki');
      expect(result.status).toBe('missing');
    });

    it('returns {status: "ok"} for valid JSON', () => {
      writeFileSync(sandbox.statePath, JSON.stringify(VALID_STATE), 'utf8');
      const result = readAutomationState(sandbox.root, 'wiki');
      expect(result.status).toBe('ok');

      if (result.status === 'ok') {
        expect(result.state.last_run_trigger).toBe('cron');
      }
    });

    it('returns {status: "malformed"} for invalid JSON', () => {
      writeFileSync(sandbox.statePath, '{nope', 'utf8');
      const result = readAutomationState(sandbox.root, 'wiki');
      expect(result.status).toBe('malformed');
    });

    it('returns {status: "malformed"} for a bad sha', () => {
      writeFileSync(
        sandbox.statePath,
        JSON.stringify({...VALID_STATE, last_run_sha: 'short'}),
        'utf8'
      );
      const result = readAutomationState(sandbox.root, 'wiki');
      expect(result.status).toBe('malformed');

      if (result.status === 'malformed') {
        expect(result.error).toContain('last_run_sha');
      }
    });

    it('uses the kebab-case tool id in the path', () => {
      const auditPath = path.join(
        sandbox.root,
        '.gaia',
        'automation.state-pnpm-audit.json'
      );
      writeFileSync(auditPath, JSON.stringify(VALID_STATE), 'utf8');
      const result = readAutomationState(sandbox.root, 'pnpm-audit');
      expect(result.status).toBe('ok');
    });
  });
});
