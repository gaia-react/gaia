/**
 * Path constants for GAIA CI configuration and per-tool state files.
 *
 * Every helper takes an explicit `repoRoot` argument — these primitives
 * never call `process.cwd()` themselves. Callers resolve the root via
 * `resolveRepoRoot` from `wiki/util/git.ts`, matching the wiki
 * primitives' pattern.
 */
import path from 'node:path';
import type {ToolId} from '../schemas/automation-config.js';

export const automationConfigPath = (repoRoot: string): string =>
  path.join(repoRoot, '.gaia', 'automation.json');

export const automationStatePath = (repoRoot: string, tool: ToolId): string =>
  path.join(repoRoot, '.gaia', `automation.state-${tool}.json`);

export const localAutomationPath = (repoRoot: string): string =>
  path.join(repoRoot, '.gaia', 'local', 'automation.json');
