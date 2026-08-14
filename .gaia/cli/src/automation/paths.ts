/**
 * Path constants for GAIA CI configuration and the workflow tree.
 *
 * Every helper takes an explicit `repoRoot` argument; these primitives
 * never call `process.cwd()` themselves. Callers resolve the root via
 * `resolveRepoRoot` from `util/repo-root.ts`, matching the wiki
 * primitives' pattern.
 *
 * Slice 3 adds workflow-tree path helpers (`workflowTemplatePath`,
 * `workflowPartialsDirectory`) that resolve into the bundled CLI source
 * directory via `import.meta.url`, mirroring `scaffold/template.ts`.
 */
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import type {ToolId} from '../schemas/automation-config.js';

export const automationConfigPath = (repoRoot: string): string =>
  path.join(repoRoot, '.gaia', 'automation.json');

export const localAutomationPath = (repoRoot: string): string =>
  path.join(repoRoot, '.gaia', 'local', 'automation.json');

export const githubWorkflowsDirectory = (repoRoot: string): string =>
  path.join(repoRoot, '.github', 'workflows');

export const workflowFilePath = (repoRoot: string, tool: ToolId): string =>
  path.join(githubWorkflowsDirectory(repoRoot), `gaia-ci-${tool}.yml`);

/**
 * The rendered scheduler workflow: the one file carrying a `schedule:`.
 * Deliberately not `gaia-ci-<something>.yml`, so the guards that enumerate
 * the per-tool set by that prefix keep matching exactly the four tools.
 */
export const SCHEDULER_WORKFLOW_FILENAME = 'gaia-ci.yml';

const TEMPLATES_RELATIVE_DIR = path.join('templates', 'workflows');

const resolveTemplatesDirectory = (): string => {
  const here = fileURLToPath(import.meta.url);

  return path.join(path.dirname(here), TEMPLATES_RELATIVE_DIR);
};

export const workflowTemplatePath = (tool: ToolId): string =>
  path.join(resolveTemplatesDirectory(), `gaia-ci-${tool}.yml.tmpl`);

export const workflowSchedulerTemplatePath = (): string =>
  path.join(resolveTemplatesDirectory(), 'gaia-ci.yml.tmpl');

export const workflowAuditTemplatePath = (): string =>
  path.join(resolveTemplatesDirectory(), 'code-review-audit.yml.tmpl');

export const workflowPartialsDirectory = (): string =>
  path.join(resolveTemplatesDirectory(), 'partials');
