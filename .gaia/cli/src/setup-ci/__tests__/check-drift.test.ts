import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {mkdirSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {
  workflowPartialsDirectory,
  workflowTemplatePath,
} from '../../automation/paths.js';
import {renderWorkflowTemplate} from '../../automation/render.js';
import {buildWorkflowVars} from '../../automation/workflow-vars.js';
import {TOOL_IDS} from '../../schemas/automation-config.js';
import type {ToolId} from '../../schemas/automation-config.js';
import {run} from '../check-drift.js';
import {setupSandbox, VALID_BASE_CONFIG} from './sandbox.js';
import type {Sandbox} from './sandbox.js';

const captureStdio = (): {
  err: string[];
  out: string[];
  restore: () => void;
} => {
  const out: string[] = [];
  const err: string[] = [];
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      out.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });
  const stderrSpy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown) => {
      err.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    err,
    out,
    restore: () => {
      stdoutSpy.mockRestore();
      stderrSpy.mockRestore();
    },
  };
};

const writeFreshWorkflows = (
  sandbox: Sandbox,
  tools: readonly ToolId[]
): void => {
  const workflowsDir = path.join(sandbox.root, '.github', 'workflows');
  mkdirSync(workflowsDir, {recursive: true});
  const partialsDir = workflowPartialsDirectory();

  for (const tool of tools) {
    const vars = buildWorkflowVars(
      {
        ...VALID_BASE_CONFIG,
        setup_complete: true,
      },
      tool
    );

    if (vars !== null) {
      const rendered = renderWorkflowTemplate(
        workflowTemplatePath(tool),
        partialsDir,
        vars
      );
      writeFileSync(
        path.join(workflowsDir, `gaia-ci-${tool}.yml`),
        rendered,
        'utf8'
      );
    }
  }
};

describe('setup-ci check-drift', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-setup-ci-check-drift-');
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('reports all enabled tools as in_sync when rendered files match templates', () => {
    sandbox.writeConfig({...VALID_BASE_CONFIG, setup_complete: true});
    writeFreshWorkflows(sandbox, TOOL_IDS);

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as {
      drifted: ToolId[];
      in_sync: ToolId[];
      missing: ToolId[];
    };
    expect(parsed.drifted).toEqual([]);
    expect(parsed.missing).toEqual([]);
    expect(new Set(parsed.in_sync)).toEqual(new Set(TOOL_IDS));
  });

  test('flags drifted tools when on-disk bytes diverge from a fresh render', () => {
    sandbox.writeConfig({...VALID_BASE_CONFIG, setup_complete: true});
    writeFreshWorkflows(sandbox, TOOL_IDS);

    // Corrupt one rendered workflow to simulate template drift.
    const target = path.join(
      sandbox.root,
      '.github',
      'workflows',
      'gaia-ci-pnpm-audit.yml'
    );
    writeFileSync(target, '# drifted contents\n', 'utf8');

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as {
      drifted: ToolId[];
      in_sync: ToolId[];
      missing: ToolId[];
    };
    expect(parsed.drifted).toEqual(['pnpm-audit']);
    expect(parsed.missing).toEqual([]);
    expect(new Set(parsed.in_sync)).toEqual(
      new Set(['stale-branches', 'update-deps', 'wiki'])
    );
  });

  test('flags tools as missing when the rendered workflow file does not exist', () => {
    sandbox.writeConfig({...VALID_BASE_CONFIG, setup_complete: true});
    // Only write three of the four workflows; wiki goes missing.
    writeFreshWorkflows(sandbox, [
      'update-deps',
      'pnpm-audit',
      'stale-branches',
    ]);

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as {
      drifted: ToolId[];
      in_sync: ToolId[];
      missing: ToolId[];
    };
    expect(parsed.missing).toEqual(['wiki']);
    expect(parsed.drifted).toEqual([]);
    expect(new Set(parsed.in_sync)).toEqual(
      new Set(['pnpm-audit', 'stale-branches', 'update-deps'])
    );
  });

  test('omits tools whose mode != ci from all three buckets', () => {
    sandbox.writeConfig({
      ...VALID_BASE_CONFIG,
      pnpm_audit: {mode: 'local', schedule: 'weekly'},
      setup_complete: true,
      stale_branches: {mode: 'off'},
    });
    writeFreshWorkflows(sandbox, ['wiki', 'update-deps']);

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as {
      drifted: ToolId[];
      in_sync: ToolId[];
      missing: ToolId[];
    };
    expect(parsed.drifted).toEqual([]);
    expect(parsed.missing).toEqual([]);
    expect(new Set(parsed.in_sync)).toEqual(new Set(['update-deps', 'wiki']));
  });

  test('exits non-zero with config_missing when .gaia/automation.json is absent', () => {
    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('config_missing');
  });

  test('exits non-zero with config_malformed for an invalid config', () => {
    sandbox.writeConfig({
      ...VALID_BASE_CONFIG,
      version: 99 as unknown as 1,
    });

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('config_malformed');
  });

  test('honors --workflows-dir override', () => {
    sandbox.writeConfig({...VALID_BASE_CONFIG, setup_complete: true});
    const customDir = path.join(sandbox.root, 'custom-workflows');
    mkdirSync(customDir, {recursive: true});

    // Default location has nothing; check-drift should still report all as
    // missing when pointed at an empty custom dir.
    const exit = run(['--workflows-dir', customDir, '--json'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as {
      drifted: ToolId[];
      in_sync: ToolId[];
      missing: ToolId[];
    };
    expect(new Set(parsed.missing)).toEqual(new Set(TOOL_IDS));
  });

  test('emits a human-readable summary without --json', () => {
    sandbox.writeConfig({...VALID_BASE_CONFIG, setup_complete: true});
    writeFreshWorkflows(sandbox, TOOL_IDS);

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const out = stdio.out.join('');
    expect(out).toContain('in_sync:');
  });

  test('rejects unknown flags', () => {
    const exit = run(['--bogus'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('unknown flag');
  });

  test('--help exits 0', () => {
    const exit = run(['--help'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.out.join('')).toContain('Usage:');
  });
});
