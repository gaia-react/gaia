/**
 * Shared sandbox helpers for automation tests. Each sandbox is a tmp dir
 * with `git init`, an initial commit, and a `.gaia/` directory ready for
 * config and state files.
 */
import {execFileSync} from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import type {AutomationConfig} from '../../schemas/automation-config.js';
import type {AutomationStateFile} from '../../schemas/automation-state.js';
import {automationConfigPath, automationStatePath} from '../paths.js';
import type {ToolId} from '../../schemas/automation-config.js';

export type Sandbox = {
  cleanup: () => void;
  commitFile: (relPath: string, content: string) => string;
  headSha: string;
  root: string;
  writeConfig: (config: AutomationConfig) => void;
  writeState: (tool: ToolId, state: AutomationStateFile) => void;
};

export const VALID_BASE_CONFIG: AutomationConfig = {
  pnpm_audit: {mode: 'local', schedule: 'weekly'},
  setup_complete: true,
  setup_opted_out: false,
  sharpen: {mode: 'off'},
  stale_branches: {mode: 'ci', schedule: 'weekly'},
  update_gaia: {mode: 'local'},
  version: 1,
  wiki: {mode: 'ci', schedule: 'daily'},
};

export const setupSandbox = (prefix = 'gaia-automation-'): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), prefix));
  execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});
  execFileSync('git', ['config', 'user.email', 'test@example.com'], {cwd: root});
  execFileSync('git', ['config', 'user.name', 'Test'], {cwd: root});
  writeFileSync(path.join(root, 'README.md'), '# test\n', 'utf8');
  execFileSync('git', ['add', 'README.md'], {cwd: root});
  execFileSync('git', ['commit', '-q', '-m', 'initial'], {cwd: root});
  const headSha = execFileSync('git', ['rev-parse', 'HEAD'], {
    cwd: root,
    encoding: 'utf8',
  })
    .toString()
    .trim();

  mkdirSync(path.join(root, '.gaia'), {recursive: true});

  const commitFile = (relPath: string, content: string): string => {
    const target = path.join(root, relPath);
    mkdirSync(path.dirname(target), {recursive: true});
    writeFileSync(target, content, 'utf8');
    execFileSync('git', ['add', relPath], {cwd: root});
    execFileSync('git', ['commit', '-q', '-m', `add ${relPath}`], {cwd: root});

    return execFileSync('git', ['rev-parse', 'HEAD'], {
      cwd: root,
      encoding: 'utf8',
    })
      .toString()
      .trim();
  };

  const writeConfig = (config: AutomationConfig): void => {
    writeFileSync(automationConfigPath(root), JSON.stringify(config), 'utf8');
  };

  const writeState = (tool: ToolId, state: AutomationStateFile): void => {
    writeFileSync(automationStatePath(root, tool), JSON.stringify(state), 'utf8');
  };

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    commitFile,
    headSha,
    root,
    writeConfig,
    writeState,
  };
};
