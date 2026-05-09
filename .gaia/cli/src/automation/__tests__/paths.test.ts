import path from 'node:path';
import {describe, expect, it} from 'vitest';
import {
  automationConfigPath,
  automationStatePath,
  localAutomationPath,
} from '../paths.js';

describe('automation/paths', () => {
  describe('automationConfigPath', () => {
    it('returns <repoRoot>/.gaia/automation.json', () => {
      expect(automationConfigPath('/tmp/repo')).toBe(
        path.join('/tmp/repo', '.gaia', 'automation.json')
      );
    });

    it('handles a trailing slash via path.join semantics', () => {
      expect(automationConfigPath('/tmp/repo/')).toBe(
        path.join('/tmp/repo/', '.gaia', 'automation.json')
      );
    });
  });

  describe('automationStatePath', () => {
    it('returns the correct path for each tool id', () => {
      expect(automationStatePath('/r', 'wiki')).toBe(
        path.join('/r', '.gaia', 'automation.state-wiki.json')
      );
      expect(automationStatePath('/r', 'sharpen')).toBe(
        path.join('/r', '.gaia', 'automation.state-sharpen.json')
      );
      expect(automationStatePath('/r', 'pnpm-audit')).toBe(
        path.join('/r', '.gaia', 'automation.state-pnpm-audit.json')
      );
      expect(automationStatePath('/r', 'stale-branches')).toBe(
        path.join('/r', '.gaia', 'automation.state-stale-branches.json')
      );
    });

    it('does not nest into a per-tool subdirectory', () => {
      const result = automationStatePath('/r', 'wiki');
      expect(result.includes(path.join('.gaia', 'wiki'))).toBe(false);
    });
  });

  describe('localAutomationPath', () => {
    it('returns <repoRoot>/.gaia/local/automation.json', () => {
      expect(localAutomationPath('/tmp/repo')).toBe(
        path.join('/tmp/repo', '.gaia', 'local', 'automation.json')
      );
    });
  });
});
