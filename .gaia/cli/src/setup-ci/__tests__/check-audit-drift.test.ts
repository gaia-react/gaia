import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {workflowAuditTemplatePath} from '../../automation/paths.js';
import {run} from '../check-audit-drift.js';
import {setupSandbox} from './sandbox.js';
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

const writeTemplateFixture = (
  sandbox: Sandbox,
  name: string,
  content: string
): string => {
  const fixturePath = path.join(sandbox.root, name);
  writeFileSync(fixturePath, content, 'utf8');

  return fixturePath;
};

const readState = (stdio: ReturnType<typeof captureStdio>): string =>
  (JSON.parse(stdio.out.join('').trim()) as {state: string}).state;

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

  test('reports in_sync when the installed file matches the template', () => {
    writeAuditWorkflow(sandbox);

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as {state: string};
    expect(parsed.state).toBe('in_sync');
  });

  test('reports drifted when the installed file bytes differ from the template', () => {
    writeAuditWorkflow(sandbox, '# drifted contents\n');

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as {state: string};
    expect(parsed.state).toBe('drifted');
  });

  test('reports missing when the workflow file does not exist', () => {
    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as {state: string};
    expect(parsed.state).toBe('missing');
  });

  test('honors --workflows-dir override (in_sync)', () => {
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

  test('honors --workflows-dir override (missing)', () => {
    const customDir = path.join(sandbox.root, 'custom-workflows');
    mkdirSync(customDir, {recursive: true});

    const exit = run(['--workflows-dir', customDir, '--json'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as {state: string};
    expect(parsed.state).toBe('missing');
  });

  test('emits human-readable output without --json', () => {
    writeAuditWorkflow(sandbox);

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);

    expect(stdio.out.join('')).toContain('audit workflow: in_sync');
  });

  test('rejects unknown flags with invalid_arguments', () => {
    const exit = run(['--bogus'], {cwd: sandbox.root});

    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('unknown flag');
  });

  test('emits help text and exits 0 when --help is passed', () => {
    const exit = run(['--help'], {cwd: sandbox.root});

    expect(exit).toBe(0);
    expect(stdio.out.join('')).toContain('Usage:');
  });
});

describe('setup-ci check-audit-drift (3-way merge classify)', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-setup-ci-check-audit-drift-3way-');
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  const OLD = '# v1 audit workflow\n';
  const NEW = '# v2 audit workflow\n';

  test('reports in_sync when the installed file equals the latest template', () => {
    writeAuditWorkflow(sandbox, NEW);
    const baseline = writeTemplateFixture(sandbox, 'baseline.tmpl', OLD);
    const latest = writeTemplateFixture(sandbox, 'latest.tmpl', NEW);

    const exit = run(['--baseline', baseline, '--latest', latest, '--json'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);
    expect(readState(stdio)).toBe('in_sync');
  });

  test('reports clean when the installed file equals the baseline template (stale)', () => {
    writeAuditWorkflow(sandbox, OLD);
    const baseline = writeTemplateFixture(sandbox, 'baseline.tmpl', OLD);
    const latest = writeTemplateFixture(sandbox, 'latest.tmpl', NEW);

    const exit = run(['--baseline', baseline, '--latest', latest, '--json'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);
    expect(readState(stdio)).toBe('clean');
  });

  test('reports conflict when the installed file matches neither template (adopter drift)', () => {
    writeAuditWorkflow(sandbox, '# adopter-customized\n');
    const baseline = writeTemplateFixture(sandbox, 'baseline.tmpl', OLD);
    const latest = writeTemplateFixture(sandbox, 'latest.tmpl', NEW);

    const exit = run(['--baseline', baseline, '--latest', latest, '--json'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);
    expect(readState(stdio)).toBe('conflict');
  });

  test('reports in_sync (no-op) when the release did not change the template even if the installed file drifted', () => {
    writeAuditWorkflow(sandbox, '# adopter-customized\n');
    const baseline = writeTemplateFixture(sandbox, 'baseline.tmpl', OLD);
    const latest = writeTemplateFixture(sandbox, 'latest.tmpl', OLD);

    const exit = run(['--baseline', baseline, '--latest', latest, '--json'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);
    expect(readState(stdio)).toBe('in_sync');
  });

  test('reports conflict (never auto-writes) when the baseline template is unavailable', () => {
    writeAuditWorkflow(sandbox, OLD);
    const latest = writeTemplateFixture(sandbox, 'latest.tmpl', NEW);
    const missingBaseline = path.join(sandbox.root, 'does-not-exist.tmpl');

    const exit = run(
      ['--baseline', missingBaseline, '--latest', latest, '--json'],
      {cwd: sandbox.root}
    );
    expect(exit).toBe(0);
    expect(readState(stdio)).toBe('conflict');
  });

  test('reports missing in 3-way mode when the installed file is absent', () => {
    const baseline = writeTemplateFixture(sandbox, 'baseline.tmpl', OLD);
    const latest = writeTemplateFixture(sandbox, 'latest.tmpl', NEW);

    const exit = run(['--baseline', baseline, '--latest', latest, '--json'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);
    expect(readState(stdio)).toBe('missing');
  });

  test('defaults --latest to the bundled template when only --baseline is given', () => {
    writeAuditWorkflow(sandbox);
    const baseline = writeTemplateFixture(sandbox, 'baseline.tmpl', OLD);

    const exit = run(['--baseline', baseline, '--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(readState(stdio)).toBe('in_sync');
  });

  test('rejects --latest without --baseline', () => {
    const latest = writeTemplateFixture(sandbox, 'latest.tmpl', NEW);

    const exit = run(['--latest', latest, '--json'], {cwd: sandbox.root});

    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('--latest requires --baseline');
  });

  test('errors when the latest template path is unreadable', () => {
    writeAuditWorkflow(sandbox, OLD);
    const baseline = writeTemplateFixture(sandbox, 'baseline.tmpl', OLD);
    const missingLatest = path.join(sandbox.root, 'no-latest.tmpl');

    const exit = run(
      ['--baseline', baseline, '--latest', missingLatest, '--json'],
      {cwd: sandbox.root}
    );

    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('template_unreadable');
  });

  test('emits human-readable 3-way output without --json', () => {
    writeAuditWorkflow(sandbox, OLD);
    const baseline = writeTemplateFixture(sandbox, 'baseline.tmpl', OLD);
    const latest = writeTemplateFixture(sandbox, 'latest.tmpl', NEW);

    const exit = run(['--baseline', baseline, '--latest', latest], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);
    expect(stdio.out.join('')).toContain('audit workflow: clean');
  });
});
