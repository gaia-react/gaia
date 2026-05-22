import {mkdirSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, it, vi} from 'vitest';
import {localAutomationPath} from '../../automation/paths.js';
import {readLocalAutomation} from '../../schemas/local-automation.js';
import {run} from '../dismiss-personal.js';
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

describe('setup-ci dismiss-personal', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-setup-ci-dismiss-personal-');
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  it('creates the local file when missing', () => {
    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const result = readLocalAutomation(sandbox.root);
    expect(result.status).toBe('ok');

    if (result.status === 'ok') {
      expect(result.local.nudge_dismissed).toBe(true);
    }
  });

  it('flips nudge_dismissed when existing local has it false', () => {
    mkdirSync(path.dirname(localAutomationPath(sandbox.root)), {
      recursive: true,
    });
    writeFileSync(
      localAutomationPath(sandbox.root),
      JSON.stringify({nudge_dismissed: false, version: 1}),
      'utf8'
    );

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const result = readLocalAutomation(sandbox.root);
    expect(result.status).toBe('ok');

    if (result.status === 'ok') {
      expect(result.local.nudge_dismissed).toBe(true);
    }
  });

  it('is idempotent (final state unchanged when already dismissed)', () => {
    mkdirSync(path.dirname(localAutomationPath(sandbox.root)), {
      recursive: true,
    });
    writeFileSync(
      localAutomationPath(sandbox.root),
      JSON.stringify({nudge_dismissed: true, version: 1}),
      'utf8'
    );

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const result = readLocalAutomation(sandbox.root);
    expect(result.status).toBe('ok');

    if (result.status === 'ok') {
      expect(result.local.nudge_dismissed).toBe(true);
    }
  });

  it('refuses with local_malformed when existing local is malformed', () => {
    mkdirSync(path.dirname(localAutomationPath(sandbox.root)), {
      recursive: true,
    });
    writeFileSync(
      localAutomationPath(sandbox.root),
      JSON.stringify({nudge_dismissed: 'yes', version: 1}),
      'utf8'
    );

    const exit = run([], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('local_malformed');
  });

  it('emits dismissed: true JSON on success', () => {
    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.out.join('').trim()) as Record<
      string,
      unknown
    >;
    expect(parsed.dismissed).toBe(true);
  });

  it('rejects unexpected arguments', () => {
    const exit = run(['--bogus'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('unexpected argument');
  });

  it('--help exits 0', () => {
    const exit = run(['--help'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.out.join('')).toContain('Usage:');
  });
});
