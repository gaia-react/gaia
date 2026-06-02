import path from 'node:path';
import {describe, expect, it} from 'vitest';
import {
  automationConfigPath,
  automationStatePath,
  githubWorkflowsDirectory,
  localAutomationPath,
  workflowAuditTemplatePath,
  workflowFilePath,
  workflowPartialsDirectory,
  workflowTemplatePath,
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
      expect(automationStatePath('/r', 'update-deps')).toBe(
        path.join('/r', '.gaia', 'automation.state-update-deps.json')
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

  describe('githubWorkflowsDirectory', () => {
    it('returns <repoRoot>/.github/workflows', () => {
      expect(githubWorkflowsDirectory('/tmp/repo')).toBe(
        path.join('/tmp/repo', '.github', 'workflows')
      );
    });
  });

  describe('workflowFilePath', () => {
    it('returns the kebab-case workflow filename per tool', () => {
      expect(workflowFilePath('/tmp/repo', 'wiki')).toBe(
        path.join('/tmp/repo', '.github', 'workflows', 'gaia-ci-wiki.yml')
      );
      expect(workflowFilePath('/tmp/repo', 'pnpm-audit')).toBe(
        path.join('/tmp/repo', '.github', 'workflows', 'gaia-ci-pnpm-audit.yml')
      );
      expect(workflowFilePath('/tmp/repo', 'stale-branches')).toBe(
        path.join(
          '/tmp/repo',
          '.github',
          'workflows',
          'gaia-ci-stale-branches.yml'
        )
      );
    });
  });

  describe('workflowTemplatePath', () => {
    it('ends with templates/workflows/gaia-ci-<tool>.yml.tmpl', () => {
      expect(
        workflowTemplatePath('wiki').endsWith(
          path.join('templates', 'workflows', 'gaia-ci-wiki.yml.tmpl')
        )
      ).toBe(true);
      expect(
        workflowTemplatePath('update-deps').endsWith(
          path.join('templates', 'workflows', 'gaia-ci-update-deps.yml.tmpl')
        )
      ).toBe(true);
      expect(
        workflowTemplatePath('pnpm-audit').endsWith(
          path.join('templates', 'workflows', 'gaia-ci-pnpm-audit.yml.tmpl')
        )
      ).toBe(true);
      expect(
        workflowTemplatePath('stale-branches').endsWith(
          path.join('templates', 'workflows', 'gaia-ci-stale-branches.yml.tmpl')
        )
      ).toBe(true);
    });
  });

  describe('workflowAuditTemplatePath', () => {
    it('ends with templates/workflows/code-review-audit.yml.tmpl', () => {
      expect(
        workflowAuditTemplatePath().endsWith(
          path.join('templates', 'workflows', 'code-review-audit.yml.tmpl')
        )
      ).toBe(true);
    });
  });

  describe('workflowPartialsDirectory', () => {
    it('ends with templates/workflows/partials', () => {
      expect(
        workflowPartialsDirectory().endsWith(
          path.join('templates', 'workflows', 'partials')
        )
      ).toBe(true);
    });
  });
});
