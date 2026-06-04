import {mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, it, vi} from 'vitest';
import {workflowAuditTemplatePath} from '../../automation/paths.js';
import {run} from '../check-audit-drift.js';
import {setupSandbox, type Sandbox} from './sandbox.js';

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

const writeAuditWorkflow = (sandbox: Sandbox, content?: string): void => {
  const workflowsDir = path.join(sandbox.root, '.github', 'workflows');
  mkdirSync(workflowsDir, {recursive: true});
  const source = content ?? readFileSync(workflowAuditTemplatePath(), 'utf8');
  writeFileSync(
    path.join(workflowsDir, 'code-review-audit.yml'),
    source,
    'utf8'
  );
};

describe('setup-ci check-audit-drift', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-setup-ci-check-audit-drift-');
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  it('reports in_sync when the installed file matches the template', () => {
    writeAuditWorkflow(sandbox);

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as {state: string};
    expect(parsed.state).toBe('in_sync');
  });

  it('reports drifted when the installed file bytes differ from the template', () => {
    writeAuditWorkflow(sandbox, '# drifted contents\n');

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as {state: string};
    expect(parsed.state).toBe('drifted');
  });

  it('reports missing when the workflow file does not exist', () => {
    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as {state: string};
    expect(parsed.state).toBe('missing');
  });

  it('honors --workflows-dir override (in_sync)', () => {
    const customDir = path.join(sandbox.root, 'custom-workflows');
    mkdirSync(customDir, {recursive: true});
    writeFileSync(
      path.join(customDir, 'code-review-audit.yml'),
      readFileSync(workflowAuditTemplatePath(), 'utf8'),
      'utf8'
    );

    const exit = run(['--workflows-dir', customDir, '--json'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as {state: string};
    expect(parsed.state).toBe('in_sync');
  });

  it('honors --workflows-dir override (missing)', () => {
    const customDir = path.join(sandbox.root, 'custom-workflows');
    mkdirSync(customDir, {recursive: true});

    const exit = run(['--workflows-dir', customDir, '--json'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as {state: string};
    expect(parsed.state).toBe('missing');
  });

  it('emits human-readable output without --json', () => {
    writeAuditWorkflow(sandbox);

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);

    expect(stdio.out.join('')).toContain('audit workflow: in_sync');
  });

  it('rejects unknown flags with invalid_arguments', () => {
    const exit = run(['--bogus'], {cwd: sandbox.root});

    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('unknown flag');
  });

  it('emits help text and exits 0 when --help is passed', () => {
    const exit = run(['--help'], {cwd: sandbox.root});

    expect(exit).toBe(0);
    expect(stdio.out.join('')).toContain('Usage:');
  });
});
