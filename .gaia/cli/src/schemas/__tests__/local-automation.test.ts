import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, it} from 'vitest';
import {
  LocalAutomationSchema,
  parseLocalAutomation,
  readLocalAutomation,
} from '../local-automation.js';

const VALID_LOCAL = {
  nudge_dismissed: false,
  version: 1,
};

type Sandbox = {
  cleanup: () => void;
  localPath: string;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-local-automation-'));
  mkdirSync(path.join(root, '.gaia', 'local'), {recursive: true});

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    localPath: path.join(root, '.gaia', 'local', 'automation.json'),
    root,
  };
};

describe('schemas/local-automation', () => {
  describe('LocalAutomationSchema', () => {
    it('parses a valid local config', () => {
      expect(() => parseLocalAutomation(VALID_LOCAL)).not.toThrow();
    });

    it('rejects version != 1', () => {
      expect(() =>
        LocalAutomationSchema.parse({...VALID_LOCAL, version: 2})
      ).toThrow();
    });

    it('rejects a non-boolean nudge_dismissed', () => {
      expect(() =>
        LocalAutomationSchema.parse({...VALID_LOCAL, nudge_dismissed: 'no'})
      ).toThrow();
    });
  });

  describe('readLocalAutomation', () => {
    let sandbox: Sandbox;

    beforeEach(() => {
      sandbox = setupSandbox();
    });

    afterEach(() => {
      sandbox.cleanup();
    });

    it('returns {status: "missing"} when the file does not exist', () => {
      const result = readLocalAutomation(sandbox.root);
      expect(result.status).toBe('missing');
    });

    it('returns {status: "ok"} for valid JSON', () => {
      writeFileSync(sandbox.localPath, JSON.stringify(VALID_LOCAL), 'utf8');
      const result = readLocalAutomation(sandbox.root);
      expect(result.status).toBe('ok');

      if (result.status === 'ok') {
        expect(result.local.nudge_dismissed).toBe(false);
      }
    });

    it('returns {status: "malformed"} for invalid JSON', () => {
      writeFileSync(sandbox.localPath, '{nope', 'utf8');
      const result = readLocalAutomation(sandbox.root);
      expect(result.status).toBe('malformed');
    });

    it('returns {status: "malformed"} for schema-violating JSON', () => {
      writeFileSync(
        sandbox.localPath,
        JSON.stringify({...VALID_LOCAL, version: 99}),
        'utf8'
      );
      const result = readLocalAutomation(sandbox.root);
      expect(result.status).toBe('malformed');
    });
  });
});
