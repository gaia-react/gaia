import {describe, expect, test} from 'vitest';
import path from 'node:path';
import {
  automationConfigPath,
  githubWorkflowsDirectory,
  localAutomationPath,
  workflowAuditTemplatePath,
  workflowFilePath,
  workflowPartialsDirectory,
  workflowTemplatePath,
} from '../paths.js';

describe('automation/paths', () => {
  describe('automationConfigPath', () => {
    test('returns <repoRoot>/.gaia/automation.json', () => {
      expect(automationConfigPath('/tmp/repo')).toBe(
        path.join('/tmp/repo', '.gaia', 'automation.json')
      );
    });

    test('handles a trailing slash via path.join semantics', () => {
      expect(automationConfigPath('/tmp/repo/')).toBe(
        path.join('/tmp/repo/', '.gaia', 'automation.json')
      );
    });
  });

  describe('localAutomationPath', () => {
    test('returns <repoRoot>/.gaia/local/automation.json', () => {
      expect(localAutomationPath('/tmp/repo')).toBe(
        path.join('/tmp/repo', '.gaia', 'local', 'automation.json')
      );
    });
  });

  describe('githubWorkflowsDirectory', () => {
    test('returns <repoRoot>/.github/workflows', () => {
      expect(githubWorkflowsDirectory('/tmp/repo')).toBe(
        path.join('/tmp/repo', '.github', 'workflows')
      );
    });
  });

  describe('workflowFilePath', () => {
    test('returns the kebab-case workflow filename per tool', () => {
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
    test('ends with templates/workflows/gaia-ci-<tool>.yml.tmpl', () => {
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
    test('ends with templates/workflows/code-review-audit.yml.tmpl', () => {
      expect(
        workflowAuditTemplatePath().endsWith(
          path.join('templates', 'workflows', 'code-review-audit.yml.tmpl')
        )
      ).toBe(true);
    });
  });

  describe('workflowPartialsDirectory', () => {
    test('ends with templates/workflows/partials', () => {
      expect(
        workflowPartialsDirectory().endsWith(
          path.join('templates', 'workflows', 'partials')
        )
      ).toBe(true);
    });
  });
});
