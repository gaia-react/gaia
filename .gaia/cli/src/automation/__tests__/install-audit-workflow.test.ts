import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, it, vi} from 'vitest';
import {run} from '../install-audit-workflow.js';
import {setupSandbox, type Sandbox} from './sandbox.js';

const captureIo = () => {
  const errors: string[] = [];
  const outs: string[] = [];
  const stderrSpy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown) => {
      errors.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      outs.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    errors,
    outs,
    restore: () => {
      stderrSpy.mockRestore();
      stdoutSpy.mockRestore();
    },
  };
};

describe('automation install-audit-workflow', () => {
  let sandbox: Sandbox;
  let io: ReturnType<typeof captureIo>;

  beforeEach(() => {
    io = captureIo();
    sandbox = setupSandbox('gaia-automation-install-audit-');
  });

  afterEach(() => {
    io.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  it('writes code-review-audit.yml to the specified out-dir', () => {
    const outDir = path.join(sandbox.root, '.github', 'workflows');

    const exit = run(['--out-dir', outDir], {cwd: sandbox.root});

    expect(exit).toBe(0);
    expect(existsSync(path.join(outDir, 'code-review-audit.yml'))).toBe(true);
  });

  it('writes a non-trivial file with expected content', () => {
    const outDir = path.join(sandbox.root, '.github', 'workflows');

    run(['--out-dir', outDir], {cwd: sandbox.root});

    const content = readFileSync(
      path.join(outDir, 'code-review-audit.yml'),
      'utf8'
    );
    expect(content.length).toBeGreaterThan(500);
    expect(content).toContain('code-review-audit');
  });

  it('reports wrote <path>/code-review-audit.yml on stdout', () => {
    const outDir = path.join(sandbox.root, '.github', 'workflows');

    run(['--out-dir', outDir], {cwd: sandbox.root});

    expect(io.outs.join('')).toContain(
      `wrote ${path.join(outDir, 'code-review-audit.yml')}`
    );
  });

  it('creates a missing --out-dir with mkdir -p semantics', () => {
    const outDir = path.join(sandbox.root, 'nested', 'deeper', 'workflows');

    const exit = run(['--out-dir', outDir], {cwd: sandbox.root});

    expect(exit).toBe(0);
    expect(existsSync(path.join(outDir, 'code-review-audit.yml'))).toBe(true);
  });

  it('in --dry-run mode prints byte count and target, writes nothing', () => {
    const outDir = path.join(sandbox.root, '.github', 'workflows');

    const exit = run(['--out-dir', outDir, '--dry-run'], {cwd: sandbox.root});

    expect(exit).toBe(0);
    expect(existsSync(path.join(outDir, 'code-review-audit.yml'))).toBe(false);
    const stdout = io.outs.join('');
    expect(stdout).toMatch(
      /code-review-audit: \d+ bytes -> .*code-review-audit\.yml/u
    );
  });

  it('is idempotent: overwrites an existing file on repeat invocation', () => {
    const outDir = path.join(sandbox.root, '.github', 'workflows');

    run(['--out-dir', outDir], {cwd: sandbox.root});
    const first = readFileSync(
      path.join(outDir, 'code-review-audit.yml'),
      'utf8'
    );

    run(['--out-dir', outDir], {cwd: sandbox.root});
    const second = readFileSync(
      path.join(outDir, 'code-review-audit.yml'),
      'utf8'
    );

    expect(second).toBe(first);
  });

  it('rejects unknown flags with invalid_arguments', () => {
    const outDir = path.join(sandbox.root, '.github', 'workflows');

    const exit = run(['--out-dir', outDir, '--bogus'], {cwd: sandbox.root});

    expect(exit).not.toBe(0);
    expect(io.errors.join('')).toContain('"code":"invalid_arguments"');
  });

  it('rejects missing --out-dir value with invalid_arguments', () => {
    const exit = run(['--out-dir'], {cwd: sandbox.root});

    expect(exit).not.toBe(0);
    expect(io.errors.join('')).toContain('--out-dir requires a path argument');
  });

  it('rejects --out-dir followed by another flag', () => {
    const exit = run(['--out-dir', '--dry-run'], {cwd: sandbox.root});

    expect(exit).not.toBe(0);
    expect(io.errors.join('')).toContain('--out-dir requires a path argument');
  });

  it('exits non-zero when --out-dir is omitted entirely', () => {
    const exit = run(['--dry-run'], {cwd: sandbox.root});

    expect(exit).not.toBe(0);
    expect(io.errors.join('')).toContain('--out-dir is required');
  });

  it('emits help text and exits 0 when --help is passed', () => {
    const exit = run(['--help'], {cwd: sandbox.root});

    expect(exit).toBe(0);
    expect(io.outs.join('')).toContain(
      'Usage: gaia automation install-audit-workflow'
    );
  });
});
